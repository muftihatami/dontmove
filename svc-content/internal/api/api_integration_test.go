package api

// Tes integrasi terhadap Content Store sungguhan.
// Jalankan: CONTENT_TEST_DATABASE_URL=postgres://… go test ./internal/api/
// Content Store menolak DELETE/TRUNCATE, jadi tes memakai shadow_id baru tiap skenario.

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-content/internal/auth"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

type fakeIdentity struct{ deleted []uuid.UUID }

func (f *fakeIdentity) DeleteAccount(_ context.Context, r ic.DeleteAccountRequest) error {
	f.deleted = append(f.deleted, r.ShadowID)
	return nil
}

func TestAuthAccountAndDelete(t *testing.T) {
	dsn := os.Getenv("CONTENT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("CONTENT_TEST_DATABASE_URL tidak diisi")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	fi := &fakeIdentity{}
	s := &Server{Pool: pool, Verifier: auth.Verifier{Key: pub}, Identity: fi,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	srv := httptest.NewServer(s.Router())
	defer srv.Close()

	id := uuid.New()
	tok, _ := jwt.NewWithClaims(jwt.SigningMethodEdDSA, jwt.RegisteredClaims{
		Subject: id.String(), Issuer: ic.TokenIssuer, Audience: jwt.ClaimStrings{ic.TokenAudience},
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}).SignedString(priv)

	do := func(method, path, bearer string) int {
		req, _ := http.NewRequest(method, srv.URL+path, nil)
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	if st := do("GET", "/v1/me", ""); st != 401 {
		t.Fatalf("tanpa token: mau 401, dapat %d", st)
	}
	if st := do("GET", "/v1/me", tok); st != 200 {
		t.Fatalf("token sah: mau 200, dapat %d", st)
	}
	var status string
	if err := pool.QueryRow(ctx, `SELECT status FROM account WHERE shadow_id = $1`, id).Scan(&status); err != nil || status != "active" {
		t.Fatalf("akun harus dibuat otomatis: %q %v", status, err)
	}
	if st := do("POST", "/v1/account/delete", tok); st != 204 {
		t.Fatalf("hapus akun: mau 204, dapat %d", st)
	}
	if len(fi.deleted) != 1 || fi.deleted[0] != id {
		t.Fatal("Layanan Identitas harus dipanggil untuk memusnahkan PII")
	}
	// Token lama tidak berlaku lagi, dan akun tidak "hidup kembali" lewat EnsureAccount.
	if st := do("GET", "/v1/me", tok); st != 401 {
		t.Fatalf("token setelah hapus akun: mau 401, dapat %d", st)
	}
	pool.QueryRow(ctx, `SELECT status FROM account WHERE shadow_id = $1`, id).Scan(&status)
	if status != "deleted" {
		t.Fatalf("akun harus tetap nisan, dapat %q", status)
	}
}
