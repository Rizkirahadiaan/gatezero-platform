# ADR-0007: Cosign keyless + verifikasi signature di admission

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Bagaimana memastikan image yang berjalan benar-benar berasal dari pipeline kita.

## Keputusan

Image di-sign dengan **Cosign keyless** melalui identity provider OIDC (GitLab ID token), lalu
**Kyverno `verifyImages`** menolak image tanpa signature valid di namespace `apps`.

## Kenapa keyless

| Aspek | Key-based | Keyless (Sigstore) |
|---|---|---|
| Private key | harus disimpan & dirotasi | tidak ada |
| Risiko | key bocor = semua image bisa dipalsukan | identitas OIDC + transparancy log |
| Audit | manual | Rekor (immutable, publik) |
| Rotasi | wajib | tidak berlaku |

Untuk portofolio ini, keyless juga menghilangkan satu kelas masalah: **tidak ada private key
signing yang harus dilindungi** — yang justru sering jadi titik terlemah di demo supply chain.

## Detail

- `cosign sign --identity-token=$CI_JOB_JWT_V2 <image>@<digest>`
- Sign **berdasarkan digest**, bukan tag.
- SBOM (`syft`) di-attach sebagai attestation: `cosign attest --type cyclonedx`.
- Kyverno attestor memverifikasi `issuer` dan `subject` GitLab sebelum menerima image.
- Untuk environment yang butuh verifikasi offline, sediakan fallback key-based dengan key di SOPS
  (didokumentasikan, tidak diaktifkan default).

## Konsekuensi

### Positif
- Menutup serangan "image palsu dengan nama sama".
- Dijalankan otomatis di admission → tidak bisa dilewati dengan `kubectl apply` manual.
- Ada bukti publik (Rekor) yang bisa ditunjukkan saat demo.

### Negatif
- Bergantung pada ketersediaan Fulcio/Rekor saat signing (build bisa gagal bila jaringan ke
  Sigstore terputus).
- Verifikasi butuh akses ke Rekor atau salinan public key; perlu strategi offline.
- Debugging lebih sulit: error admission muncul saat pod dibuat, bukan saat build.

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| Key-based saja | Satu key bocor = seluruh supply chain bisa dipalsukan |
| Verifikasi di CI saja | Bisa dilewati; image bisa diubah setelah scan |
| SLSA provenance saja | Bagus, tapi butuh infrastruktur builder tepercaya; dijadikan backlog, bukan pengganti signature |

## Backlog

- `cosign verify-attestation` untuk SBOM sebelum admit.
- SLSA provenance via BuildKit `--provenance` + verifikasi `slsa-verifier`.
