# Infrastructure (VM & benchmark)

Berisi hal-hal yang hidup **di luar cluster**: spesifikasi VM, hardening OS, dan baseline performa.
Dipisahkan dari `platform/` karena lifecycle-nya berbeda (VM jarang berubah, workload sering).

```
infra/
├── nutanix/     # spec VM, cloud-init, golden image
├── vm/          # hardening OS + CIS benchmark
└── benchmark/   # baseline performa + skrip pengukuran
```

## Dokumen

| Dokumen | Isi |
|---|---|
| [`vm/HARDENING.md`](vm/HARDENING.md) | baseline hardening untuk **semua** VM: SSH, sysctl, filesystem, auditd, AIDE, nftables, patch |
| [`vm/HARDENING-K8S.md`](vm/HARDENING-K8S.md) | overlay node kubeadm: kubelet, apiserver, etcd, Cilium, PSA, tabel pengecualian CIS |
| [`vm/CIS-BENCHMARK.md`](vm/CIS-BENCHMARK.md) | cara mengukur: USG, OpenSCAP, Lynis, kube-bench, Kubescape + tren skor |
| [`benchmark/README.md`](benchmark/README.md) | baseline performa (fio, iperf3, etcd) |

## Kenapa benchmark dipisah

Baseline performa harus diambil **sebelum** hardening dan **sebelum** cluster dipasang, supaya:

1. Sizing VM (Nexus, SonarQube, etcd) punya dasar angka, bukan perkiraan.
2. Delta hardening bisa diukur ("-3% throughput, +18 kontrol CIS").
3. Masalah infrastruktur (noisy neighbor, MTU mismatch, disk lambat) ketahuan lebih awal.

Hasil disimpan di `benchmark/results/YYYY-MM-DD-<label>.json` dan di-commit, sehingga tren
performa terlihat di git history.
