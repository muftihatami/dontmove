#!/usr/bin/env bash
# Menjalankan Don't Move untuk uji di HP (Codespaces atau mesin dengan Docker).
#   bash demo/start.sh            # jalankan
#   bash demo/start.sh --update   # ambil build aplikasi terbaru lalu jalankan ulang
# Data uji saja. OTP tidak dikirim: kodenya tampil di terminal ini.
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f docker-compose.yml -f demo/compose.demo.yml)

[ "${1:-}" = "--update" ] && rm -rf demo/web

# 1. Kunci acak untuk uji (produksi: KMS). Dibuat sekali.
if [ ! -s .env.identity ] || [ ! -s .env.content ]; then
  echo "→ Membuat kunci uji…"
  keys=$(docker run --rm -v "$PWD":/src -w /src/svc-identity golang:1.23-alpine go run ./cmd/keygen)
  grep -E '^IDENTITY_(PEPPER|ENC_KEY|TOKEN_SEED|INTERNAL_TOKEN)=' <<<"$keys" > .env.identity
  grep -E '^(CONTENT_TOKEN_PUBLIC_KEY|IDENTITY_INTERNAL_TOKEN)=' <<<"$keys" > .env.content
fi

# 2. Build web aplikasi: unduh dari GitHub Actions, atau bangun di sini kalau gagal.
if [ ! -f demo/web/index.html ]; then
  mkdir -p demo/web
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  run=""
  [ -n "$repo" ] && run=$(gh run list -R "$repo" -w app --branch main --status success -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  if [ -n "$run" ] && gh run download "$run" -R "$repo" -n web-build -D demo/web 2>/dev/null; then
    echo "→ Build aplikasi diambil dari GitHub Actions (run $run)."
  else
    echo "→ Membangun aplikasi di sini dengan Docker (sekitar 5 menit, hanya sekali)…"
    docker run --rm -v "$PWD/app":/app -w /app ghcr.io/cirruslabs/flutter:stable bash -c \
      "flutter create --platforms=web --project-name dontmove --org id.dontmove . >/dev/null && flutter pub get >/dev/null && flutter build web --release"
    cp -r app/build/web/. demo/web/
  fi
fi

# 3. Jalankan semua layanan.
echo "→ Menjalankan layanan…"
"${COMPOSE[@]}" up -d --build
[ "${1:-}" = "--update" ] && "${COMPOSE[@]}" restart web >/dev/null

# 4. Alamat untuk HP.
if [ -n "${CODESPACE_NAME:-}" ]; then
  gh codespace ports visibility 8088:public -c "$CODESPACE_NAME" >/dev/null
  url="https://${CODESPACE_NAME}-8088.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
else
  url="http://localhost:8088"
fi
cat <<MSG

──────────────────────────────────────────────
 Don't Move siap diuji. Buka di Safari iPhone:

   $url

 Daftar memakai email dan nomor HP apa saja (format valid).
 Kode verifikasi muncul di bawah ini. Ctrl+C hanya menutup
 tampilan kode; layanan tetap berjalan.
──────────────────────────────────────────────
MSG
"${COMPOSE[@]}" logs -f --no-log-prefix --since 1s svc-identity 2>/dev/null \
  | grep --line-buffered 'DEV OTP' \
  | sed -u -E 's/.*channel=([a-z]+).*code=([0-9]+).*/  Kode \1: \2/'
