# Infrastructure (VM & benchmark)

Berisi hal-hal yang hidup **di luar cluster**: spesifikasi VM, hardening OS, dan baseline performa.
Dipisahkan dari `platform/` karena lifecycle-nya berbeda (VM jarang berubah, workload sering).

```
infra/
├── nutanix/     # spec VM, cloud-init, golden image
├── vm/          # ansible hardening, usg/CIS tailoring
└── benchmark/   # baseline performa + skrip pengukuran
```

## Kenapa benchmark dipisah

Baseline performa harus diambil **sebelum** hardening dan **sebelum** cluster dipasang, supaya:

1. Sizing VM (Nexus, SonarQube, etcd) punya dasar angka, bukan perkiraan.
2. Delta hardening bisa diukur ("-3% throughput, +18 kontrol CIS").
3. Masalah infrastruktur (noisy neighbor, MTU mismatch, disk lambat) ketahuan lebih awal.

Hasil disimpan di `benchmark/results/YYYY-MM-DD-<label>.json` dan di-commit, sehingga tren
performa terlihat di git history.
