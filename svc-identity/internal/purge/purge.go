// Package purge: job harian pemusnahan (KEPUTUSAN-F0 §3.3). Bukan prosedur manual.
package purge

import (
	"context"
	"time"

	"github.com/dontmove/svc-identity/internal/identitydb"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Result struct {
	DenylistReleased int64
	ShadowLinks      int64
	OTPChallenges    int64
}

// Run menjalankan ketiga langkah, masing-masing dalam transaksinya sendiri.
// Urutannya penting: pelepasan denylist membaca shadow_link untuk log, jadi jalan lebih dulu.
func Run(ctx context.Context, pool *pgxpool.Pool, now time.Time) (Result, error) {
	var res Result
	steps := []func(q *identitydb.Queries) error{
		func(q *identitydb.Queries) (err error) {
			res.DenylistReleased, err = q.ReleaseExpiredTemporaryDenylist(ctx)
			return
		},
		func(q *identitydb.Queries) (err error) {
			res.ShadowLinks, err = q.PurgeExpiredShadowLinks(ctx)
			return
		},
		func(q *identitydb.Queries) (err error) {
			res.OTPChallenges, err = q.DeleteStaleOTP(ctx, now.Add(-24*time.Hour))
			return
		},
	}
	for _, step := range steps {
		tx, err := pool.BeginTx(ctx, pgx.TxOptions{})
		if err != nil {
			return res, err
		}
		if err := step(identitydb.New(tx)); err != nil {
			_ = tx.Rollback(ctx)
			return res, err
		}
		if err := tx.Commit(ctx); err != nil {
			return res, err
		}
	}
	return res, nil
}
