-- Akun dibuat malas saat permintaan pertama dengan token sah.
-- Layanan Konten tidak pernah melihat email/HP, bahkan sekadar lewat.
-- name: EnsureAccount :exec
INSERT INTO account (shadow_id) VALUES ($1)
ON CONFLICT (shadow_id) DO NOTHING;

-- name: GetAccount :one
SELECT shadow_id, status, created_at, deleted_at FROM account WHERE shadow_id = $1;

-- name: MarkAccountDeleted :exec
UPDATE account SET status = 'deleted', deleted_at = now()
WHERE shadow_id = $1 AND deleted_at IS NULL;
