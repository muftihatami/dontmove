// Package vaultcrypto: lookup HMAC dan enkripsi kolom untuk Identity Vault.
//
// Di produksi, Pepper dan EncKey berasal dari KMS. Di F0 keduanya dibaca dari env
// supaya bisa berjalan lokal; ganti sumbernya, bukan antarmukanya.
package vaultcrypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/mail"
	"regexp"
	"strings"
)

// Kind memisahkan domain HMAC dan AAD supaya nilai satu kolom tidak bisa dipindah ke kolom lain.
type Kind string

const (
	KindEmail  Kind = "email"
	KindPhone  Kind = "phone"
	KindDevice Kind = "device"
	KindOTP    Kind = "otp"
)

type Keys struct {
	pepper []byte
	aead   cipher.AEAD
}

func New(pepper, encKey []byte) (*Keys, error) {
	if len(pepper) < 32 {
		return nil, errors.New("pepper minimal 32 byte")
	}
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Keys{pepper: pepper, aead: aead}, nil
}

// Lookup = HMAC-SHA256(pepper, kind || 0x00 || value). Satu arah; hanya bisa dicocokkan.
func (k *Keys) Lookup(kind Kind, value string) []byte {
	m := hmac.New(sha256.New, k.pepper)
	m.Write([]byte(kind))
	m.Write([]byte{0})
	m.Write([]byte(value))
	return m.Sum(nil)
}

// Seal mengenkripsi dengan AES-256-GCM. Keluaran: nonce || ciphertext.
func (k *Keys) Seal(kind Kind, plaintext string) ([]byte, error) {
	nonce := make([]byte, k.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return k.aead.Seal(nonce, nonce, []byte(plaintext), []byte(kind)), nil
}

// Open dipakai hanya untuk mengirim OTP/email pemulihan. Tidak pernah untuk respons API.
func (k *Keys) Open(kind Kind, sealed []byte) (string, error) {
	ns := k.aead.NonceSize()
	if len(sealed) < ns {
		return "", errors.New("ciphertext terlalu pendek")
	}
	pt, err := k.aead.Open(nil, sealed[:ns], sealed[ns:], []byte(kind))
	if err != nil {
		return "", err
	}
	return string(pt), nil
}

// NormalizeEmail: huruf kecil, tanpa spasi, harus alamat tunggal yang valid.
func NormalizeEmail(s string) (string, error) {
	s = strings.ToLower(strings.TrimSpace(s))
	a, err := mail.ParseAddress(s)
	if err != nil || a.Address != s || a.Name != "" {
		return "", fmt.Errorf("format email tidak valid")
	}
	return s, nil
}

var e164 = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)

// NormalizePhone mengubah nomor ke E.164. Format lokal Indonesia (08…, 628…) diterima.
func NormalizePhone(s string) (string, error) {
	r := strings.NewReplacer(" ", "", "-", "", "(", "", ")", "", ".", "")
	s = r.Replace(strings.TrimSpace(s))
	switch {
	case strings.HasPrefix(s, "+"):
	case strings.HasPrefix(s, "08"):
		s = "+62" + s[1:]
	case strings.HasPrefix(s, "62"):
		s = "+" + s
	}
	if !e164.MatchString(s) {
		return "", fmt.Errorf("format nomor HP tidak valid")
	}
	return s, nil
}
