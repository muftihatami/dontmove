# Build dari root repo: docker build -f svc-identity/Dockerfile .
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY pkg/identity-client ./pkg/identity-client
COPY svc-identity ./svc-identity
WORKDIR /src/svc-identity
RUN go mod download && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/...

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ /app/
USER nonroot
ENTRYPOINT ["/app/identity"]
