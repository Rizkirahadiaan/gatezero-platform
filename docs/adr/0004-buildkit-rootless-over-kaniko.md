# ADR-0004: BuildKit rootless menggantikan Kaniko

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Build image container dari dalam pod tanpa `privileged: true`.

## Konteks

Hampir semua tutorial 2022–2024 memakai Kaniko. Repo Kaniko sudah diarsipkan dan tidak lagi
dirawat aktif, sehingga memakainya di 2026 adalah risiko keamanan (tidak ada patch) sekaligus
sinyal bahwa kita mengikuti tutorial lama.

## Keputusan

**BuildKit rootless** sebagai daemon terpisah (Deployment di namespace `buildkit`) dengan
`buildctl`/`buildx` dipanggil dari job CI melalui koneksi TLS.

Alternatif yang setara dan dipertimbangkan serius: **Buildah** dengan `--isolation=chroot`
untuk menyederhanakan operasi (tanpa daemon).

## Detail

- BuildKit berjalan sebagai user non-root (`rootless`), `securityContext` tanpa privilege.
- Cache mount (`--mount=type=cache`) dipakai untuk Go module — build lebih cepat dari Kaniko.
- Output: OCI image langsung ke Nexus, plus `--metadata-file` untuk digest.
- Multi-arch (`--platform linux/amd64,linux/arm64`) didukung tanpa QEMU bila build hanya amd64.

## Konsekuensi

### Positif
- Tool yang aktif dirawat dan menjadi standar industri.
- Tidak perlu pod privileged → konsisten dengan policy Kyverno/PSA.
- Build cache lebih efektif.

### Negatif
- Butuh daemon tambahan + TLS cert (mTLS) untuk akses remote.
- Di Ubuntu 24.04, unprivileged user namespace dibatasi AppArmor → perlu
  `kernel.apparmor_restrict_unprivileged_userns=0` **hanya di worker** (masuk daftar pengecualian
  CIS, ADR-0010).
- Debugging lebih rumit daripada `docker build`.

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| Kaniko | Repo diarsipkan, tidak dirawat |
| Docker-in-Docker privileged | Melanggar baseline keamanan |
| `ko` | Sangat baik untuk Go, tapi tidak generik untuk worker (Python/Node) |
| Build di luar cluster (VM) | Menambah lantai mesin, menghilangkan isolasi per-job |
