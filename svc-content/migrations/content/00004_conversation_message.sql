-- +goose Up
-- ★ Percakapan pribadi. F0 §6 butir 7 / T4: berdiri sendiri.
-- origin_snippet & kedua alias DISALIN saat lahir, tidak pernah di-join ulang saat render.
CREATE TABLE conversation (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  origin_thread_id    UUID NOT NULL REFERENCES thread (id) ON DELETE RESTRICT,  -- hanya untuk moderasi
  initiator_id        UUID NOT NULL REFERENCES account (shadow_id),
  recipient_id        UUID NOT NULL REFERENCES account (shadow_id),
  origin_snippet      TEXT NOT NULL CHECK (char_length(origin_snippet) BETWEEN 1 AND 200),
  initiator_alias_id  INT  NOT NULL REFERENCES alias_pool (id),
  recipient_alias_id  INT  NOT NULL REFERENCES alias_pool (id),
  status              TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'active', 'declined', 'expired', 'closed')),
  expires_at          TIMESTAMPTZ NOT NULL,          -- 48 jam saat pending
  last_message_at     TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (initiator_id <> recipient_id)
);

-- Satu pasang orang + satu thread = maksimal satu percakapan.
CREATE UNIQUE INDEX conversation_unique_pair ON conversation (
  origin_thread_id,
  LEAST(initiator_id, recipient_id),
  GREATEST(initiator_id, recipient_id)
);

CREATE TRIGGER conversation_no_hard_delete BEFORE DELETE ON conversation
  FOR EACH ROW EXECUTE FUNCTION forbid_hard_delete();
CREATE TRIGGER conversation_no_truncate BEFORE TRUNCATE ON conversation
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_hard_delete();

CREATE TABLE message (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  UUID NOT NULL REFERENCES conversation (id) ON DELETE RESTRICT,
  sender_id        UUID NOT NULL REFERENCES account (shadow_id),
  body             TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
  -- Moderasi (21 Agt): pesan ke orang yang memblokir pengirim disimpan tapi tidak pernah sampai.
  -- Tidak ikut terkirim saat unblock; tetap ada sebagai bukti untuk moderator.
  undelivered      BOOLEAN NOT NULL DEFAULT false,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at       TIMESTAMPTZ
);
CREATE INDEX message_conversation_idx ON message (conversation_id, created_at);

CREATE TRIGGER message_no_hard_delete BEFORE DELETE ON message
  FOR EACH ROW EXECUTE FUNCTION forbid_hard_delete();
CREATE TRIGGER message_no_truncate BEFORE TRUNCATE ON message
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_hard_delete();

-- F0 §6 butir 8: TIDAK ADA tabel reaction. Ditegakkan oleh scripts/verify/content.sql.

-- +goose Down
DROP TRIGGER message_no_truncate ON message;
DROP TRIGGER message_no_hard_delete ON message;
DROP TABLE message;
DROP TRIGGER conversation_no_truncate ON conversation;
DROP TRIGGER conversation_no_hard_delete ON conversation;
DROP TABLE conversation;
