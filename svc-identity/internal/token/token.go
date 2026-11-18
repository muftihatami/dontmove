// Package token menerbitkan token akses bertanda tangan Ed25519.
// Klaimnya hanya sub (shadow_id), iss, aud, iat, exp. Tidak ada yang lain, dan tidak akan ada.
package token

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

type Issuer struct {
	priv ed25519.PrivateKey
	ttl  time.Duration
	now  func() time.Time
}

func NewIssuer(seed []byte, ttl time.Duration) (*Issuer, error) {
	if len(seed) != ed25519.SeedSize {
		return nil, errors.New("seed Ed25519 harus 32 byte")
	}
	return &Issuer{priv: ed25519.NewKeyFromSeed(seed), ttl: ttl, now: time.Now}, nil
}

func (i *Issuer) Issue(shadowID uuid.UUID) (string, time.Time, error) {
	now := i.now()
	exp := now.Add(i.ttl)
	claims := jwt.RegisteredClaims{
		Subject:   shadowID.String(),
		Issuer:    ic.TokenIssuer,
		Audience:  jwt.ClaimStrings{ic.TokenAudience},
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(exp),
	}
	s, err := jwt.NewWithClaims(jwt.SigningMethodEdDSA, claims).SignedString(i.priv)
	return s, exp, err
}

// PublicKeyBase64 adalah nilai untuk CONTENT_TOKEN_PUBLIC_KEY.
func (i *Issuer) PublicKeyBase64() string {
	return base64.StdEncoding.EncodeToString(i.priv.Public().(ed25519.PublicKey))
}
