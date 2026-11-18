#!/usr/bin/env bash
# Penjaga G1–G4 (KEPUTUSAN-F0 §1.2). Pengganti jaminan compiler yang hilang karena memilih Go.
# Jalankan dari root repo:  ./scripts/guard.sh        (exit ≠ 0 = build gagal)
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() { echo "✗ $1"; fail=1; }
ok()  { echo "✓ $1"; }

# --- G1: dua modul terpisah; svc-content tidak pernah meng-import svc-identity -------------
g1=0
if grep -q 'svc-identity' svc-content/go.mod; then
  bad "G1: svc-content/go.mod menyebut svc-identity"; g1=1
fi
if grep -rn --include='*.go' 'dontmove/svc-identity' svc-content pkg; then
  bad "G1: import svc-identity ditemukan di svc-content/ atau pkg/"; g1=1
fi
if grep -rn --include='*.go' 'dontmove/svc-content' svc-identity pkg; then
  bad "G1: import svc-content ditemukan di svc-identity/ atau pkg/"; g1=1
fi
if command -v go >/dev/null && [ -z "${GUARD_SKIP_GOLIST:-}" ]; then
  if ! deps=$(cd svc-content && go list -deps ./... 2>&1); then
    echo "$deps" | tail -5
    bad "G1: go list gagal — jalankan 'make tidy' dulu (penjaga tidak boleh lulus tanpa memeriksa)"; g1=1
  elif echo "$deps" | grep -q 'dontmove/svc-identity'; then
    bad "G1: svc-content bergantung (transitif) pada svc-identity"; g1=1
  fi
fi
# pkg/identity-client hanya boleh berisi DTO + klien HTTP: tanpa driver database.
if grep -rnE --include='*.go' 'jackc/pgx|database/sql|identitydb|contentdb' pkg; then
  bad "G1: pkg/identity-client menyentuh database"; g1=1
fi
[ $g1 -eq 0 ] && ok "G1: modul terpisah"

# --- G2: query hanya lewat sqlc; SQL mentah dilarang di luar internal/*db ------------------
# File *_test.go dikecualikan: tes boleh memakai SQL untuk fixture dan pemeriksaan.
g2=0
files=$(find svc-identity svc-content -name '*.go' ! -name '*_test.go' ! -path '*/internal/*db/*')
if [ -n "$files" ]; then
  if grep -nE '\.(Query|QueryRow|Exec|SendBatch|CopyFrom)\(' $files | grep -vE 'URL\.Query\(\)'; then
    bad "G2: eksekusi query langsung di luar internal/*db (pakai query sqlc)"; g2=1
  fi
  if grep -niE '"[[:space:]]*(select|insert|update|delete|with|truncate|alter|drop)[[:space:]]' $files; then
    bad "G2: string SQL mentah di luar internal/*db"; g2=1
  fi
  if grep -nE '"database/sql"|lib/pq' $files; then
    bad "G2: database/sql atau lib/pq dipakai langsung"; g2=1
  fi
fi
[ $g2 -eq 0 ] && ok "G2: SQL hanya lewat sqlc"

# --- G3: svc-content hanya punya satu DSN --------------------------------------------------
# Struct Config dicek oleh svc-content/internal/config/config_test.go (reflection).
# Di sini: tidak ada env var Vault yang dibaca di mana pun di svc-content.
g3=0
if grep -rnE --include='*.go' 'VAULT_|IDENTITY_(PEPPER|ENC_KEY|TOKEN_SEED)' svc-content pkg; then
  bad "G3: svc-content membaca konfigurasi milik Vault/Identitas"; g3=1
fi
if grep -nE 'VAULT_DATABASE_URL' <(sed -n '/^  svc-content:/,/^  [a-z]/p' docker-compose.yml); then
  bad "G3: docker-compose memberi svc-content akses ke DSN Vault"; g3=1
fi
[ $g3 -eq 0 ] && ok "G3: satu DSN untuk svc-content"

# --- G4: tujuh string terlarang di bawah svc-content/ (dan pkg/) ---------------------------
# Pengecualian hanya lewat scripts/g4-allowlist.txt, yang dijaga CODEOWNERS:
# satu baris = satu path file, diikuti alasan tertulis.
g4=0
pattern='shadow_link|identity_id|email_lookup|phone_lookup|email_enc|phone_enc|device_lookup'
allow=$(grep -vE '^\s*(#|$)' scripts/g4-allowlist.txt 2>/dev/null | awk '{print $1}')
hits=$(grep -rnIE "$pattern" svc-content pkg 2>/dev/null || true)
for a in $allow; do hits=$(printf '%s\n' "$hits" | grep -v "^$a:" || true); done
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  bad "G4: string terlarang muncul di svc-content/ atau pkg/"; g4=1
fi
[ $g4 -eq 0 ] && ok "G4: tidak ada string Vault di sisi Konten"

exit $fail
