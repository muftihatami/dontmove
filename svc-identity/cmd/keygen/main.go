// keygen mencetak kunci acak untuk pengembangan lokal. Di produksi, kunci berasal dari KMS.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
)

func rnd(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func main() {
	b64 := base64.StdEncoding.EncodeToString
	seed := rnd(32)
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	fmt.Println("IDENTITY_PEPPER=" + b64(rnd(32)))
	fmt.Println("IDENTITY_ENC_KEY=" + b64(rnd(32)))
	fmt.Println("IDENTITY_TOKEN_SEED=" + b64(seed))
	fmt.Println("CONTENT_TOKEN_PUBLIC_KEY=" + b64(pub))
	fmt.Println("IDENTITY_INTERNAL_TOKEN=" + hex.EncodeToString(rnd(32)))
}
