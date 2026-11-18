// Layanan Konten. Tidak punya kredensial ke Identity Vault — hanya ke Content Store.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	ic "github.com/dontmove/identity-client"
	"github.com/dontmove/svc-content/internal/api"
	"github.com/dontmove/svc-content/internal/auth"
	"github.com/dontmove/svc-content/internal/config"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("berhenti", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	srv := &api.Server{
		Pool:     pool,
		Verifier: auth.Verifier{Key: cfg.TokenPublicKey},
		Identity: ic.New(cfg.IdentityInternalURL, cfg.IdentityInternalToken),
		Log:      log,
	}
	hs := &http.Server{Addr: cfg.ListenAddr, Handler: srv.Router(), ReadHeaderTimeout: 5 * time.Second}
	errc := make(chan error, 1)
	go func() {
		log.Info("mendengarkan", "addr", hs.Addr)
		if err := hs.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			errc <- err
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return hs.Shutdown(shut)
}
