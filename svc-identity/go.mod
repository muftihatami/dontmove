module github.com/dontmove/svc-identity

go 1.23

require (
	github.com/dontmove/identity-client v0.0.0
	github.com/go-chi/chi/v5 v5.1.0
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx/v5 v5.7.1
)

replace github.com/dontmove/identity-client => ../pkg/identity-client
