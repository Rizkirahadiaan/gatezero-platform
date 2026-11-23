# Benchmark

Dua jalur pengukuran, keduanya disimpan sebagai artefak dan tren.

## 1. Security / compliance benchmark

| Sumber | Perintah | Output |
|---|---|---|
| Lynis (OS) | `lynis audit system --quick` | `hardening_index` 0–100 |
| OpenSCAP (OS) | `oscap xccdf eval --profile cis_level1_server --report r.html ssg-ubuntu2404-ds.xml` | XCCDF + HTML |
| kube-bench (k8s) | Job di namespace `security` | PASS/FAIL per section |
| Kubescape | `kubescape scan framework nsa,cis-v1.10 --format json` | controls failed |
| Trivy | `trivy rootfs /` atau `trivy vm` | CVE OS |

Target (lihat ADR-0010): Lynis ≥ 80, kube-bench CP ≥ 90%, worker ≥ 85%, Kubescape NSA 0 critical.

### Push ke Prometheus

Semua skor dikirim sebagai metrik supaya ada grafik tren, bukan sekadar file JSON:

```
compliance_score{source="lynis",host="k8s-w-01"} 82
compliance_score{source="kube-bench",role="controlplane"} 93
kubescape_controls_failed{framework="nsa"} 0
```

Dashboard: **Security Posture Trend** (target line 90).

## 2. Performance baseline

Skrip: [`scripts/run-all.sh`](scripts/run-all.sh)

| Test | Alat | Metrik | Ambang (sesuaikan hardware) |
|---|---|---|---|
| 4k random write | fio | IOPS, p99 | > 5 000 IOPS, p99 < 2 ms |
| 64k sequential read | fio | MB/s | > 500 |
| etcd fsync | `etcdctl check perf` | p99 fsync | < 10 ms |
| CPU | sysbench | events/s | baseline (tanpa target) |
| Memory | sysbench | MiB/s | baseline |
| Network | iperf3 | Gbps | > 5 (link 10G) |
| Latency | sockperf | µs | < 200 |
| PVC (CSI) | `kubestr fio` | IOPS | ≈ bare-metal VM |

## Aturan

1. **Ukur di VM yang sama** dengan beban yang sama; jangan bandingkan lintas hardware.
2. **Catat konteks** (kernel, disk type, MTU, jumlah vCPU) — sudah otomatis di `context.txt`.
3. **Baseline dulu, baru hardening.** Tanpa baseline, klaim "hardening tidak memperlambat"
   tidak bisa dibuktikan.
4. **Ulangi minimal 3x**, ambil median — satu kali jalan bisa misleading.
5. Hasil di-commit: `benchmark/results/YYYY-MM-DD-<label>/`.

## Kesalahan umum yang ingin dihindari

| Kesalahan | Akibat |
|---|---|
| Menjalankan fio di disk yang sama dengan etcd | mengukur angka salah dan mengganggu cluster |
| Benchmark tanpa mencatat MTU | hasil jaringan tidak bisa dibandingkan |
| Benchmark dari laptop ke VM lewat Wi-Fi | mengukur jaringan kantor, bukan datacenter |
| Hanya 1x run | noise I/O Nutanix membuat angka tidak stabil |
