// Package api: dua listener HTTP Layanan Identitas.
//
//	Publik  (lewat gateway): /v1/otp/start, /v1/otp/verify, /v1/register, /v1/login
//	Internal (hanya Konten): /internal/enforce-ban, /internal/is-banned, /internal/delete-account
//
// Tidak ada satu pun endpoint yang mengembalikan email, nomor HP, atau tanggal lahir.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-identity/internal/identitydb"
	"github.com/dontmove/svc-identity/internal/otp"
	"github.com/dontmove/svc-identity/internal/token"
	"github.com/dontmove/svc-identity/internal/vaultcrypto"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	otpTTL          = 10 * time.Minute
	otpMaxAttempts  = 5
	otpPerHour      = 5
	retentionWindow = 30 * 24 * time.Hour // T3
	actorSelf       = "svc-identity"
)

type Server struct {
	Pool          *pgxpool.Pool
	Keys          *vaultcrypto.Keys
	Tokens        *token.Issuer
	Sender        otp.Sender
	InternalToken string
	MinAge        int
	Log           *slog.Logger
	Now           func() time.Time
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) q() *identitydb.Queries { return identitydb.New(s.Pool) }

func (s *Server) PublicRouter() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	// Sengaja TIDAK memakai middleware.Logger / RealIP: IP per-request tidak dicatat (Prinsip 4).
	r.Get("/healthz", s.health)
	r.Post("/v1/otp/start", s.otpStart)
	r.Post("/v1/otp/verify", s.otpVerify)
	r.Post("/v1/register", s.register)
	r.Post("/v1/login", s.login)
	return r
}

func (s *Server) InternalRouter() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	r.Get("/healthz", s.health)
	r.Group(func(r chi.Router) {
		r.Use(s.requireInternalToken)
		r.Post("/internal/enforce-ban", s.enforceBan)
		r.Get("/internal/is-banned", s.isBanned)
		r.Post("/internal/delete-account", s.deleteAccount)
	})
	return r
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if err := s.Pool.Ping(r.Context()); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "Layanan sedang tidak tersedia.")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) requireInternalToken(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.InternalToken)) != 1 {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "Tidak diizinkan.")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// inTx menjalankan fn dalam satu transaksi dengan Queries yang terikat ke tx.
func (s *Server) inTx(ctx context.Context, fn func(q *identitydb.Queries) error) error {
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if err := fn(identitydb.New(tx)); err != nil {
		var ct errCommitThen
		if errors.As(err, &ct) {
			if cerr := tx.Commit(ctx); cerr != nil {
				return cerr
			}
			return ct.err
		}
		return err
	}
	return tx.Commit(ctx)
}

// apiError membawa respons yang aman ditampilkan ke pengguna.
type apiError struct {
	status  int
	code    string
	message string
}

func (e *apiError) Error() string { return e.code }

func fail(status int, code, msg string) error { return &apiError{status, code, msg} }

func (s *Server) respondErr(w http.ResponseWriter, err error) {
	var ae *apiError
	if errors.As(err, &ae) {
		writeErr(w, ae.status, ae.code, ae.message)
		return
	}
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

func decode(r *http.Request, v any) error {
	d := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 16<<10))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return fail(http.StatusBadRequest, "bad_request", "Permintaan tidak valid.")
	}
	return nil
}

func isUniqueViolation(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && pg.Code == "23505"
}

func isNoRows(err error) bool { return errors.Is(err, pgx.ErrNoRows) }
