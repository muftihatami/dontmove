-- +goose Up
-- Setiap akses ke shadow_link dicatat. Alasan wajib, bukan opsional.
CREATE TABLE vault_access_log (
  id         BIGSERIAL PRIMARY KEY,
  actor      TEXT NOT NULL CHECK (actor <> ''),
  action     TEXT NOT NULL CHECK (action <> ''),
  shadow_id  UUID,
  reason     TEXT NOT NULL CHECK (btrim(reason) <> ''),
  at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX vault_access_log_shadow_idx ON vault_access_log (shadow_id, at);

-- Tantangan OTP. Tujuan (email/HP) TIDAK disimpan: kode dikirim saat tantangan dibuat,
-- yang tersimpan hanya lookup HMAC-nya untuk dicocokkan ulang saat register/login.
CREATE TABLE otp_challenge (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel      TEXT NOT NULL CHECK (channel IN ('email', 'phone')),
  dest_lookup  BYTEA NOT NULL,
  code_mac     BYTEA NOT NULL,          -- HMAC(kode), bukan kode mentah
  attempts     INT NOT NULL DEFAULT 0,
  expires_at   TIMESTAMPTZ NOT NULL,
  verified_at  TIMESTAMPTZ,
  consumed_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX otp_challenge_dest_idx ON otp_challenge (dest_lookup, created_at);

-- +goose Down
DROP TABLE otp_challenge;
DROP TABLE vault_access_log;
