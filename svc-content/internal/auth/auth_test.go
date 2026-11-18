package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

func sign(t *testing.T, k ed25519.PrivateKey, c jwt.RegisteredClaims) string {
	t.Helper()
	s, err := jwt.NewWithClaims(jwt.SigningMethodEdDSA, c).SignedString(k)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestVerify(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	_, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	v := Verifier{Key: pub}
	id := uuid.New()
	ok := jwt.RegisteredClaims{
		Subject: id.String(), Issuer: ic.TokenIssuer, Audience: jwt.ClaimStrings{ic.TokenAudience},
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}
	got, err := v.Verify(sign(t, priv, ok))
	if err != nil || got != id {
		t.Fatalf("token sah ditolak: %v", err)
	}

	bad := map[string]string{}
	bad["kunci lain"] = sign(t, otherPriv, ok)
	exp := ok
	exp.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Minute))
	bad["kedaluwarsa"] = sign(t, priv, exp)
	aud := ok
	aud.Audience = jwt.ClaimStrings{"lain"}
	bad["audience salah"] = sign(t, priv, aud)
	noexp := ok
	noexp.ExpiresAt = nil
	bad["tanpa exp"] = sign(t, priv, noexp)
	hs, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, ok).SignedString([]byte("rahasia"))
	bad["algoritma HS256"] = hs
	for name, tok := range bad {
		if _, err := v.Verify(tok); err == nil {
			t.Errorf("%s: seharusnya ditolak", name)
		}
	}
}
