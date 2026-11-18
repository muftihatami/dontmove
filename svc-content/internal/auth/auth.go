// Package auth memverifikasi token dari Layanan Identitas dan memastikan akun Konten ada.
package auth

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"

	ic "github.com/dontmove/identity-client"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

type ctxKey struct{}

// ShadowID mengambil shadow_id pemanggil dari context. Hanya ada di route yang diautentikasi.
func ShadowID(ctx context.Context) uuid.UUID {
	id, _ := ctx.Value(ctxKey{}).(uuid.UUID)
	return id
}

func WithShadowID(ctx context.Context, id uuid.UUID) context.Context {
	return context.WithValue(ctx, ctxKey{}, id)
}

type Verifier struct{ Key ed25519.PublicKey }

var ErrInvalid = errors.New("token tidak valid")

func (v Verifier) Verify(raw string) (uuid.UUID, error) {
	claims := &jwt.RegisteredClaims{}
	_, err := jwt.ParseWithClaims(raw, claims,
		func(*jwt.Token) (any, error) { return v.Key, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodEdDSA.Alg()}),
		jwt.WithIssuer(ic.TokenIssuer),
		jwt.WithAudience(ic.TokenAudience),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return uuid.Nil, ErrInvalid
	}
	id, err := uuid.Parse(claims.Subject)
	if err != nil {
		return uuid.Nil, ErrInvalid
	}
	return id, nil
}

// Bearer mengambil token dari header Authorization.
func Bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return ""
	}
	return strings.TrimPrefix(h, "Bearer ")
}
