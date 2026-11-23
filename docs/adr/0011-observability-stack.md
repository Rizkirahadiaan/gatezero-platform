# ADR-0011: Observability stack — Prometheus + Alloy/Loki + Tempo + Grafana

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Butuh metrics, logs, trace, dan SLO untuk membuktikan platform benar-benar
  berjalan — sekaligus materi demo (canary, error budget, DORA).

## Keputusan

| Sinyal | Komponen |
|---|---|
| Metrics | `kube-prometheus-stack` (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics) |
| Logs | **Grafana Alloy** → Loki (single-binary, retensi 14–30 hari) |
| Traces | OpenTelemetry Collector → Tempo |
| SLO | **Sloth** (menghasilkan Prometheus recording + alert rules) |
| Long-term metrics | remote-write ke S3 (Thanos/Mimir bila perlu) |
| Dashboard | Grafana + dashboard-as-code (JSON di repo) |

## Kenapa Alloy, bukan Promtail

Promtail sudah dinyatakan deprecated dan mencapai EOL pada 2026. Memulai project baru dengan
Promtail berarti memulai dengan utang teknis. Alloy adalah penerus resmi (River/OTel-based) dan
bisa menggantikan node-exporter scraper sekaligus.

## Kenapa Sloth

SLO manual berarti menulis recording rule yang mudah salah. Sloth menerima definisi SLO
(singkat, mudah dibaca) dan menghasilkan rules Prometheus yang benar, termasuk multi-window
multi-burn-rate alert. Ini artefak yang menunjukkan pemahaman SRE, bukan hanya "pasang Grafana".

## Konsekuensi

### Positif
- Semua sinyal di satu Grafana → demo lebih koheren.
- SLO + error budget memberi angka objektif untuk keputusan rollback canary.
- Dashboard dan alert sebagai kode → bisa di-review di MR.

### Negatif
- Konsumsi RAM signifikan (2,5–4 GB) di worker → memengaruhi sizing VM.
- Loki/Tempo single-binary bukan HA; cukup untuk portofolio, harus disebutkan sebagai batasan.
- Cardinality Prometheus perlu dijaga (jangan label `user_id`).

## Yang **tidak** dipakai (dan alasannya)

| Alternatif | Alasan |
|---|---|
| Elastic Stack | Berat (JVM + storage), overhead besar untuk satu cluster |
| Datadog/New Relic | Berbayar; menghilangkan bagian self-hosting yang ingin didemokan |
| VictoriaMetrics | Efisien, tapi ekosistem alert/dashboard lebih kecil; dicatat sebagai opsi |

## Dashboard wajib

1. **Golden signals** per service (latency, traffic, errors, saturation).
2. **SLO & error budget** per service.
3. **Security posture trend** (Lynis, kube-bench, Kubescape, Trivy).
4. **DORA**: lead time, deployment frequency, change failure rate, MTTR.
5. **Pipeline**: durasi per stage, tingkat kegagalan gate.
