-- +goose Up
-- Content Store: TIDAK ADA PII. Hanya shadow_id, UUID acak tanpa arti.

-- Cermin akun. KEPUTUSAN-F0 §6 butir 5.
-- Baris account TIDAK PERNAH dihapus: ia nisan yang menjamin shadow_id tidak dipakai ulang (F0 §2.4).
CREATE TABLE account (
  shadow_id   UUID PRIMARY KEY,
  status      TEXT NOT NULL DEFAULT 'active'
              CHECK (status IN ('active', 'suspended', 'banned', 'deleted')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  CONSTRAINT account_deleted_check CHECK ((status = 'deleted') = (deleted_at IS NOT NULL))
);

-- Penghapusan keras (DELETE maupun TRUNCATE, yang melewati trigger baris) dilarang
-- di tingkat database, bukan sekadar disiplin kode.
-- +goose StatementBegin
CREATE FUNCTION forbid_hard_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'hapus keras dilarang pada tabel %: pakai deleted_at', TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$;
-- +goose StatementEnd

CREATE TRIGGER account_no_hard_delete BEFORE DELETE ON account
  FOR EACH ROW EXECUTE FUNCTION forbid_hard_delete();
CREATE TRIGGER account_no_truncate BEFORE TRUNCATE ON account
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_hard_delete();

-- +goose Down
DROP TRIGGER account_no_truncate ON account;
DROP TRIGGER account_no_hard_delete ON account;
DROP TABLE account;
DROP FUNCTION forbid_hard_delete();
