# demo-worker

Konsumen queue: membaca job dari Postgres (`SELECT ... FOR UPDATE SKIP LOCKED`) atau Redis stream,
memproses, lalu menulis hasil.

Tujuan keberadaannya di portofolio:

1. Mendemokan **Argo Rollouts** pada workload tanpa HTTP (rollout berbasis metrik queue depth).
2. Mendemokan **KEDA** (scale-to-zero saat queue kosong) — bukti resource efficiency.
3. Mendemokan **NetworkPolicy**: worker hanya boleh bicara ke Postgres, tidak ke internet.
4. Mendemokan `PodDisruptionBudget` pada workload yang tidak punya traffic HTTP.

## Aturan desain

- Idempoten (job bisa diproses dua kali tanpa efek samping).
- Graceful shutdown: berhenti ambil job baru, selesaikan yang sedang jalan (max 30s).
- Tanpa shell di image (`distroless/static`).
- Metrik: `jobs_processed_total`, `job_duration_seconds`, `queue_depth`.

> **Status:** belum diimplementasikan. Item `A2` di [ROADMAP](../../ROADMAP.md).
