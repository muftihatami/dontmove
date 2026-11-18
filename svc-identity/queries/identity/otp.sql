-- name: InsertOTPChallenge :one
INSERT INTO otp_challenge (channel, dest_lookup, code_mac, expires_at)
VALUES ($1, $2, $3, $4)
RETURNING id;

-- name: CountOTPSince :one
SELECT count(*) FROM otp_challenge
WHERE dest_lookup = $1 AND created_at > $2;

-- name: GetOTPForUpdate :one
SELECT id, channel, dest_lookup, code_mac, attempts, expires_at, verified_at, consumed_at
FROM otp_challenge
WHERE id = $1
FOR UPDATE;

-- name: BumpOTPAttempts :exec
UPDATE otp_challenge SET attempts = attempts + 1 WHERE id = $1;

-- name: MarkOTPVerified :exec
UPDATE otp_challenge SET verified_at = now() WHERE id = $1;

-- name: ConsumeOTP :exec
UPDATE otp_challenge SET consumed_at = now() WHERE id = $1;

-- name: DeleteStaleOTP :execrows
DELETE FROM otp_challenge WHERE created_at < $1;
