# demo-api

HTTP API kecil: Go + Postgres, dibuild static, dijalankan di distroless.

## Endpoint

| Method | Path | Keterangan |
|---|---|---|
| GET | `/healthz` | liveness — tanpa dependency check |
| GET | `/readyz` | readiness — cek koneksi Postgres |
| GET | `/metrics` | Prometheus |
| GET | `/api/v1/items` | list item |
| POST | `/api/v1/items` | create item |
| GET | `/api/v1/items/{id}` | detail |

## Konfigurasi

| Env | Sumber | Keterangan |
|---|---|---|
| `DATABASE_URL` | Secret `demo-api-db` (`*.enc.yaml`) | dari SOPS |
| `PORT` | ConfigMap | default `8080` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | ConfigMap | collector |
| `LOG_LEVEL` | ConfigMap | `info` |

## Rencana Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/api"]
```

Catatan: `hadolint` akan menuntut pin digest pada base image production. Untuk demo boleh tag,
untuk `prod` gunakan `@sha256:...`.

## Yang diuji di pipeline

- `go test -race -coverprofile=coverage.out ./...`
- coverage report → SonarQube
- `govulncheck` (opsional, cepat) sebelum Trivy
- SBOM Syft dari image final

> **Status:** belum diimplementasikan. Item `A1`, `A3`-`A5` di [ROADMAP](../../ROADMAP.md).
