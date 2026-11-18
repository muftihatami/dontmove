-- name: FindIdentityByEmailLookup :one
SELECT id, status, banned_until, deleted_at, denylisted
FROM identity WHERE email_lookup = $1;

-- name: FindIdentityByPhoneLookup :one
SELECT id, status, banned_until, deleted_at, denylisted
FROM identity WHERE phone_lookup = $1;

-- name: InsertIdentity :one
INSERT INTO identity (email_lookup, phone_lookup, email_enc, phone_enc, birth_date)
VALUES ($1, $2, $3, $4, $5)
RETURNING id;

-- name: DeviceBlocked :one
SELECT EXISTS (
  SELECT 1 FROM device WHERE device_lookup = $1 AND blocked
);

-- Satu perangkat, satu identitas hidup (Keputusan 5: anti-sockpuppet).
-- name: DeviceHeldByOtherLiveIdentity :one
SELECT EXISTS (
  SELECT 1 FROM device d
  JOIN identity i ON i.id = d.identity_id
  WHERE d.device_lookup = sqlc.arg(device_lookup)
    AND i.deleted_at IS NULL
    AND i.id <> sqlc.arg(identity_id)
);

-- name: UpsertDevice :exec
INSERT INTO device (identity_id, device_lookup)
VALUES ($1, $2)
ON CONFLICT (identity_id, device_lookup) DO UPDATE SET last_seen = now();

-- name: DeleteDevices :exec
DELETE FROM device WHERE identity_id = $1;

-- name: BlockDevices :exec
UPDATE device SET blocked = true WHERE identity_id = $1;

-- name: InsertShadowLink :exec
INSERT INTO shadow_link (shadow_id, identity_id) VALUES ($1, $2);

-- name: GetShadowByIdentity :one
SELECT shadow_id FROM shadow_link WHERE identity_id = $1;

-- name: GetIdentityByShadowForUpdate :one
SELECT i.id, i.status, i.banned_until, i.deleted_at, i.denylisted
FROM shadow_link s
JOIN identity i ON i.id = s.identity_id
WHERE s.shadow_id = $1
FOR UPDATE OF i;

-- name: SchedulePurge :exec
UPDATE shadow_link SET purge_after = $2 WHERE shadow_id = $1;

-- name: InsertAccessLog :exec
INSERT INTO vault_access_log (actor, action, shadow_id, reason)
VALUES ($1, $2, $3, $4);

-- name: SetBan :exec
UPDATE identity SET status = 'banned', banned_until = $2 WHERE id = $1;

-- name: ReactivateExpiredBan :exec
UPDATE identity SET status = 'active', banned_until = NULL
WHERE id = $1 AND status = 'banned' AND banned_until IS NOT NULL
  AND banned_until <= now() AND deleted_at IS NULL;

-- Penghapusan sukarela (F0 §2.3 kolom tengah): semua PII dan semua lookup dimusnahkan.
-- name: PurgeVoluntary :exec
UPDATE identity
SET status = 'deleted', deleted_at = now(),
    email_enc = NULL, phone_enc = NULL, birth_date = NULL,
    email_lookup = NULL, phone_lookup = NULL
WHERE id = $1;

-- Pemusnahan dengan denylist (F0 §2.3 kolom kanan): PII yang bisa dikembalikan dimusnahkan,
-- lookup HMAC dipertahankan. Dipakai untuk ban permanen DAN hapus akun saat ban sementara aktif.
-- name: PurgeKeepDenylist :exec
UPDATE identity
SET status = 'banned', deleted_at = now(), denylisted = true,
    email_enc = NULL, phone_enc = NULL, birth_date = NULL
WHERE id = $1;

-- Job harian: identitas yang dihapus saat ban sementara aktif dilepas dari denylist
-- setelah masa ban-nya habis, lalu diperlakukan seperti penghapusan sukarela.
-- name: ReleaseExpiredTemporaryDenylist :execrows
WITH released AS (
  UPDATE identity
  SET status = 'deleted', denylisted = false, banned_until = NULL,
      email_lookup = NULL, phone_lookup = NULL
  WHERE deleted_at IS NOT NULL AND denylisted
    AND banned_until IS NOT NULL AND banned_until <= now()
  RETURNING id
), devices AS (
  DELETE FROM device d USING released r WHERE d.identity_id = r.id
)
INSERT INTO vault_access_log (actor, action, shadow_id, reason)
SELECT 'purge-job', 'denylist.release', s.shadow_id, 'masa ban sementara habis setelah akun dihapus'
FROM released r
LEFT JOIN shadow_link s ON s.identity_id = r.id;

-- Job harian, KEPUTUSAN-F0 §3.4.
-- name: PurgeExpiredShadowLinks :execrows
WITH gone AS (
  DELETE FROM shadow_link
  WHERE purge_after IS NOT NULL
    AND purge_after < now()
    AND NOT legal_hold
  RETURNING shadow_id
)
INSERT INTO vault_access_log (actor, action, shadow_id, reason)
SELECT 'purge-job', 'shadow_link.purge', shadow_id, 'retensi 30 hari terlampaui'
FROM gone;
