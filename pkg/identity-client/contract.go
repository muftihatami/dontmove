// Package identityclient adalah satu-satunya kontrak yang dibagi antara Layanan Konten dan
// Layanan Identitas (G1). Isinya hanya DTO dan klien HTTP: TIDAK ADA tipe database,
// dan tidak ada satu pun field yang bisa membawa email, nomor HP, atau tanggal lahir.
package identityclient

import (
	"time"

	"github.com/google/uuid"
)

// Klaim token yang diterbitkan Layanan Identitas dan diverifikasi Layanan Konten.
const (
	TokenIssuer   = "dontmove-identity"
	TokenAudience = "dontmove-content"
)

// BanMode membedakan ban sementara (bisa dipulihkan) dari ban permanen (masuk denylist).
type BanMode string

const (
	BanTemporary BanMode = "temporary"
	BanPermanent BanMode = "permanent"
)

// EnforceBanRequest: POST /internal/enforce-ban.
// Ban permanen wajib sudah dikonfirmasi moderator kedua sebelum dipanggil (moderasi §konsol).
type EnforceBanRequest struct {
	ShadowID uuid.UUID  `json:"shadow_id"`
	Mode     BanMode    `json:"mode"`
	Until    *time.Time `json:"until,omitempty"` // wajib untuk temporary
	Actor    string     `json:"actor"`
	Reason   string     `json:"reason"`
}

// DeleteAccountRequest: POST /internal/delete-account.
type DeleteAccountRequest struct {
	ShadowID uuid.UUID `json:"shadow_id"`
	Reason   string    `json:"reason"`
}

// IsBannedResponse: GET /internal/is-banned?shadow_id=…&actor=…&reason=…
type IsBannedResponse struct {
	Banned bool `json:"banned"`
}

// ErrorResponse dipakai semua endpoint. Pesan ditulis untuk ditampilkan ke pengguna.
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
