-- F1 Timeline. Semua jumlah balasan dan penyaringan memakai visible_comments(thread, penonton),
-- tidak pernah thread.reply_count (angka mentah, arsitektur §6.2).

-- name: ThreadQuota :one
SELECT count(*)::int AS used, COALESCE(min(created_at), now())::timestamptz AS oldest
FROM thread
WHERE author_id = $1 AND created_at > now() - interval '24 hours';

-- name: CommentQuota :one
SELECT count(*)::int AS used, COALESCE(min(created_at), now())::timestamptz AS oldest
FROM comment
WHERE author_id = $1 AND created_at > now() - interval '24 hours';

-- name: CreateThread :one
INSERT INTO thread (author_id, body) VALUES ($1, $2)
RETURNING id, created_at;

-- A4: alias diambil ACAK dari kolam, tidak diturunkan dari hash.
-- Tidak mengembalikan baris kalau orang ini sudah punya alias di thread ini, atau kolam habis.
-- name: AssignAlias :one
INSERT INTO thread_participant (thread_id, shadow_id, alias_id)
SELECT sqlc.arg(thread_id)::uuid, sqlc.arg(shadow_id)::uuid, a.id
FROM alias_pool a
WHERE a.active
  AND NOT EXISTS (SELECT 1 FROM thread_participant p
                  WHERE p.thread_id = sqlc.arg(thread_id)::uuid AND p.alias_id = a.id)
ORDER BY random()
LIMIT 1
ON CONFLICT (thread_id, shadow_id) DO NOTHING
RETURNING alias_id;

-- name: GetMyAlias :one
SELECT a.label, a.color_hex
FROM thread_participant p JOIN alias_pool a ON a.id = p.alias_id
WHERE p.thread_id = $1 AND p.shadow_id = $2;

-- name: GetThreadState :one
SELECT id, author_id, deleted_at FROM thread WHERE id = $1;

-- name: GetCommentState :one
SELECT id, thread_id, parent_id, author_id, deleted_at FROM comment WHERE id = $1;

-- name: CreateComment :one
INSERT INTO comment (thread_id, parent_id, author_id, body) VALUES ($1, $2, $3, $4)
RETURNING id, created_at;

-- name: TouchThread :exec
UPDATE thread SET reply_count = reply_count + 1, last_activity = now() WHERE id = $1;

-- Selalu boleh menghapus kata-katamu sendiri, tidak pernah kata-kata orang lain.
-- name: SoftDeleteThread :execrows
UPDATE thread SET deleted_at = now()
WHERE id = $1 AND author_id = $2 AND deleted_at IS NULL;

-- name: SoftDeleteComment :execrows
UPDATE comment SET deleted_at = now()
WHERE id = $1 AND author_id = $2 AND deleted_at IS NULL;

-- Tab Terbaru: urut waktu. Kursor = id thread terakhir (UUID acak, tidak membawa waktu).
-- name: FeedLatest :many
SELECT t.id, t.author_id, t.body, t.created_at, a.label, a.color_hex,
       (SELECT count(*) FROM visible_comments(t.id, sqlc.arg(viewer)::uuid) v
        WHERE v.deleted_at IS NULL)::int AS reply_count
FROM thread t
JOIN thread_participant p ON p.thread_id = t.id AND p.shadow_id = t.author_id
JOIN alias_pool a ON a.id = p.alias_id
WHERE t.deleted_at IS NULL AND t.scope = 'global'
  AND (sqlc.narg(cursor)::uuid IS NULL
       OR (t.created_at, t.id) < (SELECT c.created_at, c.id FROM thread c WHERE c.id = sqlc.narg(cursor)::uuid))
ORDER BY t.created_at DESC, t.id DESC
LIMIT sqlc.arg(lim)::int;

-- Tab Belum dibalas (K9): thread < 24 jam tanpa balasan menurut penonton ini,
-- bukan milik penonton sendiri; yang paling lama menunggu di atas.
-- name: FeedUnanswered :many
SELECT t.id, t.author_id, t.body, t.created_at, a.label, a.color_hex
FROM thread t
JOIN thread_participant p ON p.thread_id = t.id AND p.shadow_id = t.author_id
JOIN alias_pool a ON a.id = p.alias_id
WHERE t.deleted_at IS NULL AND t.scope = 'global'
  AND t.created_at > now() - interval '24 hours'
  AND t.author_id <> sqlc.arg(viewer)::uuid
  AND NOT EXISTS (SELECT 1 FROM visible_comments(t.id, sqlc.arg(viewer)::uuid))
ORDER BY t.created_at ASC, t.id ASC
LIMIT sqlc.arg(lim)::int OFFSET sqlc.arg(off)::int;

-- Tab Ramai (K9): jumlah ORANG berbeda (bukan penulis thread) yang membalas dalam 24 jam,
-- dikelompokkan 1–2 / 3–5 / 6+, lalu terbaru di dalam kelompok. Thread > 48 jam keluar.
-- name: FeedBusy :many
WITH scored AS (
  SELECT t.id,
         (SELECT count(DISTINCT v.author_id) FROM visible_comments(t.id, sqlc.arg(viewer)::uuid) v
          WHERE v.deleted_at IS NULL AND v.author_id <> t.author_id
            AND v.created_at > now() - interval '24 hours')::int AS repliers
  FROM thread t
  WHERE t.deleted_at IS NULL AND t.scope = 'global' AND t.created_at > now() - interval '48 hours'
)
SELECT t.id, t.author_id, t.body, t.created_at, a.label, a.color_hex,
       (SELECT count(*) FROM visible_comments(t.id, sqlc.arg(viewer)::uuid) v
        WHERE v.deleted_at IS NULL)::int AS reply_count,
       (CASE WHEN s.repliers >= 6 THEN 3 WHEN s.repliers >= 3 THEN 2 ELSE 1 END)::int AS bucket
FROM scored s
JOIN thread t ON t.id = s.id
JOIN thread_participant p ON p.thread_id = t.id AND p.shadow_id = t.author_id
JOIN alias_pool a ON a.id = p.alias_id
WHERE s.repliers >= 1
ORDER BY bucket DESC, t.created_at DESC, t.id DESC
LIMIT sqlc.arg(lim)::int OFFSET sqlc.arg(off)::int;

-- name: GetThread :one
SELECT t.id, t.author_id, t.body, t.created_at, t.deleted_at, a.label, a.color_hex
FROM thread t
JOIN thread_participant p ON p.thread_id = t.id AND p.shadow_id = t.author_id
JOIN alias_pool a ON a.id = p.alias_id
WHERE t.id = $1;

-- name: ListThreadComments :many
SELECT v.id, v.parent_id, v.author_id, v.body, v.created_at, v.deleted_at, a.label, a.color_hex
FROM visible_comments(sqlc.arg(thread_id)::uuid, sqlc.arg(viewer)::uuid) v
JOIN thread_participant p ON p.thread_id = v.thread_id AND p.shadow_id = v.author_id
JOIN alias_pool a ON a.id = p.alias_id
ORDER BY v.created_at, v.id
LIMIT 1000;

-- Memakai definisi yang sama dengan halaman thread: komentar yang tidak terlihat tidak bisa dibalas.
-- name: IsCommentVisible :one
SELECT EXISTS (
  SELECT 1 FROM visible_comments(sqlc.arg(thread_id)::uuid, sqlc.arg(viewer)::uuid) v
  WHERE v.id = sqlc.arg(comment_id)::uuid
)::bool AS visible;

-- Menyerialkan tulisan satu akun supaya kuota tidak bisa dilewati dengan permintaan paralel.
-- name: LockAccount :exec
SELECT shadow_id FROM account WHERE shadow_id = $1 FOR UPDATE;
