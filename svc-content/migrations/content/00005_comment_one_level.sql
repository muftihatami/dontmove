-- +goose Up
-- K3 (18 Nov 2026): balasan bersarang maksimal satu tingkat.
-- Membalas sebuah balasan → aplikasi menulis parent_id = komentar induknya (tingkat atas),
-- dengan rujukan nama yang dibalas di badan teks. Database menolak bentuk lain, supaya
-- fungsi penyaring sub-pohon untuk blokir (§moderasi) cukup menangani satu tingkat.
-- +goose StatementBegin
CREATE FUNCTION comment_one_level() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  p_thread UUID;
  p_parent UUID;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.parent_id IS DISTINCT FROM OLD.parent_id OR NEW.thread_id <> OLD.thread_id THEN
      RAISE EXCEPTION 'parent_id dan thread_id komentar tidak boleh diubah'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.parent_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT thread_id, parent_id INTO p_thread, p_parent FROM comment WHERE id = NEW.parent_id;
  IF NOT FOUND THEN
    RETURN NEW; -- biar foreign key yang menolak
  END IF;
  IF p_parent IS NOT NULL THEN
    RAISE EXCEPTION 'K3: balasan hanya boleh satu tingkat (induk % sudah berupa balasan)', NEW.parent_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_thread <> NEW.thread_id THEN
    RAISE EXCEPTION 'balasan harus berada di thread yang sama dengan induknya'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
-- +goose StatementEnd

CREATE TRIGGER comment_one_level BEFORE INSERT OR UPDATE ON comment
  FOR EACH ROW EXECUTE FUNCTION comment_one_level();

-- +goose Down
DROP TRIGGER comment_one_level ON comment;
DROP FUNCTION comment_one_level();
