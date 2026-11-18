// Job purge harian. Jalankan lewat cron / CronJob, sekali sehari.
package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/dontmove/svc-identity/internal/purge"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	dsn := os.Getenv("VAULT_DATABASE_URL")
	if dsn == "" {
		log.Error("VAULT_DATABASE_URL wajib diisi")
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		log.Error("koneksi gagal", "err", err)
		os.Exit(1)
	}
	defer pool.Close()
	res, err := purge.Run(ctx, pool, time.Now())
	if err != nil {
		log.Error("purge gagal", "err", err)
		os.Exit(1)
	}
	log.Info("purge selesai",
		"denylist_dilepas", res.DenylistReleased,
		"shadow_link_dimusnahkan", res.ShadowLinks,
		"otp_dihapus", res.OTPChallenges)
}
