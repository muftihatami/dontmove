-- +goose Up
-- F0 §6 butir 6: RESTRICT, bukan CASCADE.
CREATE TABLE comment (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id   UUID NOT NULL REFERENCES thread (id) ON DELETE RESTRICT,
  parent_id   UUID REFERENCES comment (id) ON DELETE RESTRICT,
  author_id   UUID NOT NULL REFERENCES account (shadow_id),
  body        TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 1000),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ
);
CREATE INDEX comment_thread_idx ON comment (thread_id, created_at);
CREATE INDEX comment_parent_idx ON comment (parent_id) WHERE parent_id IS NOT NULL;

CREATE TRIGGER comment_no_hard_delete BEFORE DELETE ON comment
  FOR EACH ROW EXECUTE FUNCTION forbid_hard_delete();
CREATE TRIGGER comment_no_truncate BEFORE TRUNCATE ON comment
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_hard_delete();

-- +goose Down
DROP TRIGGER comment_no_truncate ON comment;
DROP TRIGGER comment_no_hard_delete ON comment;
DROP TABLE comment;
