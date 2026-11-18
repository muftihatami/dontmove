# Don't Move — F0. Butuh: Go 1.23+, sqlc 1.27, goose 3.22, psql, Docker (opsional).
VAULT_URL   ?= postgres://vault:vault-dev-only@localhost:5433/vault?sslmode=disable
CONTENT_URL ?= postgres://content:content-dev-only@localhost:5434/content?sslmode=disable
MODULES := pkg/identity-client svc-identity svc-content

.PHONY: tidy generate guard test test-integration migrate verify keys up check

tidy:            ## sekali setelah clone: isi go.sum tiap modul
	@for m in $(MODULES); do (cd $$m && go mod tidy) || exit 1; done

generate:        ## regenerasi kode sqlc (G2)
	cd svc-identity && sqlc generate
	cd svc-content  && sqlc generate

guard:           ## G1–G4
	./scripts/guard.sh

test:            ## tes unit
	@for m in $(MODULES); do (cd $$m && go vet ./... && go test ./...) || exit 1; done

migrate:
	goose -dir svc-identity/migrations/identity postgres "$(VAULT_URL)" up
	goose -dir svc-content/migrations/content   postgres "$(CONTENT_URL)" up

verify:          ## uji constraint di database sungguhan
	psql "$(VAULT_URL)"   -v ON_ERROR_STOP=1 -f scripts/verify/vault.sql
	psql "$(CONTENT_URL)" -v ON_ERROR_STOP=1 -f scripts/verify/content.sql

test-integration: migrate verify
	cd svc-identity && VAULT_TEST_DATABASE_URL="$(VAULT_URL)" go test -count=1 ./internal/api/
	cd svc-content  && CONTENT_TEST_DATABASE_URL="$(CONTENT_URL)" go test -count=1 ./internal/api/

keys:            ## kunci acak untuk lokal (produksi: KMS)
	cd svc-identity && go run ./cmd/keygen

up:
	docker compose up --build

check: guard test test-integration   ## semua yang dijalankan CI
