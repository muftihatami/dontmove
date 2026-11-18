-- +goose Up
-- Identity Vault: satu-satunya database yang menyimpan PII.
-- KEPUTUSAN-F0 §6 butir 1 & 2 dilipat langsung ke skema awal
-- (belum ada data produksi, jadi tidak perlu ALTER).

CREATE TABLE identity (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email_lookup  BYTEA,                 -- HMAC-SHA256(email ternormalisasi, pepper)
  phone_lookup  BYTEA,                 -- HMAC-SHA256(nomor E.164, pepper)
  email_enc     BYTEA,                 -- AES-256-GCM; kunci di KMS (dev: env)
  phone_enc     BYTEA,
  birth_date    DATE,                  -- PRD Q7. Tidak pernah dicerminkan ke Content Store.
  status        TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'banned', 'deleted')),
  banned_until  TIMESTAMPTZ,           -- status=banned + NULL = ban permanen
  deleted_at    TIMESTAMPTZ,           -- pemicu pemusnahan PII (BUKAN status)
  denylisted    BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Identitas hidup wajib lengkap.
  CONSTRAINT identity_live_complete_check CHECK (
    deleted_at IS NOT NULL
    OR (email_lookup IS NOT NULL AND phone_lookup IS NOT NULL
        AND email_enc IS NOT NULL AND phone_enc IS NOT NULL
        AND birth_date IS NOT NULL)
  ),
  -- F0 §2.6: identitas yang dimusnahkan tidak boleh menyimpan PII yang bisa dikembalikan.
  -- birth_date ikut, karena tanggal lahir juga PII.
  CONSTRAINT identity_purged_check CHECK (
    deleted_at IS NULL
    OR (email_enc IS NULL AND phone_enc IS NULL AND birth_date IS NULL)
  ),
  -- F0 §2.6: yang tidak di-denylist wajib kehilangan lookup-nya, supaya bisa mendaftar lagi.
  CONSTRAINT identity_lookup_purge_check CHECK (
    deleted_at IS NULL OR denylisted
    OR (email_lookup IS NULL AND phone_lookup IS NULL)
  ),
  -- Denylist hanya untuk identitas yang dimusnahkan dalam keadaan di-ban.
  CONSTRAINT identity_denylist_check CHECK (
    NOT denylisted OR (deleted_at IS NOT NULL AND status = 'banned')
  ),
  CONSTRAINT identity_deleted_status_check CHECK (
    status <> 'deleted' OR deleted_at IS NOT NULL
  )
);

-- F0 §2.6: UNIQUE parsial, sekaligus melayani pencocokan denylist saat registrasi.
CREATE UNIQUE INDEX identity_email_lookup_uq ON identity (email_lookup)
  WHERE email_lookup IS NOT NULL;
CREATE UNIQUE INDEX identity_phone_lookup_uq ON identity (phone_lookup)
  WHERE phone_lookup IS NOT NULL;

-- Satu identitas bisa punya beberapa device (ganti HP).
CREATE TABLE device (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  identity_id   UUID NOT NULL REFERENCES identity (id) ON DELETE RESTRICT,
  device_lookup BYTEA NOT NULL,        -- HMAC dari fingerprint perangkat
  blocked       BOOLEAN NOT NULL DEFAULT false,
  first_seen    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (identity_id, device_lookup)
);
CREATE INDEX device_lookup_idx ON device (device_lookup);

-- +goose Down
DROP TABLE device;
DROP TABLE identity;
