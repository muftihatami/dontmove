package api

import (
	"net/http"
	"strings"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-identity/internal/identitydb"
	"github.com/google/uuid"
)

var errLinkGone = fail(http.StatusGone, "link_purged",
	"Jalur dari shadow_id ke identitas sudah diputus (retensi 30 hari). Ban tidak bisa ditegakkan lagi.")

func (s *Server) loadByShadow(q *identitydb.Queries, r *http.Request, id uuid.UUID) (identitydb.GetIdentityByShadowForUpdateRow, error) {
	row, err := q.GetIdentityByShadowForUpdate(r.Context(), id)
	if isNoRows(err) {
		return row, errLinkGone
	}
	return row, err
}

func (s *Server) logAs(q *identitydb.Queries, r *http.Request, actor, action string, shadowID uuid.UUID, reason string) error {
	return q.InsertAccessLog(r.Context(), identitydb.InsertAccessLogParams{
		Actor: actor, Action: action,
		ShadowID: uuid.NullUUID{UUID: shadowID, Valid: true}, Reason: reason,
	})
}

// enforceBan — ban sementara bisa dipulihkan; ban permanen memusnahkan PII dan menyimpan denylist (F0 §2.3).
func (s *Server) enforceBan(w http.ResponseWriter, r *http.Request) {
	var req ic.EnforceBanRequest
	if err := decode(r, &req); err != nil {
		s.respondErr(w, err)
		return
	}
	if strings.TrimSpace(req.Actor) == "" || strings.TrimSpace(req.Reason) == "" {
		s.respondErr(w, fail(http.StatusBadRequest, "reason_required", "Actor dan alasan wajib diisi."))
		return
	}
	ctx := r.Context()
	now := s.now()
	err := s.inTx(ctx, func(q *identitydb.Queries) error {
		row, err := s.loadByShadow(q, r, req.ShadowID)
		if err != nil {
			return err
		}
		switch req.Mode {
		case ic.BanTemporary:
			if req.Until == nil || !req.Until.After(now) {
				return fail(http.StatusBadRequest, "until_required", "Ban sementara butuh waktu berakhir di masa depan.")
			}
			if row.DeletedAt != nil {
				return fail(http.StatusConflict, "identity_purged", "Akun sudah dihapus; ban sementara tidak berlaku.")
			}
			if err := q.SetBan(ctx, identitydb.SetBanParams{ID: row.ID, BannedUntil: req.Until}); err != nil {
				return err
			}
		case ic.BanPermanent:
			if row.DeletedAt != nil {
				if row.Denylisted && row.BannedUntil == nil {
					return nil // sudah permanen; idempoten, tanpa log ganda
				}
				if !row.Denylisted {
					// Penghapusan sukarela sudah memusnahkan lookup: tidak ada yang bisa dimasukkan denylist.
					return fail(http.StatusConflict, "identity_purged",
						"Pemiliknya sudah menghapus akun; ban permanen tidak bisa lagi ditegakkan.")
				}
				// Dihapus saat ban sementara aktif → naikkan jadi permanen.
				if err := q.SetBan(ctx, identitydb.SetBanParams{ID: row.ID, BannedUntil: nil}); err != nil {
					return err
				}
				if err := q.BlockDevices(ctx, row.ID); err != nil {
					return err
				}
				break
			}
			if err := q.SetBan(ctx, identitydb.SetBanParams{ID: row.ID, BannedUntil: nil}); err != nil {
				return err
			}
			if err := q.PurgeKeepDenylist(ctx, row.ID); err != nil {
				return err
			}
			if err := q.BlockDevices(ctx, row.ID); err != nil {
				return err
			}
			after := now.Add(retentionWindow)
			if err := q.SchedulePurge(ctx, identitydb.SchedulePurgeParams{ShadowID: req.ShadowID, PurgeAfter: &after}); err != nil {
				return err
			}
		default:
			return fail(http.StatusBadRequest, "invalid_mode", "Mode harus temporary atau permanent.")
		}
		return s.logAs(q, r, req.Actor, "ban."+string(req.Mode), req.ShadowID, req.Reason)
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) isBanned(w http.ResponseWriter, r *http.Request) {
	qs := r.URL.Query()
	id, err := uuid.Parse(qs.Get("shadow_id"))
	actor, reason := strings.TrimSpace(qs.Get("actor")), strings.TrimSpace(qs.Get("reason"))
	if err != nil || actor == "" || reason == "" {
		s.respondErr(w, fail(http.StatusBadRequest, "bad_request", "shadow_id, actor, dan reason wajib."))
		return
	}
	var banned bool
	err = s.inTx(r.Context(), func(q *identitydb.Queries) error {
		row, err := s.loadByShadow(q, r, id)
		if err != nil {
			return err
		}
		banned = row.Status == "banned" && (row.BannedUntil == nil || s.now().Before(*row.BannedUntil))
		return s.logAs(q, r, actor, "is-banned", id, reason)
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, ic.IsBannedResponse{Banned: banned})
}

// deleteAccount — T2/T3. Ban yang sedang berjalan TIDAK bisa dihindari dengan menghapus akun:
// lookup tetap disimpan (denylisted) sampai masa ban habis, lalu dilepas oleh job harian.
func (s *Server) deleteAccount(w http.ResponseWriter, r *http.Request) {
	var req ic.DeleteAccountRequest
	if err := decode(r, &req); err != nil {
		s.respondErr(w, err)
		return
	}
	if strings.TrimSpace(req.Reason) == "" {
		s.respondErr(w, fail(http.StatusBadRequest, "reason_required", "Alasan wajib diisi."))
		return
	}
	ctx := r.Context()
	now := s.now()
	err := s.inTx(ctx, func(q *identitydb.Queries) error {
		row, err := s.loadByShadow(q, r, req.ShadowID)
		if err != nil {
			return err
		}
		if row.DeletedAt != nil {
			return nil // idempoten
		}
		activeBan := row.Status == "banned" && (row.BannedUntil == nil || now.Before(*row.BannedUntil))
		if activeBan {
			if err := q.PurgeKeepDenylist(ctx, row.ID); err != nil {
				return err
			}
		} else {
			if err := q.PurgeVoluntary(ctx, row.ID); err != nil {
				return err
			}
			if err := q.DeleteDevices(ctx, row.ID); err != nil {
				return err
			}
		}
		after := now.Add(retentionWindow)
		if err := q.SchedulePurge(ctx, identitydb.SchedulePurgeParams{ShadowID: req.ShadowID, PurgeAfter: &after}); err != nil {
			return err
		}
		return s.logAs(q, r, "svc-content", "account.delete", req.ShadowID, req.Reason)
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
