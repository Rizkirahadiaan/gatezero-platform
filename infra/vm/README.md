# VM Hardening

Dokumen hardening untuk semua VM di platform ini — dari jumpbox sampai node Kubernetes.

## Peta dokumen

| Dokumen | Untuk VM apa | Isi |
|---|---|---|
| [`HARDENING.md`](HARDENING.md) | **semua** VM | baseline global: SSH, sysctl, filesystem, auditd, AIDE, nftables, patch |
| [`HARDENING-K8S.md`](HARDENING-K8S.md) | node kubeadm | delta di atas baseline: kubelet/apiserver/etcd, exception CIS, policy pod |
| [`CIS-BENCHMARK.md`](CIS-BENCHMARK.md) | semua | cara mengukur: USG/OpenSCAP, Lynis, kube-bench, Kubescape, trending |

## Urutan yang benar

```
1. Provisioning   cloud-init + golden image
2. Baseline       HARDENING.md        <- semua VM
3. Benchmark #1   CIS-BENCHMARK.md    <- ukur sebelum overlay
4. Overlay k8s    HARDENING-K8S.md    <- hanya node cluster
5. Benchmark #2   CIS-BENCHMARK.md    <- ukur delta
6. Remediasi      FAIL -> perbaiki kode / catat exception
7. Jadwalkan      cron mingguan + grafik tren
```

Alasan urutan:

- **Baseline sebelum overlay.** Overlay k8s mengasumsikan sysctl dan module sudah benar;
  kalau tidak, kubelet gagal start dengan pesan yang membingungkan.
- **Benchmark sebelum dan sesudah.** Tanpa baseline, klaim *"hardening tidak memperlambat"*
  tidak bisa dibuktikan. Bandingkan dengan `infra/benchmark`.
- **Ukur, lalu remediasi.** `usg fix` buta pada node yang sudah jadi akan mematikan cluster.

## Prinsip

1. **Hardening adalah kode, bukan tindakan manual.** Semua yang di dokumen ini harus
   berakhir di Ansible. Kalau hanya diketik di server, ia akan hilang saat rebuild.
2. **Setiap pengecualian wajib punya mitigasi pengganti.** "Tidak bisa" bukan alasan.
   Lihat [`docs/adr/0010`](../../docs/adr/0010-cis-hardening-exceptions.md).
3. **Jangan mengejar 100% CIS.** Skor 100% pada node yang berfungsi lebih buruk daripada
   skor 82% dengan 12 pengecualian yang terdokumentasi.
4. **Uji di satu node** sebelum rollout. Kluster tidak punya "rollback sekali klik".

## Status implementasi

| Komponen | Status |
|---|---|
| Dokumen + perintah | ✅ ada (3 file ini) |
| Role Ansible `infra/vm/ansible` | ⬜ belum dibuat |
| Tailoring USG (`usg/tailoring.xml`) | ⬜ belum dibuat |
| Job kube-bench terjadwal | ⬜ belum dibuat |
| Dashboard tren skor | ⬜ belum dibuat |

Sampai role Ansible ada, dokumen ini yang menjadi acuan eksekusi manual.
