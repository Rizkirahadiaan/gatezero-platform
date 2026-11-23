# ADR-0009: vDisk etcd terpisah + backup level API, bukan VM snapshot

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** etcd adalah otak cluster. Kehilangan etcd = kehilangan seluruh state cluster.

## Keputusan

1. `/var/lib/etcd` berada di **vDisk terpisah** (storage container SSD) pada setiap control plane.
2. Backup memakai **`etcdctl snapshot save`** (level API) setiap 6 jam + upload ke S3,
   bukan snapshot VM sebagai mekanisme utama.
3. Snapshot diuji restore ke cluster uji setiap kuartal.

## Kenapa

| Aspek | VM snapshot (AHV) | `etcdctl snapshot save` |
|---|---|---|
| Konsistensi | tidak crash-consistent dengan WAL etcd | konsisten (API-level) |
| Ukuran | seluruh disk VM | hanya database etcd |
| Waktu | detik, tapi butuh quiesce | detik |
| Restore | seluruh VM | satu anggota etcd |
| Verifikasi | sulit | `etcdutl snapshot status` |

Snapshot VM tetap dipakai untuk **DR GitLab & Nexus** (dengan pre-freeze), tapi **bukan** untuk
etcd.

## Kenapa vDisk terpisah

etcd sangat sensitif pada latency fsync. Jika `/var/lib/containerd` berbagi disk, `image pull`
besar (mis. image observability) dapat membanjiri disk dan memicu:

```
etcdserver: request timed out
leader changed
```

yang berujung pada API server tidak responsif — tanpa ada yang salah pada konfigurasi cluster.

## Konsekuensi

### Positif
- Latency etcd stabil meski ada image pull / log burst.
- Backup kecil, cepat, dan bisa diuji restore tanpa menyentuh VM.
- RTO jelas dan terukur (didokumentasikan di runbook).

### Negatif
- Perlu kapasitas vDisk tambahan (40 GB per CP).
- Perlu cron + rotasi + monitoring ukuran snapshot.
- Restore manual, bukan satu klik.

## Konfigurasi terkait

```yaml
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: quota-backend-bytes
        value: "8589934592"     # 8 GiB, alert di 70%
      - name: listen-metrics-urls
        value: "http://0.0.0.0:2381"
```

Alert wajib: `etcd_db_total_size_in_bytes / quota > 0.7`, `etcd_server_leader_changes_seen_total`,
`etcd_disk_wal_fsync_duration_seconds{quantile="0.99"} > 0.01`.

## Verifikasi

Runbook `docs/runbooks/etcd-restore.md` wajib punya waktu eksekusi tercatat dari drill terakhir.
