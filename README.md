# Don't Move — Backend

**F0 Fondasi** (selesai, CI hijau 18 Nov 2026): implementasi `KEPUTUSAN-F0-Dont-Move.md` — dua database terpisah,
Layanan Identitas, registrasi + OTP, token, `shadow_link`, log akses, job purge, dan penjaga G1–G4.

**F1 Timeline** (18 Nov 2026): thread, komentar, feed tiga tab, alias per-thread, kuota, hapus tulisan sendiri.
Lihat bagian *F1 Timeline* di bawah.

## Struktur

```
pkg/identity-client/   Kontrak bersama: DTO + klien HTTP. Tanpa tipe database. (G1)
svc-identity/          Layanan Identitas — satu-satunya pemegang kredensial Identity Vault
  migrations/identity/   skema Vault (goose)
  queries/identity/      query sqlc → internal/identitydb (G2)
  cmd/identity           server: listener publik :8081 + listener internal :8082
  cmd/purge              job harian (shadow_link 30 hari, denylist sementara, OTP basi)
  cmd/keygen             kunci acak untuk lokal
svc-content/           Layanan Konten — hanya kenal Content Store
  migrations/content/    skema Content Store lengkap untuk v1 (minus blokir/laporan → F3)
  queries/content/       query sqlc → internal/contentdb (G2)
scripts/guard.sh       G1–G4
scripts/verify/*.sql   uji constraint di database sungguhan
```

## Peta ke KEPUTUSAN-F0 §6

| # | Item | Di mana |
|---|---|---|
| 1 | `identity` nullable + `deleted_at` + `denylisted` + 2 CHECK | `svc-identity/migrations/identity/00001_identity_device.sql` |
| 2 | UNIQUE parsial `email_lookup`/`phone_lookup` | idem |
| 3 | `shadow_link.purge_after` + `legal_hold` + indeks | `00002_shadow_link.sql` |
| 4 | Job purge harian → `vault_access_log` | `svc-identity/internal/purge`, `cmd/purge` |
| 5 | `account.deleted_at`, status `deleted` | `svc-content/migrations/content/00001_account.sql` |
| 6 | CASCADE → RESTRICT | `00002_alias_thread.sql`, `00003_comment.sql` |
| 7 | `conversation` berdiri sendiri, status `closed` | `00004_conversation_message.sql` |
| 8 | Tidak ada tabel `reaction` | ditegakkan `scripts/verify/content.sql` |
| 9 | G1 dua modul | `go.mod` terpisah + `scripts/guard.sh` |
| 10 | G2 dua konfigurasi sqlc | `*/sqlc.yaml` + `scripts/guard.sh` + `sqlc diff` di CI |
| 11 | G3 satu DSN | `svc-content/internal/config/config_test.go` + jaringan compose + `scripts/guard.sh` |
| 12 | G4 penjaga CI | `scripts/guard.sh` + `scripts/g4-allowlist.txt` + `.github/CODEOWNERS` |

Belum ada data produksi, jadi butir 1–7 ditulis sebagai skema awal (`CREATE`), bukan `ALTER`.

## Menjalankan

```bash
make tidy                 # WAJIB sekali setelah clone: membuat go.sum (lihat catatan di bawah)
make keys                 # lalu isi .env.identity dan .env.content dari contoh *.example
docker compose up --build # Vault, Content, Redis, migrasi, kedua layanan
make check                # G1–G4 + tes unit + migrasi + uji constraint + tes integrasi
```

Alur lokal: `POST :8081/v1/otp/start` → kode muncul di log `svc-identity` (mode dev) →
`/v1/otp/verify` → `/v1/register` → token → `GET :8080/v1/me`.

## Yang sudah diverifikasi

- Tes unit + integrasi lulus terhadap PostgreSQL 16 sungguhan (register, login, OTP terkunci setelah 5 kali salah,
  umur < 17 ditolak, satu perangkat satu akun, hapus akun, ban permanen + denylist, hapus akun saat ban sementara,
  purge 30 hari + `legal_hold`, listener internal butuh token).
- Migrasi naik → turun → naik bersih di kedua database.
- `scripts/verify/*.sql`: 9 pelanggaran di Vault dan 13 di Content Store ditolak oleh database.
- `scripts/guard.sh` diuji dengan pelanggaran sengaja untuk G1, G2, G3, G4 — semuanya menggagalkan build.
- Uji ujung-ke-ujung dengan kedua layanan berjalan: tidak ada email/HP di log mana pun.

## Keputusan yang diambil saat membangun — perlu persetujuan

1. **Autentikasi langsung ke Layanan Identitas lewat gateway**, bukan diproksikan Layanan Konten.
   Diagram §3 arsitektur menulis Identitas "hanya menerima panggilan dari Layanan Konten". Kalau diikuti,
   email dan nomor HP lewat di memori dan log Konten. Dengan rute langsung, Konten tidak pernah melihatnya
   sama sekali; ia hanya memegang **kunci publik** token. Listener internal (ban, hapus akun) tetap hanya
   untuk Konten.
2. **Endpoint tambahan:** `/v1/otp/start`, `/v1/otp/verify`, `/internal/delete-account`. Tidak satu pun
   mengembalikan PII. `otp/start` menjawab sama untuk nomor terdaftar maupun tidak (anti-enumerasi).
3. **Token:** JWT EdDSA (Ed25519), berlaku 30 hari, klaim hanya `sub` = `shadow_id`.
4. **Satu perangkat = satu identitas hidup** (penegakan Keputusan 5 anti-sockpuppet). Ganti HP tetap bisa.
5. **Hapus akun saat ban sementara berjalan:** lookup HMAC tetap di denylist sampai masa ban habis, lalu job
   harian melepasnya. Tanpa ini, "hapus akun → daftar ulang" jadi jalan keluar dari ban (dilarang F0 §2.3).
6. **`birth_date` ikut dimusnahkan** dan masuk `identity_purged_check`.
7. **Hapus keras dilarang oleh trigger** (DELETE dan TRUNCATE) di `account`, `thread`, `comment`,
   `conversation`, `message`. Lebih kuat dari RESTRICT saja, karena `TRUNCATE … CASCADE` melewati FK.
8. **OTP disimpan di Vault** (hanya HMAC tujuan + HMAC kode), bukan di Redis, karena Redis milik sisi Konten.
9. **`message.undelivered`** sudah ada (dari keputusan moderasi 21 Agt).
10. **Tabel `block` dan `report` belum dibuat.** Bentuknya berubah di dokumen moderasi (asimetris, `origin_snippet`,
    `reporter_score`), jadi dibangun di F3 dari DDL dokumen itu.

## Celah di dokumen yang ditemukan saat membangun — perlu keputusan

**`legal_hold` tidak menyelamatkan kemampuan ban.** F0 §3.1 mengandaikan akun yang dilaporkan lalu menghapus diri
masih bisa di-ban selama `legal_hold`. Tapi §2.3 + `identity_lookup_purge_check` memusnahkan lookup **seketika**
saat penghapusan sukarela. Jadi walaupun `shadow_link` masih ada, tidak ada lagi yang bisa dimasukkan ke denylist:
pelaku bisa dilaporkan → hapus akun → daftar ulang dengan email dan HP yang sama besoknya.
Saat ini kode menjawab `409 identity_purged` untuk kasus itu.

Usulan perbaikan: kolom `identity.lookup_hold`. Kalau saat hapus akun ada laporan `open` (yang memang sudah
memicu `legal_hold`), lookup **ditahan** (bukan denylist) sampai laporannya diputus. Selama ditahan, email/HP itu
tidak bisa dipakai mendaftar. Kalau laporan ditolak → lookup dimusnahkan; kalau berujung ban → jadi denylist.
`identity_lookup_purge_check` diubah jadi `deleted_at IS NULL OR denylisted OR lookup_hold OR (lookup NULL)`.
Biayanya: orang yang dilaporkan lalu menghapus akun baik-baik harus menunggu laporannya selesai sebelum bisa
kembali. SLA moderasi (6 jam untuk pelecehan) membuat itu murah.

## F1 Timeline

Semua endpoint butuh `Authorization: Bearer <token>`. Kode di `svc-content/internal/api/timeline.go`,
query di `svc-content/queries/content/timeline.sql`.

| Endpoint | Fungsi | Aturan |
|---|---|---|
| `GET /v1/feed?tab=terbaru\|belum-dibalas\|ramai&cursor=&limit=` | Feed (K9) | Default `terbaru`. `next` kosong = halaman terakhir |
| `POST /v1/threads` `{"body"}` | Tulis thread | 1–1.000 karakter, 10 per 24 jam (R4). Penulis langsung mendapat alias |
| `GET /v1/threads/{id}` | Thread + komentar | `my_alias: null` = belum pernah menulis di sini. `closed` = dihapus penulisnya |
| `DELETE /v1/threads/{id}` | Hapus thread sendiri | Tanpa balasan → hilang. Ada balasan → nisan, keluar dari feed, tidak menerima balasan baru |
| `POST /v1/threads/{id}/comments` `{"body","parent_id"?}` | Komentar | 60 per 24 jam (R5). Membalas balasan → otomatis naik ke induk tingkat atas (K3). `alias_new: true` → tampilkan toast TH-02 |
| `DELETE /v1/comments/{id}` | Hapus komentar sendiri | Tanpa balasan → hilang. Tingkat atas dengan balasan → nisan |
| `GET /v1/quota` | Sisa kuota | Aplikasi menampilkan sisa thread hanya saat ≤ 3 (K5) |

Aturan yang ditegakkan:

- **Tidak ada `shadow_id`/`author_id` dan tidak ada cap waktu presisi di respons.** Klien menerima alias,
  `is_mine`, `is_author` (penanda "penulis"), dan waktu kasar ("2 mnt", "kemarin"). Kursor tab Terbaru adalah id
  thread (UUID acak), bukan waktu. Tes memeriksa respons feed tidak memuat id akun.
- **Satu definisi "komentar yang terlihat"**: fungsi SQL `visible_comments(thread, penonton)` (migrasi 00007).
  Jumlah balasan, tab Belum dibalas, tab Ramai, dan halaman thread semuanya memakainya. **F3 menambahkan penyaringan
  blokir di fungsi ini saja** — jangan buat penyaring kedua.
- **Alias lahir dari menulis, tidak dari membaca** (T7). Diambil acak dari kolam (A4); tabrakan antar-penulis
  bersamaan diulang di dalam savepoint.
- **Kuota dihitung termasuk tulisan yang sudah dihapus**, supaya hapus-lalu-kirim-ulang tidak membuka kuota.
  Tulisan satu akun diserialkan (`LockAccount`) sehingga permintaan paralel tidak bisa menembus batas.
- Tab **Belum dibalas**: thread < 24 jam tanpa balasan menurut penonton, bukan milik penonton, terlama di atas.
  Tab **Ramai**: jumlah orang berbeda (bukan penulis) yang membalas dalam 24 jam, dikelompokkan 1–2 / 3–5 / 6+,
  thread > 48 jam keluar.

Tes: `svc-content/internal/api/timeline_integration_test.go` — alur lengkap, validasi, kuota, paginasi,
30 balasan serentak (alias tidak bertabrakan), 15 thread serentak (tepat 10 lolos).

Belum di F1: chat (F2), blokir dan lapor (F3), Nearby (v2.0, kolom `scope` sudah ada).

## Belum di F0 (sengaja)

- **Pengirim OTP produksi** (penyedia SMS dan email) belum dipilih. Tanpa `IDENTITY_DEV_OTP=1`, layanan menolak
  mengirim, bukan pura-pura berhasil.
- **KMS:** pepper, kunci enkripsi, dan seed token dibaca dari env. Antarmukanya sudah dipisah supaya sumbernya
  bisa diganti tanpa mengubah pemanggil.
- **Rate limit per-IP** tidak ada, karena IP tidak dicatat (Prinsip 4). Batas yang ada: 5 OTP per tujuan per jam,
  5 percobaan per kode.
- **Ban → status akun di Content Store** diteruskan oleh konsol moderasi di F3. Sampai saat itu, token yang sudah
  terbit tetap berlaku sampai kedaluwarsa walau identitasnya di-ban.
- **Endpoint `legal_hold`** dibuat bersama alur laporan di F3.
- ~~**Kolam alias**~~ di-seed di F1: 1.310 label (`00006_alias_pool_seed.sql`).

## Catatan go.sum

`go.sum` dibuat dengan `make tidy` dan sudah di-commit. CI memeriksa `go mod tidy -diff`, jadi dependensi baru
tanpa go.sum yang diperbarui akan ketahuan.
