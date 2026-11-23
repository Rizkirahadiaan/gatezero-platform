# ADR-0003: Nexus OSS sebagai artifact hub tunggal

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Butuh registry OCI + proxy dependency (npm/maven/pypi) + penyimpanan SBOM,
  dengan jumlah komponen sesedikit mungkin.

## Keputusan

Nexus Repository OSS di VM terpisah (Docker Compose), berperan sebagai:

- `oci-hosted` untuk image aplikasi hasil build
- `docker-proxy` untuk `docker.io`, `k8s-proxy` untuk `registry.k8s.io`
- proxy npm / maven / pypi untuk dependency
- `raw-releases` untuk SBOM dan laporan scan

GitLab Container Registry **tidak dipakai** sebagai registry utama.

## Konsekuensi

### Positif
- Satu UI, satu audit trail untuk semua artifact.
- Pull-through cache mengurangi egress dan mempercepat build.
- Terpisah dari cluster → restart cluster tidak memutus registry.

### Negatif
- Registry OCI di Nexus OSS terbatas: tanpa HA, tanpa scan bawaan, auth basic, dan
  **butuh port/reverse-proxy terpisah** (tidak bisa path prefix).
- Tidak ada replikasi multi-site.
- Retensi harus dikelola manual (cleanup policy + compact blob store).

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| GitLab Container Registry | Memenuhi kebutuhan OCI, tapi tidak menyelesaikan proxy npm/maven/pypi dan menyatukan lifecycle dengan GitLab |
| Harbor | Lebih baik untuk OCI (scan Trivy bawaan, RBAC, replication) tapi menambah satu VM dan tidak menyelesaikan proxy package non-OCI |
| GHCR/Quay | Di luar kendali, tidak mendemokan self-hosting |

## Rencana evolusi

Kalau kebutuhan OCI tumbuh (multi-env, scanning registry-level), tambahkan **Harbor** khusus OCI
sementara Nexus tetap untuk package proxy. Keputusan itu akan dicatat sebagai ADR baru, bukan
revisi ADR ini.

## Catatan risiko

Status dukungan/lisensi Nexus Community Edition perlu diverifikasi ulang sebelum dipakai jangka
panjang. Rencana migrasi harus sudah ada sebelum ini jadi dependensi produksi nyata.
