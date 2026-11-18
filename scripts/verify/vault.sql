-- Uji constraint Identity Vault: setiap pelanggaran HARUS ditolak database.
-- Jalankan setelah migrasi:  psql "$VAULT_DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/verify/vault.sql
-- Semua dalam satu transaksi yang di-ROLLBACK, jadi aman di database mana pun.
\o /dev/null
BEGIN;

CREATE FUNCTION pg_temp.must_fail(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN check_violation OR unique_violation OR not_null_violation
            OR foreign_key_violation OR restrict_violation THEN
    RAISE NOTICE 'OK  ditolak: %', label;
    RETURN;
  END;
  RAISE EXCEPTION 'GAGAL: % seharusnya ditolak database', label;
END $$;

INSERT INTO identity (id, email_lookup, phone_lookup, email_enc, phone_enc, birth_date)
VALUES ('00000000-0000-0000-0000-000000000001', 'e1', 'p1', 'x', 'y', '1990-01-01');

SELECT pg_temp.must_fail('identitas hidup tanpa email_enc',
  $q$INSERT INTO identity (email_lookup, phone_lookup, phone_enc, birth_date) VALUES ('e2','p2','y','1990-01-01')$q$);
SELECT pg_temp.must_fail('identity_purged_check: dihapus tapi email_enc masih ada',
  $q$UPDATE identity SET deleted_at = now(), status = 'deleted', email_lookup = NULL, phone_lookup = NULL, phone_enc = NULL, birth_date = NULL$q$);
SELECT pg_temp.must_fail('identity_purged_check: dihapus tapi birth_date masih ada',
  $q$UPDATE identity SET deleted_at = now(), status = 'deleted', email_lookup = NULL, phone_lookup = NULL, email_enc = NULL, phone_enc = NULL$q$);
SELECT pg_temp.must_fail('identity_lookup_purge_check: hapus sukarela tapi lookup disimpan',
  $q$UPDATE identity SET deleted_at = now(), status = 'deleted', email_enc = NULL, phone_enc = NULL, birth_date = NULL$q$);
SELECT pg_temp.must_fail('denylist pada identitas hidup',
  $q$UPDATE identity SET denylisted = true$q$);
SELECT pg_temp.must_fail('status deleted tanpa deleted_at',
  $q$UPDATE identity SET status = 'deleted'$q$);
SELECT pg_temp.must_fail('email_lookup ganda',
  $q$INSERT INTO identity (email_lookup, phone_lookup, email_enc, phone_enc, birth_date) VALUES ('e1','p9','x','y','1990-01-01')$q$);
SELECT pg_temp.must_fail('identity dengan shadow_link tidak bisa dihapus keras',
  $q$INSERT INTO shadow_link VALUES ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-000000000001');
     DELETE FROM identity$q$);
SELECT pg_temp.must_fail('log akses tanpa alasan',
  $q$INSERT INTO vault_access_log (actor, action, reason) VALUES ('x', 'y', '  ')$q$);

-- Bentuk yang SAH harus diterima: ban permanen (PII musnah, lookup disimpan).
UPDATE identity SET status = 'banned', deleted_at = now(), denylisted = true,
       email_enc = NULL, phone_enc = NULL, birth_date = NULL;
-- Lookup NULL boleh berulang (unique parsial).
INSERT INTO identity (email_lookup, phone_lookup, status, deleted_at) VALUES (NULL, NULL, 'deleted', now()), (NULL, NULL, 'deleted', now());

DO $$ BEGIN RAISE NOTICE 'Vault: semua constraint bekerja'; END $$;
ROLLBACK;
