# Build dari root repo: docker build -f svc-content/Dockerfile .
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY pkg/identity-client ./pkg/identity-client
COPY svc-content ./svc-content
WORKDIR /src/svc-content
RUN go mod download && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/...

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ /app/
USER nonroot
ENTRYPOINT ["/app/content"]
