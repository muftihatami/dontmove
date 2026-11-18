// Package config membaca konfigurasi Layanan Identitas dari env var saja (KEPUTUSAN-F0 §1.1).
package config

import (
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	VaultDatabaseURL string        // VAULT_DATABASE_URL — satu-satunya database yang boleh disentuh layanan ini
	PublicAddr       string        // IDENTITY_PUBLIC_ADDR — otp/register/login, dibuka lewat gateway
	InternalAddr     string        // IDENTITY_INTERNAL_ADDR — hanya untuk Layanan Konten
	InternalToken    string        // IDENTITY_INTERNAL_TOKEN — bearer untuk listener internal
	Pepper           []byte        // IDENTITY_PEPPER (base64, ≥32 byte) — kunci HMAC lookup
	EncKey           []byte        // IDENTITY_ENC_KEY (base64, 32 byte) — AES-256-GCM
	TokenSeed        []byte        // IDENTITY_TOKEN_SEED (base64, 32 byte) — seed Ed25519
	TokenTTL         time.Duration // IDENTITY_TOKEN_TTL, default 720h
	MinAge           int           // IDENTITY_MIN_AGE, default 17 (PRD Q7 — menunggu tinjauan hukum)
	DevOTP           bool          // IDENTITY_DEV_OTP=1: kode OTP ditulis ke log, bukan dikirim
}

func Load() (Config, error) {
	c := Config{
		VaultDatabaseURL: os.Getenv("VAULT_DATABASE_URL"),
		PublicAddr:       envOr("IDENTITY_PUBLIC_ADDR", ":8081"),
		InternalAddr:     envOr("IDENTITY_INTERNAL_ADDR", ":8082"),
		InternalToken:    os.Getenv("IDENTITY_INTERNAL_TOKEN"),
		TokenTTL:         720 * time.Hour,
		MinAge:           17,
		DevOTP:           os.Getenv("IDENTITY_DEV_OTP") == "1",
	}
	var err error
	if c.VaultDatabaseURL == "" {
		return c, fmt.Errorf("VAULT_DATABASE_URL wajib diisi")
	}
	if len(c.InternalToken) < 32 {
		return c, fmt.Errorf("IDENTITY_INTERNAL_TOKEN wajib, minimal 32 karakter")
	}
	if c.Pepper, err = b64("IDENTITY_PEPPER", 32, false); err != nil {
		return c, err
	}
	if c.EncKey, err = b64("IDENTITY_ENC_KEY", 32, true); err != nil {
		return c, err
	}
	if c.TokenSeed, err = b64("IDENTITY_TOKEN_SEED", 32, true); err != nil {
		return c, err
	}
	if v := os.Getenv("IDENTITY_TOKEN_TTL"); v != "" {
		if c.TokenTTL, err = time.ParseDuration(v); err != nil {
			return c, fmt.Errorf("IDENTITY_TOKEN_TTL: %w", err)
		}
	}
	if v := os.Getenv("IDENTITY_MIN_AGE"); v != "" {
		if c.MinAge, err = strconv.Atoi(v); err != nil {
			return c, fmt.Errorf("IDENTITY_MIN_AGE: %w", err)
		}
	}
	return c, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func b64(name string, n int, exact bool) ([]byte, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return nil, fmt.Errorf("%s wajib diisi (jalankan: make keys)", name)
	}
	b, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("%s bukan base64: %w", name, err)
	}
	if (exact && len(b) != n) || len(b) < n {
		return nil, fmt.Errorf("%s harus %d byte", name, n)
	}
	return b, nil
}
