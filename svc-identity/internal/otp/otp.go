// Package otp: pembuatan kode dan pengiriman.
package otp

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
)

// Sender mengirim kode ke email atau HP. Implementasi produksi (penyedia SMS & email)
// belum dipilih; lihat README bagian "Belum di F0".
type Sender interface {
	Send(ctx context.Context, channel, destination, code string) error
}

// NewCode menghasilkan 6 digit dari crypto/rand.
func NewCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// DevSender menulis kode ke log untuk pengembangan lokal.
// Yang ditulis hanya challenge_id dan kode, TIDAK PERNAH alamat tujuan (PII di log).
type DevSender struct{ Log *slog.Logger }

type ctxKey struct{}

// WithChallengeID menyisipkan challenge_id agar DevSender bisa mencatatnya.
func WithChallengeID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, ctxKey{}, id)
}

func (d DevSender) Send(ctx context.Context, channel, _ string, code string) error {
	id, _ := ctx.Value(ctxKey{}).(string)
	d.Log.Warn("DEV OTP — jangan aktifkan di produksi", "channel", channel, "challenge_id", id, "code", code)
	return nil
}

// Unconfigured menolak berjalan: layanan tidak boleh diam-diam "berhasil" tanpa mengirim apa pun.
type Unconfigured struct{}

func (Unconfigured) Send(context.Context, string, string, string) error {
	return errors.New("pengirim OTP produksi belum dikonfigurasi")
}

// ChallengeIDKey dipakai Sender lain (dan tes) untuk membaca challenge_id dari context.
func ChallengeIDKey() any { return ctxKey{} }
