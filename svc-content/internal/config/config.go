// Package config — konfigurasi Layanan Konten.
//
// G3: struct ini punya TEPAT SATU field DSN. Tidak ada tempat untuk menaruh DSN kedua,
// dan config_test.go menggagalkan build kalau seseorang menambahkannya.
package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"os"
)

type Config struct {
	DatabaseURL           string            // CONTENT_DATABASE_URL — satu-satunya DSN
	ListenAddr            string            // CONTENT_ADDR, default :8080
	IdentityInternalURL   string            // IDENTITY_INTERNAL_URL
	IdentityInternalToken string            // IDENTITY_INTERNAL_TOKEN
	TokenPublicKey        ed25519.PublicKey // CONTENT_TOKEN_PUBLIC_KEY — hanya kunci publik; Konten tidak bisa menerbitkan token
}

func Load() (Config, error) {
	c := Config{
		DatabaseURL:           os.Getenv("CONTENT_DATABASE_URL"),
		ListenAddr:            os.Getenv("CONTENT_ADDR"),
		IdentityInternalURL:   os.Getenv("IDENTITY_INTERNAL_URL"),
		IdentityInternalToken: os.Getenv("IDENTITY_INTERNAL_TOKEN"),
	}
	if c.ListenAddr == "" {
		c.ListenAddr = ":8080"
	}
	if c.DatabaseURL == "" || c.IdentityInternalURL == "" || c.IdentityInternalToken == "" {
		return c, fmt.Errorf("CONTENT_DATABASE_URL, IDENTITY_INTERNAL_URL, IDENTITY_INTERNAL_TOKEN wajib diisi")
	}
	pk, err := base64.StdEncoding.DecodeString(os.Getenv("CONTENT_TOKEN_PUBLIC_KEY"))
	if err != nil || len(pk) != ed25519.PublicKeySize {
		return c, fmt.Errorf("CONTENT_TOKEN_PUBLIC_KEY harus kunci publik Ed25519 base64 (32 byte)")
	}
	c.TokenPublicKey = pk
	return c, nil
}
