// Package api — HTTP Layanan Konten. F0: autentikasi, akun, hapus akun. F1: timeline (timeline.go).
// Chat (F2) menumpuk di atas router ini.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-content/internal/auth"
	"github.com/dontmove/svc-content/internal/contentdb"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Identity adalah bagian klien Layanan Identitas yang dipakai di sini (bisa di-mock di tes).
type Identity interface {
	DeleteAccount(ctx context.Context, req ic.DeleteAccountRequest) error
}

type Server struct {
	Pool     *pgxpool.Pool
	Verifier auth.Verifier
	Identity Identity
	Log      *slog.Logger
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	// Sengaja tanpa middleware.Logger / RealIP: IP per-request tidak dicatat (arsitektur Prinsip 4).
	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := s.Pool.Ping(r.Context()); err != nil {
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "Layanan sedang tidak tersedia.")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	r.Group(func(r chi.Router) {
		r.Use(s.authenticate)
		r.Get("/v1/me", s.me)
		r.Post("/v1/account/delete", s.deleteAccount)

		// F1 Timeline (timeline.go)
		r.Get("/v1/feed", s.feed)
		r.Get("/v1/quota", s.quota)
		r.Post("/v1/threads", s.createThread)
		r.Get("/v1/threads/{id}", s.getThread)
		r.Delete("/v1/threads/{id}", s.deleteThread)
		r.Post("/v1/threads/{id}/comments", s.createComment)
		r.Delete("/v1/comments/{id}", s.deleteComment)
	})
	return r
}

// authenticate: verifikasi token, buat baris account kalau belum ada, tolak akun yang tidak aktif.
func (s *Server) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := s.Verifier.Verify(auth.Bearer(r))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "Sesi berakhir. Silakan masuk lagi.")
			return
		}
		q := contentdb.New(s.Pool)
		if err := q.EnsureAccount(r.Context(), id); err != nil {
			s.internal(w, err)
			return
		}
		acc, err := q.GetAccount(r.Context(), id)
		if err != nil {
			s.internal(w, err)
			return
		}
		switch acc.Status {
		case "active":
		case "deleted":
			writeErr(w, http.StatusUnauthorized, "unauthorized", "Sesi berakhir. Silakan masuk lagi.")
			return
		default: // suspended, banned
			writeErr(w, http.StatusForbidden, "account_restricted", "Akunmu sedang ditangguhkan.")
			return
		}
		next.ServeHTTP(w, r.WithContext(auth.WithShadowID(r.Context(), id)))
	})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	// Sengaja minim. Tidak ada profil — itu inti produknya.
	writeJSON(w, http.StatusOK, map[string]string{"status": "active"})
}

// deleteAccount — T2: tulisan tetap ada, pemiliknya diputus.
// Urutan: Vault dulu (memusnahkan PII), baru nisan di Content Store. Keduanya idempoten,
// jadi kalau langkah kedua gagal, klien cukup mengulang.
func (s *Server) deleteAccount(w http.ResponseWriter, r *http.Request) {
	id := auth.ShadowID(r.Context())
	err := s.Identity.DeleteAccount(r.Context(), ic.DeleteAccountRequest{ShadowID: id, Reason: "permintaan pengguna"})
	var se *ic.StatusError
	if errors.As(err, &se) && se.Status == http.StatusGone {
		err = nil // jalur sudah diputus sebelumnya; cukup pastikan nisannya ada
	}
	if err != nil {
		s.internal(w, err)
		return
	}
	if err := contentdb.New(s.Pool).MarkAccountDeleted(r.Context(), id); err != nil {
		s.internal(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) internal(w http.ResponseWriter, err error) {
	s.Log.Error("internal error", "err", err)
	writeErr(w, http.StatusInternalServerError, "internal", "Terjadi kesalahan. Coba lagi sebentar lagi.")
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, ic.ErrorResponse{Code: code, Message: msg})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
