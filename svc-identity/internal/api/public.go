package api

import (
	"crypto/hmac"
	"net/http"
	"time"

	"github.com/dontmove/svc-identity/internal/identitydb"
	"github.com/dontmove/svc-identity/internal/otp"
	"github.com/dontmove/svc-identity/internal/vaultcrypto"
	"github.com/google/uuid"
)

// ---------- OTP ----------

type otpStartReq struct {
	Channel     string `json:"channel"`     // email | phone
	Destination string `json:"destination"` // alamat email atau nomor HP
}

type otpStartResp struct {
	ChallengeID uuid.UUID `json:"challenge_id"`
	ExpiresAt   time.Time `json:"expires_at"`
}

func (s *Server) normalize(channel, dest string) (string, vaultcrypto.Kind, error) {
	switch channel {
	case "email":
		v, err := vaultcrypto.NormalizeEmail(dest)
		if err != nil {
			return "", "", fail(http.StatusBadRequest, "invalid_email", "Format email tidak valid.")
		}
		return v, vaultcrypto.KindEmail, nil
	case "phone":
		v, err := vaultcrypto.NormalizePhone(dest)
		if err != nil {
			return "", "", fail(http.StatusBadRequest, "invalid_phone", "Format nomor HP tidak valid.")
		}
		return v, vaultcrypto.KindPhone, nil
	}
	return "", "", fail(http.StatusBadRequest, "invalid_channel", "Kanal harus email atau phone.")
}

// otpStart selalu menjawab sama, terdaftar atau tidak, supaya endpoint ini
// tidak bisa dipakai untuk menguji "apakah nomor ini punya akun Don't Move".
func (s *Server) otpStart(w http.ResponseWriter, r *http.Request) {
	var req otpStartReq
	if err := decode(r, &req); err != nil {
		s.respondErr(w, err)
		return
	}
	dest, kind, err := s.normalize(req.Channel, req.Destination)
	if err != nil {
		s.respondErr(w, err)
		return
	}
	ctx := r.Context()
	lookup := s.Keys.Lookup(kind, dest)
	q := s.q()

	n, err := q.CountOTPSince(ctx, identitydb.CountOTPSinceParams{DestLookup: lookup, CreatedAt: s.now().Add(-time.Hour)})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	if n >= otpPerHour {
		s.respondErr(w, fail(http.StatusTooManyRequests, "otp_rate_limited", "Terlalu banyak permintaan kode. Coba lagi dalam satu jam."))
		return
	}

	code, err := otp.NewCode()
	if err != nil {
		s.respondErr(w, err)
		return
	}
	// MAC kode diikat ke lookup tujuan, lalu dicek ulang saat verifikasi.
	exp := s.now().Add(otpTTL)
	id, err := q.InsertOTPChallenge(ctx, identitydb.InsertOTPChallengeParams{
		Channel:    req.Channel,
		DestLookup: lookup,
		CodeMac:    s.codeMAC(lookup, code),
		ExpiresAt:  exp,
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	if err := s.Sender.Send(otp.WithChallengeID(ctx, id.String()), req.Channel, dest, code); err != nil {
		s.respondErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, otpStartResp{ChallengeID: id, ExpiresAt: exp})
}

func (s *Server) codeMAC(destLookup []byte, code string) []byte {
	return s.Keys.Lookup(vaultcrypto.KindOTP, string(destLookup)+":"+code)
}

type otpVerifyReq struct {
	ChallengeID uuid.UUID `json:"challenge_id"`
	Code        string    `json:"code"`
}

func (s *Server) otpVerify(w http.ResponseWriter, r *http.Request) {
	var req otpVerifyReq
	if err := decode(r, &req); err != nil {
		s.respondErr(w, err)
		return
	}
	wrong := fail(http.StatusBadRequest, "otp_invalid", "Kode salah atau sudah kedaluwarsa.")
	err := s.inTx(r.Context(), func(q *identitydb.Queries) error {
		c, err := q.GetOTPForUpdate(r.Context(), req.ChallengeID)
		if isNoRows(err) {
			return wrong
		}
		if err != nil {
			return err
		}
		if c.ConsumedAt != nil || !s.now().Before(c.ExpiresAt) {
			return wrong
		}
		if c.VerifiedAt != nil {
			return nil // idempoten
		}
		if c.Attempts >= otpMaxAttempts {
			return fail(http.StatusTooManyRequests, "otp_locked", "Terlalu banyak percobaan. Minta kode baru.")
		}
		if !hmac.Equal(c.CodeMac, s.codeMAC(c.DestLookup, req.Code)) {
			if err := q.BumpOTPAttempts(r.Context(), c.ID); err != nil {
				return err
			}
			return errCommitThen{wrong}
		}
		return q.MarkOTPVerified(r.Context(), c.ID)
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Register ----------

type registerReq struct {
	EmailChallengeID  uuid.UUID `json:"email_challenge_id"`
	Email             string    `json:"email"`
	PhoneChallengeID  uuid.UUID `json:"phone_challenge_id"`
	Phone             string    `json:"phone"`
	BirthDate         string    `json:"birth_date"` // YYYY-MM-DD
	DeviceFingerprint string    `json:"device_fingerprint"`
}

type authResp struct {
	ShadowID  uuid.UUID `json:"shadow_id"`
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var req registerReq
	if err := decode(r, &req); err != nil {
		s.respondErr(w, err)
		return
	}
	email, _, err := s.normalize("email", req.Email)
	if err != nil {
		s.respondErr(w, err)
		return
	}
	phone, _, err := s.normalize("phone", req.Phone)
	if err != nil {
		s.respondErr(w, err)
		return
	}
	birth, err := time.Parse(time.DateOnly, req.BirthDate)
	if err != nil {
		s.respondErr(w, fail(http.StatusBadRequest, "invalid_birth_date", "Tanggal lahir tidak valid."))
		return
	}
	if ageOn(birth, s.now()) < s.MinAge {
		// Pesan netral: tidak memberi tahu angka yang harus diketik supaya lolos.
		s.respondErr(w, fail(http.StatusForbidden, "not_eligible", "Kamu belum bisa memakai Don't Move."))
		return
	}
	if len(req.DeviceFingerprint) < 16 {
		s.respondErr(w, fail(http.StatusBadRequest, "invalid_device", "Perangkat tidak dikenali."))
		return
	}

	emailLookup := s.Keys.Lookup(vaultcrypto.KindEmail, email)
	phoneLookup := s.Keys.Lookup(vaultcrypto.KindPhone, phone)
	deviceLookup := s.Keys.Lookup(vaultcrypto.KindDevice, req.DeviceFingerprint)
	emailEnc, err := s.Keys.Seal(vaultcrypto.KindEmail, email)
	if err != nil {
		s.respondErr(w, err)
		return
	}
	phoneEnc, err := s.Keys.Seal(vaultcrypto.KindPhone, phone)
	if err != nil {
		s.respondErr(w, err)
		return
	}

	shadowID := uuid.New()
	err = s.inTx(ctx, func(q *identitydb.Queries) error {
		if err := s.consumeVerified(q, r, req.EmailChallengeID, "email", emailLookup); err != nil {
			return err
		}
		if err := s.consumeVerified(q, r, req.PhoneChallengeID, "phone", phoneLookup); err != nil {
			return err
		}
		if err := s.refuseIfTaken(q, r, emailLookup, phoneLookup); err != nil {
			return err
		}
		if err := s.checkDevice(q, r, deviceLookup, uuid.Nil); err != nil {
			return err
		}
		idt, err := q.InsertIdentity(ctx, identitydb.InsertIdentityParams{
			EmailLookup: emailLookup, PhoneLookup: phoneLookup,
			EmailEnc: emailEnc, PhoneEnc: phoneEnc, BirthDate: &birth,
		})
		if isUniqueViolation(err) {
			return errAlreadyRegistered
		}
		if err != nil {
			return err
		}
		if err := q.UpsertDevice(ctx, identitydb.UpsertDeviceParams{IdentityID: idt, DeviceLookup: deviceLookup}); err != nil {
			return err
		}
		if err := q.InsertShadowLink(ctx, identitydb.InsertShadowLinkParams{ShadowID: shadowID, IdentityID: idt}); err != nil {
			return err
		}
		return s.audit(q, r, "register", shadowID, "pendaftaran baru")
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	s.issue(w, http.StatusCreated, shadowID)
}

var (
	errAlreadyRegistered = fail(http.StatusConflict, "already_registered", "Email atau nomor HP ini sudah terdaftar. Silakan masuk.")
	errNotAllowed        = fail(http.StatusForbidden, "not_allowed", "Akun ini tidak dapat digunakan di Don't Move.")
	errDeviceRefused     = fail(http.StatusForbidden, "device_not_allowed", "Perangkat ini sudah terhubung ke akun lain atau tidak dapat digunakan.")
	errOTPNotVerified    = fail(http.StatusBadRequest, "otp_not_verified", "Verifikasi kode belum selesai atau sudah kedaluwarsa.")
)

// consumeVerified memastikan tantangan OTP sudah diverifikasi untuk tujuan yang sama, lalu memakainya.
func (s *Server) consumeVerified(q *identitydb.Queries, r *http.Request, id uuid.UUID, channel string, lookup []byte) error {
	c, err := q.GetOTPForUpdate(r.Context(), id)
	if isNoRows(err) {
		return errOTPNotVerified
	}
	if err != nil {
		return err
	}
	if c.Channel != channel || !hmac.Equal(c.DestLookup, lookup) ||
		c.VerifiedAt == nil || c.ConsumedAt != nil || !s.now().Before(c.ExpiresAt) {
		return errOTPNotVerified
	}
	return q.ConsumeOTP(r.Context(), id)
}

// refuseIfTaken: denylist dan akun hidup sama-sama memegang lookup, jadi keduanya ditemukan di sini.
// Membedakan keduanya aman: hanya pemilik email DAN HP yang sudah terverifikasi yang sampai ke titik ini.
func (s *Server) refuseIfTaken(q *identitydb.Queries, r *http.Request, emailLookup, phoneLookup []byte) error {
	type found struct {
		denylisted bool
	}
	var hits []found
	if row, err := q.FindIdentityByEmailLookup(r.Context(), emailLookup); err == nil {
		hits = append(hits, found{row.Denylisted})
	} else if !isNoRows(err) {
		return err
	}
	if row, err := q.FindIdentityByPhoneLookup(r.Context(), phoneLookup); err == nil {
		hits = append(hits, found{row.Denylisted})
	} else if !isNoRows(err) {
		return err
	}
	for _, h := range hits {
		if h.denylisted {
			return errNotAllowed
		}
	}
	if len(hits) > 0 {
		return errAlreadyRegistered
	}
	return nil
}

// checkDevice: perangkat yang diblokir ditolak, dan satu perangkat hanya untuk satu identitas hidup.
func (s *Server) checkDevice(q *identitydb.Queries, r *http.Request, deviceLookup []byte, self uuid.UUID) error {
	blocked, err := q.DeviceBlocked(r.Context(), deviceLookup)
	if err != nil {
		return err
	}
	held, err := q.DeviceHeldByOtherLiveIdentity(r.Context(), identitydb.DeviceHeldByOtherLiveIdentityParams{
		DeviceLookup: deviceLookup, IdentityID: self,
	})
	if err != nil {
		return err
	}
	if blocked || held {
		return errDeviceRefused
	}
	return nil
}

// ---------- Login ----------

type loginReq struct {
	ChallengeID       uuid.UUID `json:"challenge_id"`
	Channel           string    `json:"channel"`
	Destination       string    `json:"destination"`
	DeviceFingerprint string    `json:"device_fingerprint"`
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var req loginReq
	if err := decode(r, &req); err != nil {
		s.respondErr(w, err)
		return
	}
	dest, kind, err := s.normalize(req.Channel, req.Destination)
	if err != nil {
		s.respondErr(w, err)
		return
	}
	if len(req.DeviceFingerprint) < 16 {
		s.respondErr(w, fail(http.StatusBadRequest, "invalid_device", "Perangkat tidak dikenali."))
		return
	}
	lookup := s.Keys.Lookup(kind, dest)
	deviceLookup := s.Keys.Lookup(vaultcrypto.KindDevice, req.DeviceFingerprint)
	notFound := fail(http.StatusNotFound, "no_account", "Belum ada akun dengan data ini. Daftar dulu.")

	var shadowID uuid.UUID
	err = s.inTx(ctx, func(q *identitydb.Queries) error {
		if err := s.consumeVerified(q, r, req.ChallengeID, req.Channel, lookup); err != nil {
			return err
		}
		var row identitydb.FindIdentityByEmailLookupRow
		if kind == vaultcrypto.KindEmail {
			row, err = q.FindIdentityByEmailLookup(ctx, lookup)
		} else {
			var p identitydb.FindIdentityByPhoneLookupRow
			p, err = q.FindIdentityByPhoneLookup(ctx, lookup)
			row = identitydb.FindIdentityByEmailLookupRow(p)
		}
		if isNoRows(err) {
			return notFound
		}
		if err != nil {
			return err
		}
		if row.DeletedAt != nil {
			if row.Denylisted {
				return errNotAllowed
			}
			return notFound
		}
		if row.Status == "banned" {
			if row.BannedUntil == nil || s.now().Before(*row.BannedUntil) {
				return fail(http.StatusForbidden, "banned", "Akunmu sedang ditangguhkan.")
			}
			if err := q.ReactivateExpiredBan(ctx, row.ID); err != nil {
				return err
			}
		}
		if err := s.checkDevice(q, r, deviceLookup, row.ID); err != nil {
			return err
		}
		if err := q.UpsertDevice(ctx, identitydb.UpsertDeviceParams{IdentityID: row.ID, DeviceLookup: deviceLookup}); err != nil {
			return err
		}
		if shadowID, err = q.GetShadowByIdentity(ctx, row.ID); err != nil {
			return err
		}
		return s.audit(q, r, "login", shadowID, "masuk dengan OTP "+req.Channel)
	})
	if err != nil {
		s.respondErr(w, err)
		return
	}
	s.issue(w, http.StatusOK, shadowID)
}

func (s *Server) issue(w http.ResponseWriter, status int, shadowID uuid.UUID) {
	tok, exp, err := s.Tokens.Issue(shadowID)
	if err != nil {
		s.respondErr(w, err)
		return
	}
	writeJSON(w, status, authResp{ShadowID: shadowID, Token: tok, ExpiresAt: exp})
}

func (s *Server) audit(q *identitydb.Queries, r *http.Request, action string, shadowID uuid.UUID, reason string) error {
	return q.InsertAccessLog(r.Context(), identitydb.InsertAccessLogParams{
		Actor: actorSelf, Action: action,
		ShadowID: uuid.NullUUID{UUID: shadowID, Valid: shadowID != uuid.Nil},
		Reason:   reason,
	})
}

// ageOn menghitung umur penuh pada tanggal now.
func ageOn(birth, now time.Time) int {
	y := now.Year() - birth.Year()
	if now.Month() < birth.Month() || (now.Month() == birth.Month() && now.Day() < birth.Day()) {
		y--
	}
	return y
}

// errCommitThen: transaksi tetap di-commit (mis. menambah hitungan percobaan), lalu err dikembalikan.
type errCommitThen struct{ err error }

func (e errCommitThen) Error() string { return e.err.Error() }
