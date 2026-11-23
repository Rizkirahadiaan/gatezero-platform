# Aplikasi demo

Aplikasi ini **bukan** bintang utama repo ini — platform-nya yang jadi fokus. Karena itu dipilih
yang paling kecil permukaannya: satu API Go, satu worker, satu Postgres.

| App | Bahasa | Image target | Tujuan |
|---|---|---|---|
| `demo-api` | Go 1.24 | distroless static, ~15 MB | target pipeline & canary |
| `demo-worker` | Go 1.24 | distroless static | konsumen queue (demo KEDA/rollout) |

## Aturan wajib

- **Static build** (`CGO_ENABLED=0`) → bisa distroless `static`.
- **Non-root** (`runAsUser: 65532`), root filesystem read-only.
- Port > 1024 (tidak butuh NET_BIND_SERVICE).
- Health endpoint terpisah (`/healthz`, `/readyz`) — bukan satu endpoint untuk keduanya.
- Metrik Prometheus di `/metrics` (untuk ServiceMonitor).
- **Tidak ada secret di environment default**; dibaca dari Secret hasil SOPS.
- Graceful shutdown (`SIGTERM` → 15s) supaya canary rollback tidak memutus request.

## Kenapa Go + distroless

| Aspek | Efek |
|---|---|
| Image kecil | scan Trivy cepat, pull dari Nexus cepat, surface CVE minimal |
| Tanpa shell | penyerang tidak bisa `exec` di container |
| Binary statis | tidak butuh libc, tidak ada package OS untuk dipatch |

Kontras yang menarik untuk demo: bandingkan ukuran & jumlah CVE image `golang:1.24` (builder)
vs `distroless/static` (runtime) di laporan Trivy.

> **Status:** belum ada kode. Item `A1`-`A7` di [ROADMAP](../ROADMAP.md).
