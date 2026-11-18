// Layanan Identitas — satu-satunya proses yang memegang kredensial Identity Vault.
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

	"github.com/dontmove/svc-identity/internal/api"
	"github.com/dontmove/svc-identity/internal/config"
	"github.com/dontmove/svc-identity/internal/otp"
	"github.com/dontmove/svc-identity/internal/token"
	"github.com/dontmove/svc-identity/internal/vaultcrypto"
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

	pool, err := pgxpool.New(ctx, cfg.VaultDatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	keys, err := vaultcrypto.New(cfg.Pepper, cfg.EncKey)
	if err != nil {
		return err
	}
	issuer, err := token.NewIssuer(cfg.TokenSeed, cfg.TokenTTL)
	if err != nil {
		return err
	}
	var sender otp.Sender = otp.Unconfigured{}
	if cfg.DevOTP {
		sender = otp.DevSender{Log: log}
		log.Warn("IDENTITY_DEV_OTP aktif: kode OTP ditulis ke log")
	}

	srv := &api.Server{
		Pool: pool, Keys: keys, Tokens: issuer, Sender: sender,
		InternalToken: cfg.InternalToken, MinAge: cfg.MinAge, Log: log,
	}
	log.Info("kunci publik token (CONTENT_TOKEN_PUBLIC_KEY)", "value", issuer.PublicKeyBase64())

	servers := []*http.Server{
		{Addr: cfg.PublicAddr, Handler: srv.PublicRouter(), ReadHeaderTimeout: 5 * time.Second},
		{Addr: cfg.InternalAddr, Handler: srv.InternalRouter(), ReadHeaderTimeout: 5 * time.Second},
	}
	errc := make(chan error, len(servers))
	for _, s := range servers {
		go func(s *http.Server) {
			log.Info("mendengarkan", "addr", s.Addr)
			if err := s.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
				errc <- err
			}
		}(s)
	}
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, s := range servers {
		_ = s.Shutdown(shut)
	}
	return nil
}
