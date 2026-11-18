package api

import "github.com/dontmove/svc-identity/internal/otp"

// ctxKeyForTest membaca challenge_id yang disisipkan otp.WithChallengeID.
func ctxKeyForTest() any { return otp.ChallengeIDKey() }
