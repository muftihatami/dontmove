-- +goose Up
-- Kolam alias. Diisi sekali saat seeding (1.000 label, disaring manual sebelum F1 selesai).
CREATE TABLE alias_pool (
  id         INT PRIMARY KEY,
  label      TEXT NOT NULL UNIQUE,
  color_hex  TEXT NOT NULL CHECK (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  active     BOOLEAN NOT NULL DEFAULT true
);

-- ★ Objek generik. Timeline dan Nearby sama-sama thread.
CREATE TABLE thread (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id      UUID NOT NULL REFERENCES account (shadow_id),
  body           TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 1000),
  scope          TEXT NOT NULL DEFAULT 'global' CHECK (scope IN ('global', 'nearby')),
  geo_cell       TEXT,                       -- indeks H3, NULL kalau global (v2.0)
  reply_count    INT NOT NULL DEFAULT 0,     -- ANGKA MENTAH. Jangan pernah dikirim ke klien (arsitektur §6.2).
  last_activity  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at     TIMESTAMPTZ,
  CHECK ((scope = 'nearby') = (geo_cell IS NOT NULL))
);
CREATE INDEX thread_feed_idx ON thread (scope, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX thread_geo_idx  ON thread (geo_cell, created_at DESC) WHERE scope = 'nearby';

CREATE TRIGGER thread_no_hard_delete BEFORE DELETE ON thread
  FOR EACH ROW EXECUTE FUNCTION forbid_hard_delete();
CREATE TRIGGER thread_no_truncate BEFORE TRUNCATE ON thread
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_hard_delete();

-- ★ Tempat alias hidup. Satu baris = satu topeng.
-- F0 §6 butir 6: RESTRICT, bukan CASCADE. Alias tetap tinggal walau pemiliknya pergi (T2).
CREATE TABLE thread_participant (
  thread_id  UUID NOT NULL REFERENCES thread (id) ON DELETE RESTRICT,
  shadow_id  UUID NOT NULL REFERENCES account (shadow_id),
  alias_id   INT  NOT NULL REFERENCES alias_pool (id),
  joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (thread_id, shadow_id),
  UNIQUE (thread_id, alias_id)
);

-- +goose Down
DROP TABLE thread_participant;
DROP TRIGGER thread_no_truncate ON thread;
DROP TRIGGER thread_no_hard_delete ON thread;
DROP TABLE thread;
DROP TABLE alias_pool;
