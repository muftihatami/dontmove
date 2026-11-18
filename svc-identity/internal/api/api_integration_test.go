package api

// Tes integrasi terhadap Identity Vault sungguhan.
// Jalankan: VAULT_TEST_DATABASE_URL=postgres://… go test ./internal/api/
// (migrasi harus sudah dijalankan; tes mengosongkan tabel sebelum tiap skenario).
// Query mentah di file _test.go diizinkan G2 hanya untuk fixture dan pemeriksaan.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-identity/internal/purge"
	"github.com/dontmove/svc-identity/internal/token"
	"github.com/dontmove/svc-identity/internal/vaultcrypto"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const internalTok = "test-internal-token-0123456789abcdef"

type captureSender struct {
	mu    sync.Mutex
	codes map[string]string // challenge_id → code
}

func (c *captureSender) Send(ctx context.Context, _, _ string, code string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	id, _ := ctx.Value(ctxKeyForTest()).(string)
	c.codes[id] = code
	return nil
}

type env struct {
	t        *testing.T
	pool     *pgxpool.Pool
	pub, int *httptest.Server
	sender   *captureSender
}

func setup(t *testing.T) *env {
	dsn := os.Getenv("VAULT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("VAULT_TEST_DATABASE_URL tidak diisi")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, `TRUNCATE vault_access_log, otp_challenge, shadow_link, device, identity RESTART IDENTITY CASCADE`); err != nil {
		t.Fatal(err)
	}
	keys, _ := vaultcrypto.New(bytes.Repeat([]byte{7}, 32), bytes.Repeat([]byte{8}, 32))
	iss, _ := token.NewIssuer(bytes.Repeat([]byte{9}, 32), time.Hour)
	snd := &captureSender{codes: map[string]string{}}
	s := &Server{Pool: pool, Keys: keys, Tokens: iss, Sender: snd, InternalToken: internalTok, MinAge: 17,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	e := &env{t: t, pool: pool, pub: httptest.NewServer(s.PublicRouter()), int: httptest.NewServer(s.InternalRouter()), sender: snd}
	t.Cleanup(e.pub.Close)
	t.Cleanup(e.int.Close)
	return e
}

func (e *env) call(srv *httptest.Server, method, path string, body any, auth string) (int, map[string]any) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, srv.URL+path, rd)
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// verified meminta dan memverifikasi OTP, mengembalikan challenge_id.
func (e *env) verified(channel, dest string) string {
	e.t.Helper()
	st, out := e.call(e.pub, "POST", "/v1/otp/start", map[string]string{"channel": channel, "destination": dest}, "")
	if st != 202 {
		e.t.Fatalf("otp/start %d %v", st, out)
	}
	id := out["challenge_id"].(string)
	st, out = e.call(e.pub, "POST", "/v1/otp/verify", map[string]string{"challenge_id": id, "code": e.sender.codes[id]}, "")
	if st != 204 {
		e.t.Fatalf("otp/verify %d %v", st, out)
	}
	return id
}

func (e *env) register(email, phone, birth, device string) (int, map[string]any) {
	return e.call(e.pub, "POST", "/v1/register", map[string]string{
		"email_challenge_id": e.verified("email", email), "email": email,
		"phone_challenge_id": e.verified("phone", phone), "phone": phone,
		"birth_date": birth, "device_fingerprint": device,
	}, "")
}

func (e *env) login(email, device string) (int, map[string]any) {
	return e.call(e.pub, "POST", "/v1/login", map[string]string{
		"challenge_id": e.verified("email", email), "channel": "email", "destination": email,
		"device_fingerprint": device,
	}, "")
}

func (e *env) scalar(sql string, args ...any) any {
	e.t.Helper()
	var v any
	if err := e.pool.QueryRow(context.Background(), sql, args...).Scan(&v); err != nil {
		e.t.Fatalf("%s: %v", sql, err)
	}
	return v
}

const (
	devA  = "device-aaaaaaaaaaaaaaaa"
	devB  = "device-bbbbbbbbbbbbbbbb"
	devC  = "device-cccccccccccccccc"
	adult = "1995-05-17"
)

func TestRegisterLoginAndNoPIIInResponse(t *testing.T) {
	e := setup(t)
	st, out := e.register("Rina@Contoh.id", "0812-1111-2222", adult, devA)
	if st != 201 {
		t.Fatalf("register %d %v", st, out)
	}
	for k := range out {
		if k != "shadow_id" && k != "token" && k != "expires_at" {
			t.Fatalf("respons register membawa field tak terduga %q", k)
		}
	}
	shadow := out["shadow_id"].(string)

	// Email & HP tersimpan terenkripsi, bukan teks polos.
	if n := e.scalar(`SELECT count(*) FROM identity WHERE position('rina@contoh.id'::bytea in email_enc) > 0 OR position('6281211112222'::bytea in phone_enc) > 0`); n.(int64) != 0 {
		t.Fatal("email tersimpan polos")
	}

	st, out = e.login("rina@contoh.id", devA)
	if st != 200 || out["shadow_id"] != shadow {
		t.Fatalf("login %d %v", st, out)
	}
	// Sudah terdaftar → 409, bukan akun kedua.
	if st, _ := e.register("rina@contoh.id", "081211112222", adult, devB); st != 409 {
		t.Fatalf("daftar ulang: mau 409, dapat %d", st)
	}
	// Setiap operasi tercatat.
	if n := e.scalar(`SELECT count(*) FROM vault_access_log WHERE shadow_id = $1`, shadow); n.(int64) != 2 {
		t.Fatalf("mau 2 baris log (register, login), dapat %v", n)
	}
}

func TestUnderageRefused(t *testing.T) {
	e := setup(t)
	young := time.Now().AddDate(-16, 0, 0).Format(time.DateOnly)
	if st, out := e.register("muda@contoh.id", "081233334444", young, devA); st != 403 || out["code"] != "not_eligible" {
		t.Fatalf("mau 403 not_eligible, dapat %d %v", st, out)
	}
}

func TestOneLiveIdentityPerDevice(t *testing.T) {
	e := setup(t)
	if st, _ := e.register("satu@contoh.id", "081200000001", adult, devA); st != 201 {
		t.Fatal("register pertama gagal")
	}
	if st, out := e.register("dua@contoh.id", "081200000002", adult, devA); st != 403 || out["code"] != "device_not_allowed" {
		t.Fatalf("akun kedua di perangkat sama: mau 403, dapat %d %v", st, out)
	}
}

func TestOTPLockout(t *testing.T) {
	e := setup(t)
	_, out := e.call(e.pub, "POST", "/v1/otp/start", map[string]string{"channel": "email", "destination": "x@contoh.id"}, "")
	id := out["challenge_id"].(string)
	for i := 0; i < otpMaxAttempts; i++ {
		if st, _ := e.call(e.pub, "POST", "/v1/otp/verify", map[string]string{"challenge_id": id, "code": "000000x"}, ""); st != 400 {
			t.Fatalf("percobaan %d: mau 400, dapat %d", i, st)
		}
	}
	if st, _ := e.call(e.pub, "POST", "/v1/otp/verify", map[string]string{"challenge_id": id, "code": e.sender.codes[id]}, ""); st != 429 {
		t.Fatalf("setelah %d kali salah, kode benar pun harus ditolak; dapat %d", otpMaxAttempts, st)
	}
}

func TestVoluntaryDeleteFreesEverything(t *testing.T) {
	e := setup(t)
	_, out := e.register("pergi@contoh.id", "081255556666", adult, devA)
	shadow := out["shadow_id"].(string)
	if st, out := e.call(e.int, "POST", "/internal/delete-account", ic.DeleteAccountRequest{ShadowID: uuid.MustParse(shadow), Reason: "permintaan pengguna"}, internalTok); st != 204 {
		t.Fatalf("delete %d %v", st, out)
	}
	if v := e.scalar(`SELECT count(*) FROM identity WHERE email_enc IS NOT NULL OR email_lookup IS NOT NULL OR birth_date IS NOT NULL`); v.(int64) != 0 {
		t.Fatal("PII atau lookup tersisa setelah penghapusan sukarela")
	}
	if v := e.scalar(`SELECT purge_after > now() + interval '29 days' FROM shadow_link WHERE shadow_id = $1`, shadow); v != true {
		t.Fatal("purge_after harus ±30 hari")
	}
	// Bisa mendaftar lagi, di perangkat yang sama, dan mendapat shadow_id baru.
	st, out := e.register("pergi@contoh.id", "081255556666", adult, devA)
	if st != 201 || out["shadow_id"] == shadow {
		t.Fatalf("daftar ulang setelah hapus: %d %v", st, out)
	}
}

func TestPermanentBanDenylistsAndBlocksDevice(t *testing.T) {
	e := setup(t)
	_, out := e.register("jahat@contoh.id", "081277778888", adult, devA)
	shadow := uuid.MustParse(out["shadow_id"].(string))
	req := ic.EnforceBanRequest{ShadowID: shadow, Mode: ic.BanPermanent, Actor: "mod-1+mod-2", Reason: "pelecehan berulang"}
	if st, out := e.call(e.int, "POST", "/internal/enforce-ban", req, internalTok); st != 204 {
		t.Fatalf("ban %d %v", st, out)
	}
	if v := e.scalar(`SELECT email_enc IS NULL AND phone_enc IS NULL AND email_lookup IS NOT NULL AND denylisted FROM identity`); v != true {
		t.Fatal("ban permanen: PII harus musnah, lookup harus tersimpan")
	}
	if st, out := e.register("jahat@contoh.id", "081299990000", adult, devB); st != 403 || out["code"] != "not_allowed" {
		t.Fatalf("email di denylist: mau 403 not_allowed, dapat %d %v", st, out)
	}
	if st, out := e.register("baru@contoh.id", "081299990001", adult, devA); st != 403 || out["code"] != "device_not_allowed" {
		t.Fatalf("perangkat diblokir: mau 403, dapat %d %v", st, out)
	}
	if st, _ := e.login("jahat@contoh.id", devC); st != 403 {
		t.Fatalf("login akun ban permanen: mau 403, dapat %d", st)
	}
	_, out = e.call(e.int, "GET", "/internal/is-banned?shadow_id="+shadow.String()+"&actor=mod-1&reason=cek", nil, internalTok)
	if out["banned"] != true {
		t.Fatal("is-banned harus true")
	}
}

func TestDeleteDuringTemporaryBanDoesNotEvadeIt(t *testing.T) {
	e := setup(t)
	_, out := e.register("kabur@contoh.id", "081211110000", adult, devA)
	shadow := uuid.MustParse(out["shadow_id"].(string))
	until := time.Now().Add(7 * 24 * time.Hour)
	ban := ic.EnforceBanRequest{ShadowID: shadow, Mode: ic.BanTemporary, Until: &until, Actor: "mod-1", Reason: "spam"}
	if st, out := e.call(e.int, "POST", "/internal/enforce-ban", ban, internalTok); st != 204 {
		t.Fatalf("ban sementara %d %v", st, out)
	}
	if st, _ := e.login("kabur@contoh.id", devA); st != 403 {
		t.Fatal("login saat ban sementara harus ditolak")
	}
	e.call(e.int, "POST", "/internal/delete-account", ic.DeleteAccountRequest{ShadowID: shadow, Reason: "permintaan pengguna"}, internalTok)
	if st, _ := e.register("kabur@contoh.id", "081211110000", adult, devB); st != 403 {
		t.Fatalf("hapus akun tidak boleh menjadi jalan keluar dari ban; dapat %d", st)
	}

	// Masa ban habis → job harian melepas denylist → orangnya boleh kembali.
	if _, err := e.pool.Exec(context.Background(), `UPDATE identity SET banned_until = now() - interval '1 minute'`); err != nil {
		t.Fatal(err)
	}
	res, err := purge.Run(context.Background(), e.pool, time.Now())
	if err != nil || res.DenylistReleased != 1 {
		t.Fatalf("purge: %+v %v", res, err)
	}
	if st, out := e.register("kabur@contoh.id", "081211110000", adult, devA); st != 201 {
		t.Fatalf("setelah masa ban habis harus bisa daftar lagi; dapat %d %v", st, out)
	}
}

func TestPurgeJobRespectsRetentionAndLegalHold(t *testing.T) {
	e := setup(t)
	var shadows []uuid.UUID
	for i, d := range []string{devA, devB, devC} {
		_, out := e.register(
			[]string{"a@contoh.id", "b@contoh.id", "c@contoh.id"}[i],
			[]string{"081200000011", "081200000012", "081200000013"}[i], adult, d)
		id := uuid.MustParse(out["shadow_id"].(string))
		shadows = append(shadows, id)
		e.call(e.int, "POST", "/internal/delete-account", ic.DeleteAccountRequest{ShadowID: id, Reason: "permintaan pengguna"}, internalTok)
	}
	ctx := context.Background()
	// [0] lewat 30 hari, [1] lewat 30 hari tapi legal_hold, [2] belum 30 hari.
	e.pool.Exec(ctx, `UPDATE shadow_link SET purge_after = now() - interval '1 day' WHERE shadow_id = ANY($1)`, []uuid.UUID{shadows[0], shadows[1]})
	e.pool.Exec(ctx, `UPDATE shadow_link SET legal_hold = true WHERE shadow_id = $1`, shadows[1])

	res, err := purge.Run(ctx, e.pool, time.Now())
	if err != nil || res.ShadowLinks != 1 {
		t.Fatalf("mau tepat 1 shadow_link dimusnahkan: %+v %v", res, err)
	}
	if v := e.scalar(`SELECT count(*) FROM shadow_link WHERE shadow_id = ANY($1)`, []uuid.UUID{shadows[1], shadows[2]}); v.(int64) != 2 {
		t.Fatal("shadow_link [1] (legal_hold) dan [2] (belum 30 hari) harus tersisa")
	}
	if v := e.scalar(`SELECT count(*) FROM vault_access_log WHERE action = 'shadow_link.purge' AND shadow_id = $1`, shadows[0]); v.(int64) != 1 {
		t.Fatal("pemusnahan harus tercatat di vault_access_log")
	}
	// Setelah jalurnya putus, ban tidak bisa ditegakkan — dan konsol diberi tahu apa adanya (T3 §3.5).
	st, out := e.call(e.int, "POST", "/internal/enforce-ban", ic.EnforceBanRequest{ShadowID: shadows[0], Mode: ic.BanPermanent, Actor: "mod", Reason: "x"}, internalTok)
	if st != 410 {
		t.Fatalf("mau 410 link_purged, dapat %d %v", st, out)
	}
}

func TestInternalRequiresToken(t *testing.T) {
	e := setup(t)
	if st, _ := e.call(e.int, "POST", "/internal/delete-account", ic.DeleteAccountRequest{ShadowID: uuid.New(), Reason: "x"}, "salah"); st != 401 {
		t.Fatalf("mau 401, dapat %d", st)
	}
	// Endpoint internal tidak ada di listener publik.
	if st, _ := e.call(e.pub, "POST", "/internal/delete-account", nil, internalTok); st != 404 {
		t.Fatalf("listener publik tidak boleh punya /internal; dapat %d", st)
	}
}
