package api

// Tes integrasi F1 Timeline terhadap Content Store sungguhan (butuh migrasi 00001–00007 + seed alias).
// Jalankan: CONTENT_TEST_DATABASE_URL=postgres://… go test ./internal/api/

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-content/internal/auth"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

type tl struct {
	t    *testing.T
	srv  *httptest.Server
	priv ed25519.PrivateKey
	pool *pgxpool.Pool
}

type user struct {
	id  uuid.UUID
	tok string
}

func newTL(t *testing.T) *tl {
	dsn := os.Getenv("CONTENT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("CONTENT_TEST_DATABASE_URL tidak diisi")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	s := &Server{Pool: pool, Verifier: auth.Verifier{Key: pub}, Identity: &fakeIdentity{},
		Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	srv := httptest.NewServer(s.Router())
	t.Cleanup(func() { srv.Close(); pool.Close() })
	return &tl{t: t, srv: srv, priv: priv, pool: pool}
}

func (x *tl) user() user {
	id := uuid.New()
	tok, _ := jwt.NewWithClaims(jwt.SigningMethodEdDSA, jwt.RegisteredClaims{
		Subject: id.String(), Issuer: ic.TokenIssuer, Audience: jwt.ClaimStrings{ic.TokenAudience},
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}).SignedString(x.priv)
	return user{id, tok}
}

// call mengembalikan status, body mentah, dan body ter-decode.
func (x *tl) call(u user, method, path string, in any) (int, string, map[string]any) {
	x.t.Helper()
	var rd io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, x.srv.URL+path, rd)
	req.Header.Set("Authorization", "Bearer "+u.tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		x.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, string(raw), out
}

func (x *tl) mustCall(u user, want int, method, path string, in any) map[string]any {
	x.t.Helper()
	st, raw, out := x.call(u, method, path, in)
	if st != want {
		x.t.Fatalf("%s %s: mau %d, dapat %d: %s", method, path, want, st, raw)
	}
	return out
}

// feedFind mencari thread di sebuah tab, menelusuri semua halaman; nil kalau tidak ada.
// (Database tes tidak pernah dikosongkan — tidak ada hapus keras — jadi thread lain bisa
// mengisi halaman pertama, terutama di Belum dibalas yang mendahulukan thread terlama.)
func (x *tl) feedFind(u user, tab, id string) map[string]any {
	x.t.Helper()
	cursor := ""
	for page := 0; page < 500; page++ {
		out := x.mustCall(u, 200, "GET", "/v1/feed?limit=50&tab="+tab+"&cursor="+cursor, nil)
		for _, it := range out["items"].([]any) {
			m := it.(map[string]any)
			if m["id"] == id {
				return m
			}
		}
		if cursor = out["next"].(string); cursor == "" {
			return nil
		}
	}
	x.t.Fatal("feed tidak selesai setelah 500 halaman")
	return nil
}

func alias(m map[string]any) string { return m["alias"].(map[string]any)["label"].(string) }

func TestTimelineFlow(t *testing.T) {
	x := newTL(t)
	a, b, c := x.user(), x.user(), x.user()

	// --- A menulis thread: alias lahir, sisa kuota 9 ---
	out := x.mustCall(a, 201, "POST", "/v1/threads", map[string]string{"body": "  Sudah tiga bulan saya belum berani cerita.  "})
	th := out["thread"].(map[string]any)
	tid := th["id"].(string)
	if th["is_mine"] != true || th["body"] != "Sudah tiga bulan saya belum berani cerita." || alias(th) == "" {
		t.Fatalf("thread baru salah: %v", th)
	}
	if out["threads_remaining"].(float64) != 9 {
		t.Fatalf("sisa kuota: %v", out["threads_remaining"])
	}
	aAlias := alias(th)

	// --- B melihatnya di Terbaru dan Belum dibalas; A tidak melihat thread sendiri di Belum dibalas ---
	_, raw, _ := x.call(b, "GET", "/v1/feed?limit=50", nil)
	for _, secret := range []string{a.id.String(), b.id.String(), "author_id", "shadow_id", "created_at"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("feed membocorkan %q", secret)
		}
	}
	if it := x.feedFind(b, "terbaru", tid); it == nil || it["is_mine"] != false || it["reply_count"].(float64) != 0 {
		t.Fatalf("Terbaru untuk B: %v", it)
	}
	if x.feedFind(b, "belum-dibalas", tid) == nil {
		t.Fatal("thread tanpa balasan harus ada di Belum dibalas")
	}
	if x.feedFind(a, "belum-dibalas", tid) != nil {
		t.Fatal("thread sendiri tidak boleh muncul di Belum dibalas")
	}
	if x.feedFind(b, "ramai", tid) != nil {
		t.Fatal("thread tanpa balasan tidak boleh di Ramai")
	}

	// --- Membaca tidak membuat alias (T7) ---
	d := x.mustCall(b, 200, "GET", "/v1/threads/"+tid, nil)
	if d["my_alias"] != nil {
		t.Fatal("membaca tidak boleh memberi alias")
	}
	var n int
	x.pool.QueryRow(context.Background(), `SELECT count(*) FROM thread_participant WHERE thread_id = $1`, tid).Scan(&n)
	if n != 1 {
		t.Fatalf("peserta setelah dibaca: mau 1, dapat %d", n)
	}

	// --- B membalas: alias baru, berbeda dari A, konsisten di balasan kedua ---
	o1 := x.mustCall(b, 201, "POST", "/v1/threads/"+tid+"/comments", map[string]string{"body": "Minggu malam itu paling berat ya."})
	c1 := o1["comment"].(map[string]any)
	if o1["alias_new"] != true || alias(c1) == aAlias || c1["is_author"] != false {
		t.Fatalf("komentar pertama B: %v", o1)
	}
	o2 := x.mustCall(b, 201, "POST", "/v1/threads/"+tid+"/comments", map[string]string{"body": "Aku juga dulu begitu."})
	if o2["alias_new"] != false || alias(o2["comment"].(map[string]any)) != alias(c1) {
		t.Fatalf("alias B harus konsisten: %v", o2)
	}
	c1id := c1["id"].(string)

	// --- A (penulis) membalas komentar B: penanda penulis ---
	o3 := x.mustCall(a, 201, "POST", "/v1/threads/"+tid+"/comments", map[string]any{"body": "Iya persis.", "parent_id": c1id})
	rep := o3["comment"].(map[string]any)
	if rep["is_author"] != true || alias(rep) != aAlias || rep["parent_id"] != c1id || o3["alias_new"] != false {
		t.Fatalf("balasan penulis: %v", o3)
	}

	// --- K3: C membalas BALASAN → dinormalkan ke komentar tingkat atas ---
	o4 := x.mustCall(c, 201, "POST", "/v1/threads/"+tid+"/comments", map[string]any{"body": "@Penulis aku juga.", "parent_id": rep["id"]})
	if o4["comment"].(map[string]any)["parent_id"] != c1id {
		t.Fatalf("balasan ke balasan harus naik ke induk tingkat atas: %v", o4)
	}

	// --- Feed sekarang: keluar dari Belum dibalas, masuk Ramai, 4 balasan ---
	if x.feedFind(c, "belum-dibalas", tid) != nil {
		t.Fatal("thread yang sudah dibalas harus keluar dari Belum dibalas")
	}
	if it := x.feedFind(c, "ramai", tid); it == nil || it["reply_count"].(float64) != 4 {
		t.Fatalf("Ramai: %v", it)
	}

	// --- B menghapus komentar tingkat atas yang punya balasan → nisan ---
	x.mustCall(b, 204, "DELETE", "/v1/comments/"+c1id, nil)
	d = x.mustCall(c, 200, "GET", "/v1/threads/"+tid, nil)
	var tomb map[string]any
	for _, it := range d["comments"].([]any) {
		if m := it.(map[string]any); m["id"] == c1id {
			tomb = m
		}
	}
	if tomb == nil || tomb["deleted"] != true || tomb["body"] != nil {
		t.Fatalf("komentar dengan balasan harus jadi nisan tanpa badan: %v", tomb)
	}
	if d["thread"].(map[string]any)["reply_count"].(float64) != 3 {
		t.Fatalf("jumlah balasan setelah nisan: %v", d["thread"])
	}

	// --- Komentar tanpa balasan dihapus → hilang total ---
	c2id := o2["comment"].(map[string]any)["id"].(string)
	x.mustCall(b, 204, "DELETE", "/v1/comments/"+c2id, nil)
	d = x.mustCall(c, 200, "GET", "/v1/threads/"+tid, nil)
	for _, it := range d["comments"].([]any) {
		if it.(map[string]any)["id"] == c2id {
			t.Fatal("komentar tanpa balasan yang dihapus harus hilang total")
		}
	}

	// --- Tidak bisa menghapus tulisan orang lain; jawabannya sama dengan "tidak ada" ---
	x.mustCall(c, 404, "DELETE", "/v1/comments/"+rep["id"].(string), nil)
	x.mustCall(c, 404, "DELETE", "/v1/threads/"+tid, nil)

	// --- A menghapus thread yang sudah dibalas → nisan, keluar dari feed, tertutup ---
	x.mustCall(a, 204, "DELETE", "/v1/threads/"+tid, nil)
	d = x.mustCall(c, 200, "GET", "/v1/threads/"+tid, nil)
	if d["closed"] != true || d["thread"].(map[string]any)["body"] != nil {
		t.Fatalf("thread dihapus harus nisan + tertutup: %v", d["thread"])
	}
	if x.feedFind(c, "terbaru", tid) != nil || x.feedFind(c, "ramai", tid) != nil {
		t.Fatal("thread dihapus harus keluar dari feed")
	}
	if st, _, out := x.call(c, "POST", "/v1/threads/"+tid+"/comments", map[string]string{"body": "halo"}); st != 410 || out["code"] != "thread_closed" {
		t.Fatalf("membalas thread tertutup: %d %v", st, out)
	}

	// --- Thread tanpa balasan yang dihapus → hilang total ---
	t2 := x.mustCall(a, 201, "POST", "/v1/threads", map[string]string{"body": "salah kirim"})["thread"].(map[string]any)["id"].(string)
	x.mustCall(a, 204, "DELETE", "/v1/threads/"+t2, nil)
	x.mustCall(b, 404, "GET", "/v1/threads/"+t2, nil)
}

func TestTimelineValidationAndQuota(t *testing.T) {
	x := newTL(t)
	u := x.user()

	for _, body := range []string{"", "   ", strings.Repeat("a", 1001)} {
		if st, _, _ := x.call(u, "POST", "/v1/threads", map[string]string{"body": body}); st != 400 {
			t.Fatalf("badan %d karakter: mau 400, dapat %d", len(body), st)
		}
	}
	x.mustCall(u, 201, "POST", "/v1/threads", map[string]string{"body": strings.Repeat("é", 1000)}) // 1.000 karakter, bukan byte

	for i := 2; i <= threadQuota; i++ {
		x.mustCall(u, 201, "POST", "/v1/threads", map[string]string{"body": fmt.Sprintf("thread %d", i)})
	}
	st, _, out := x.call(u, "POST", "/v1/threads", map[string]string{"body": "satu lagi"})
	if st != 429 || out["code"] != "quota_exceeded" || out["retry_at"] == nil {
		t.Fatalf("kuota thread: %d %v", st, out)
	}
	q := x.mustCall(u, 200, "GET", "/v1/quota", nil)
	if q["threads_remaining"].(float64) != 0 || q["comments_remaining"].(float64) != commentQuota {
		t.Fatalf("kuota: %v", q)
	}

	// Menghapus thread tidak mengembalikan kuota (mencegah hapus-lalu-kirim-ulang).
	feed := x.mustCall(u, 200, "GET", "/v1/feed?limit=50", nil)["items"].([]any)
	for _, it := range feed {
		if m := it.(map[string]any); m["is_mine"] == true {
			x.mustCall(u, 204, "DELETE", "/v1/threads/"+m["id"].(string), nil)
			break
		}
	}
	if st, _, _ := x.call(u, "POST", "/v1/threads", map[string]string{"body": "coba lagi"}); st != 429 {
		t.Fatalf("hapus thread tidak boleh mengembalikan kuota: dapat %d", st)
	}

	x.mustCall(u, 400, "GET", "/v1/feed?tab=terkait", nil)
	x.mustCall(u, 404, "GET", "/v1/threads/bukan-uuid", nil)
}

func TestFeedLatestPagination(t *testing.T) {
	x := newTL(t)
	u := x.user()
	var ids []string
	for i := 0; i < 5; i++ {
		th := x.mustCall(u, 201, "POST", "/v1/threads", map[string]string{"body": fmt.Sprintf("halaman %d", i)})
		ids = append(ids, th["thread"].(map[string]any)["id"].(string))
	}
	seen := map[string]bool{}
	cursor := ""
	for page := 0; page < 200 && len(seen) < len(ids); page++ {
		out := x.mustCall(u, 200, "GET", "/v1/feed?limit=2&cursor="+cursor, nil)
		for _, it := range out["items"].([]any) {
			id := it.(map[string]any)["id"].(string)
			if seen[id] {
				t.Fatalf("thread %s muncul dua kali", id)
			}
			for _, mine := range ids {
				if id == mine {
					seen[id] = true
				}
			}
		}
		cursor = out["next"].(string)
		if cursor == "" {
			break
		}
	}
	if len(seen) != len(ids) {
		t.Fatalf("paginasi kehilangan thread: %d dari %d", len(seen), len(ids))
	}
}

func TestRelTime(t *testing.T) {
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	cases := map[time.Duration]string{
		10 * time.Second: "baru saja", 2 * time.Minute: "2 mnt", 59 * time.Minute: "59 mnt",
		3 * time.Hour: "3 jam", 30 * time.Hour: "kemarin", 3 * 24 * time.Hour: "3 hari",
		10 * 24 * time.Hour: "1 mgg", 60 * 24 * time.Hour: "2 bln", 400 * 24 * time.Hour: "lebih dari setahun",
	}
	for d, want := range cases {
		if got := relTime(now.Add(-d), now); got != want {
			t.Errorf("%v: mau %q, dapat %q", d, want, got)
		}
	}
}

func TestConcurrentAliasAndQuota(t *testing.T) {
	x := newTL(t)
	owner := x.user()
	tid := x.mustCall(owner, 201, "POST", "/v1/threads", map[string]string{"body": "ramai-ramai"})["thread"].(map[string]any)["id"].(string)

	// 30 orang membalas bersamaan: semua berhasil, dan tidak ada dua orang dengan alias yang sama.
	type res struct {
		st    int
		alias string
	}
	ch := make(chan res, 30)
	for i := 0; i < 30; i++ {
		u := x.user()
		go func() {
			st, _, out := x.call(u, "POST", "/v1/threads/"+tid+"/comments", map[string]string{"body": "aku juga"})
			a := ""
			if st == 201 {
				a = alias(out["comment"].(map[string]any))
			}
			ch <- res{st, a}
		}()
	}
	seen := map[string]bool{}
	for i := 0; i < 30; i++ {
		r := <-ch
		if r.st != 201 {
			t.Fatalf("balasan paralel gagal: %d", r.st)
		}
		if seen[r.alias] {
			t.Fatalf("alias %q dipakai dua orang di thread yang sama", r.alias)
		}
		seen[r.alias] = true
	}

	// Satu orang mengirim 15 thread bersamaan: tepat 10 yang lolos.
	u := x.user()
	sts := make(chan int, 15)
	for i := 0; i < 15; i++ {
		go func(i int) {
			st, _, _ := x.call(u, "POST", "/v1/threads", map[string]string{"body": fmt.Sprintf("paralel %d", i)})
			sts <- st
		}(i)
	}
	ok, limited := 0, 0
	for i := 0; i < 15; i++ {
		switch <-sts {
		case 201:
			ok++
		case 429:
			limited++
		}
	}
	if ok != threadQuota || limited != 15-threadQuota {
		t.Fatalf("kuota paralel: %d lolos, %d ditahan", ok, limited)
	}
}
