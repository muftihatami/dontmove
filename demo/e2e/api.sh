#!/usr/bin/env bash
# Uji API ujung-ke-ujung LEWAT pintu masuk (Caddy :8088), persis jalur yang dipakai aplikasi web.
# Butuh: curl, jq, IDLOG = file log JSON svc-identity (untuk membaca kode OTP uji).
set -euo pipefail
BASE=${BASE:-http://localhost:8088}
: "${IDLOG:?IDLOG wajib diisi}"
pass=0
ok() { pass=$((pass + 1)); echo "✓ $1"; }
die() { echo "✗ $1"; exit 1; }
J=(-H 'Content-Type: application/json')

otp() { # channel tujuan → challenge_id yang sudah terverifikasi
  local id code
  id=$(curl -sf "${J[@]}" -X POST "$BASE/identity/v1/otp/start" -d "{\"channel\":\"$1\",\"destination\":\"$2\"}" | jq -r .challenge_id)
  for _ in $(seq 1 20); do
    code=$(grep -F "\"challenge_id\":\"$id\"" "$IDLOG" | tail -1 | jq -r '.code // empty' || true)
    [ -n "$code" ] && break
    sleep 0.2
  done
  [ -n "$code" ] || die "kode OTP untuk $1 tidak muncul di log"
  curl -sf "${J[@]}" -X POST "$BASE/identity/v1/otp/verify" -d "{\"challenge_id\":\"$id\",\"code\":\"$code\"}" -o /dev/null
  echo "$id"
}

register() { # email hp perangkat [tanggal_lahir] → token
  local e p
  e=$(otp email "$1"); p=$(otp phone "$2")
  curl -s "${J[@]}" -X POST "$BASE/identity/v1/register" -d "{\"email_challenge_id\":\"$e\",\"email\":\"$1\",\"phone_challenge_id\":\"$p\",\"phone\":\"$2\",\"birth_date\":\"${4:-1998-04-12}\",\"device_fingerprint\":\"$3\"}"
}

api() { local tok=$1; shift; curl -sf "${J[@]}" -H "Authorization: Bearer $tok" "$@"; }

# --- halaman web disajikan, termasuk rute dalam (try_files) ---
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")" = 200 ] && curl -s "$BASE/" | grep -q 'flutter' && ok "aplikasi web disajikan di /"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/thread/abc")" = 200 ] && ok "rute dalam jatuh ke index.html"
curl -sI "$BASE/" | grep -qi '^server:' && die "header Server bocor" || ok "header Server disembunyikan"

# --- daftar tiga orang lewat /identity ---
TA=$(register sekar@uji.dev 081200000001 a0a0a0a0a0a0a0a0a0 | jq -r .token)
TB=$(register bayu@uji.dev 081200000002 b0b0b0b0b0b0b0b0b0 | jq -r .token)
TC=$(register citra@uji.dev 081200000003 c0c0c0c0c0c0c0c0c0 | jq -r .token)
[ ${#TA} -gt 40 ] && [ ${#TB} -gt 40 ] && [ ${#TC} -gt 40 ] && ok "tiga akun terdaftar lewat pintu masuk"

young=$(register muda@uji.dev 081200000009 d0d0d0d0d0d0d0d0d0 2012-01-01 | jq -r .code)
[ "$young" = "not_eligible" ] && ok "usia di bawah 17 ditolak (not_eligible)"
again=$(register sekar@uji.dev 081200000001 e0e0e0e0e0e0e0e0e0 | jq -r .code)
[ "$again" = "already_registered" ] || [ "$again" = "device_not_allowed" ] && ok "email/HP yang sama ditolak ($again)"

# --- konten lewat /api ---
T1=$(api "$TA" -X POST "$BASE/api/v1/threads" -d '{"body":"Sudah tiga bulan saya belum berani cerita ke siapa pun soal kerjaan baru. Semua orang kira saya bahagia karena gajinya naik. Padahal tiap Minggu malam rasanya mau muntah."}' | jq -r .thread.id)
api "$TB" -X POST "$BASE/api/v1/threads" -d '{"body":"Ada yang pernah resign tanpa rencana? Gimana rasanya bulan pertama?"}' >/dev/null
api "$TC" -X POST "$BASE/api/v1/threads" -d '{"body":"Hari ini ulang tahun ibu. Sudah lima tahun saya tidak pulang dan tidak ada yang tanya kenapa."}' >/dev/null
ok "tiga thread ditulis"

C1=$(api "$TB" -X POST "$BASE/api/v1/threads/$T1/comments" -d '{"body":"Minggu malam itu paling berat ya. Aku dulu juga begitu waktu pindah kantor. Badan yang tahu duluan sebelum kepala."}' | jq -r .comment.id)
api "$TA" -X POST "$BASE/api/v1/threads/$T1/comments" -d "{\"body\":\"Iya persis. Kamu akhirnya gimana?\",\"parent_id\":\"$C1\"}" >/dev/null
api "$TC" -X POST "$BASE/api/v1/threads/$T1/comments" -d '{"body":"Gaji naik tapi tiap minggu mual itu bukan tukar yang adil. Yang bikin berat orangnya atau kerjaannya?"}' >/dev/null
ok "tiga komentar, termasuk balasan penulis"

d=$(api "$TC" "$BASE/api/v1/threads/$T1")
[ "$(jq '.comments | length' <<<"$d")" = 3 ] && ok "thread berisi 3 komentar"
[ "$(jq '[.comments[] | select(.is_author)] | length' <<<"$d")" = 1 ] && ok "penanda penulis tepat satu"
[ "$(jq -r '.my_alias.label' <<<"$d")" != null ] && ok "alias C tercatat setelah menulis"
echo "$d" | grep -qE 'author_id|shadow_id|created_at' && die "respons thread membocorkan id/waktu" || ok "respons thread tanpa id akun dan cap waktu"

[ "$(api "$TC" "$BASE/api/v1/feed?tab=ramai" | jq --arg t "$T1" '[.items[] | select(.id==$t)] | length')" = 1 ] && ok "thread yang dibalas masuk Ramai"
[ "$(api "$TA" "$BASE/api/v1/feed?tab=belum-dibalas" | jq '.items | length')" = 2 ] && ok "Belum dibalas untuk A: 2 thread orang lain"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/feed")" = 401 ] && ok "tanpa token ditolak 401"

echo "$TC" > "${TOKEN_OUT:-/tmp/token-c}"
echo "Lulus: $pass pemeriksaan"
