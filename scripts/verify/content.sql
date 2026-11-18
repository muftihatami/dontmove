-- Uji invariant Content Store. Jalankan setelah migrasi:
--   psql "$CONTENT_DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/verify/content.sql
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

-- F0 §6 butir 8: tidak ada tabel reaksi/like dalam bentuk apa pun.
DO $$
DECLARE t text;
BEGIN
  SELECT string_agg(table_name, ', ') INTO t FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name ~* '(reaction|like|upvote|vote|applause|kudos|favorite|favourite)';
  IF t IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: T7 dilanggar, ditemukan tabel %', t;
  END IF;
  RAISE NOTICE 'OK  tidak ada tabel reaksi (T7)';
END $$;

-- A1: Content Store tidak boleh punya kolom yang berbau identitas.
DO $$
DECLARE c text;
BEGIN
  SELECT string_agg(table_name || '.' || column_name, ', ') INTO c FROM information_schema.columns
  WHERE table_schema = 'public'
    AND column_name ~* '(email|phone|device|identity|birth|lat|lon|lng|ip_addr|ipaddr)';
  IF c IS NOT NULL THEN
    RAISE EXCEPTION 'GAGAL: A1 dilanggar, kolom berbau PII di Content Store: %', c;
  END IF;
  RAISE NOTICE 'OK  tidak ada kolom PII di Content Store (A1)';
END $$;

INSERT INTO account (shadow_id) VALUES ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b');
-- ID 900001+ supaya tidak bentrok dengan kolam alias hasil seed (00006).
INSERT INTO alias_pool VALUES (900001, 'Uji Satu', '#E8A33D'), (900002, 'Uji Dua', '#3D6FE8');
INSERT INTO thread (id, author_id, body) VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'halo');
INSERT INTO thread_participant VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 900001);
INSERT INTO comment (thread_id, author_id, body) VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'hai');
INSERT INTO conversation (id, origin_thread_id, initiator_id, recipient_id, origin_snippet, initiator_alias_id, recipient_alias_id, expires_at)
VALUES ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a', 'halo', 900002, 900001, now() + interval '48 hours');
INSERT INTO message (conversation_id, sender_id, body) VALUES ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'pesan pembuka');

SELECT pg_temp.must_fail('hapus keras account (nisan)',      $q$DELETE FROM account$q$);
SELECT pg_temp.must_fail('hapus keras thread',               $q$DELETE FROM thread$q$);
SELECT pg_temp.must_fail('hapus keras comment',              $q$DELETE FROM comment$q$);
SELECT pg_temp.must_fail('hapus keras conversation (T4)',    $q$DELETE FROM conversation$q$);
SELECT pg_temp.must_fail('hapus keras message',              $q$DELETE FROM message$q$);
SELECT pg_temp.must_fail('TRUNCATE ... CASCADE pada thread',  $q$TRUNCATE thread CASCADE$q$);
SELECT pg_temp.must_fail('TRUNCATE ... CASCADE pada account', $q$TRUNCATE account CASCADE$q$);
SELECT pg_temp.must_fail('alias ganda di satu thread',
  $q$INSERT INTO thread_participant VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 900001)$q$);
SELECT pg_temp.must_fail('percakapan kedua untuk pasangan + thread yang sama',
  $q$INSERT INTO conversation (origin_thread_id, initiator_id, recipient_id, origin_snippet, initiator_alias_id, recipient_alias_id, expires_at)
     VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 'x', 900001, 900002, now())$q$);
SELECT pg_temp.must_fail('percakapan tanpa origin_snippet (T4)',
  $q$INSERT INTO conversation (origin_thread_id, initiator_id, recipient_id, initiator_alias_id, recipient_alias_id, expires_at)
     VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 900001, 900002, now())$q$);
SELECT pg_temp.must_fail('status deleted tanpa deleted_at',  $q$UPDATE account SET status = 'deleted'$q$);
SELECT pg_temp.must_fail('thread nearby tanpa geo_cell',
  $q$INSERT INTO thread (author_id, body, scope) VALUES ('00000000-0000-0000-0000-00000000000a', 'x', 'nearby')$q$);

-- K3: balasan bersarang maksimal satu tingkat, dan selalu di thread yang sama.
INSERT INTO thread (id, author_id, body) VALUES ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000b', 'thread lain');
INSERT INTO comment (id, thread_id, author_id, body) VALUES
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'komentar atas');
INSERT INTO comment (id, thread_id, parent_id, author_id, body) VALUES
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'balasan satu tingkat');
DO $$ BEGIN RAISE NOTICE 'OK  balasan satu tingkat diterima (K3)'; END $$;
SELECT pg_temp.must_fail('balasan dua tingkat (K3)',
  $q$INSERT INTO comment (thread_id, parent_id, author_id, body)
     VALUES ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'x')$q$);
SELECT pg_temp.must_fail('balasan ke komentar di thread lain',
  $q$INSERT INTO comment (thread_id, parent_id, author_id, body)
     VALUES ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'x')$q$);
SELECT pg_temp.must_fail('memindahkan komentar ke induk lain',
  $q$UPDATE comment SET parent_id = '30000000-0000-0000-0000-000000000001' WHERE id <> '30000000-0000-0000-0000-000000000001' AND parent_id IS NULL$q$);

-- T4: thread dihapus (lunak) → percakapan tetap terbaca tanpa join ke thread.
UPDATE thread SET deleted_at = now();
DO $$ BEGIN
  IF (SELECT origin_snippet FROM conversation) <> 'halo' THEN RAISE EXCEPTION 'GAGAL: T4'; END IF;
  RAISE NOTICE 'OK  percakapan bertahan setelah thread dihapus (T4)';
END $$;

-- T2: akun dihapus → jadi nisan, tulisannya tetap ada.
UPDATE account SET status = 'deleted', deleted_at = now() WHERE shadow_id = '00000000-0000-0000-0000-00000000000b';
DO $$ BEGIN
  IF (SELECT count(*) FROM comment WHERE author_id = '00000000-0000-0000-0000-00000000000b') <> 2 OR (SELECT count(*) FROM message) <> 1 THEN RAISE EXCEPTION 'GAGAL: T2'; END IF;
  RAISE NOTICE 'OK  tulisan tetap ada setelah akun dihapus (T2)';
END $$;

DO $$ BEGIN RAISE NOTICE 'Content Store: semua invariant bekerja'; END $$;
ROLLBACK;
