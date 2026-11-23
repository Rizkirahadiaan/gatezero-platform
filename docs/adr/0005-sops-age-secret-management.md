# ADR-0005: SOPS + age sebagai mekanisme secret management

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Secret harus tersimpan di Git (karena GitOps), tapi tidak boleh plaintext.

## Keputusan

**SOPS + age** dengan hierarki key 4 level. Ciphertext disimpan di repo; plaintext hanya ada
di memori proses saat dibutuhkan.

| Level | Key | Lokasi private key | Dipakai untuk |
|---|---|---|---|
| root | age root | offline (password manager / cetak) | `platform/bootstrap/*.enc.yaml` |
| ci | age ci | OpenBao, diakses via GitLab OIDC (`secrets:vault`) | dekripsi di pipeline |
| cluster | age cluster | Secret `sops-age` di ns `argocd`, dari ESO | CMP sidecar ArgoCD |
| team | age team | tiap engineer | `sops edit`, rotasi |

## Kenapa bukan yang lain

| Alternatif | Alasan ditolak |
|---|---|
| Sealed Secrets | Enkripsi terikat satu cluster; tidak bisa di-review lintas env; rotasi kaku |
| plain Secret + RBAC | Tidak ada audit trail di Git, tidak portabel |
| External Secrets + Vault saja | Bagus, tapi solusi "secret zero" tetap butuh mekanisme bootstrap — SOPS mengisi celah itu |
| git-crypt | Enkripsi seluruh file → diff tidak terbaca, tidak cocok untuk GitOps |
| Infisical | Menarik, tapi menambah dependensi SaaS/self-host baru tanpa keunggulan untuk kasus ini |

## Keputusan desain penting

- **`encrypted_regex: ^(data|stringData)$`** — hanya value yang dienkripsi. Metadata
  (`name`, `namespace`, `labels`) tetap plaintext sehingga **diff ArgoCD tetap terbaca** dan
  review MR tetap bermakna.
- **Nama file `*.enc.yaml`** — supaya `gitleaks`, `.gitignore`, dan pre-commit hook bisa
  membedakan ciphertext dari manifest biasa.
- **Rotasi**: `sops updatekeys` saat anggota tim berubah; `sops rotate -i` saat dicurigai bocor.
- **Integritas**: `sops --verify` (MAC) dijalankan di CI untuk mendeteksi ciphertext yang diubah
  manual.

## Konsekuensi

### Positif
- Secret ikut versi kode → rollback secret = rollback commit.
- Partial encryption → MR tetap bisa di-review.
- Tidak ada dependensi runtime ke secret server saat ArgoCD sync.

### Negatif
- Siapa pun yang punya private key bisa membaca **semua** secret level itu → blast radius besar.
  Dimitigasi dengan pemisahan 4 level dan rotasi berkala.
- age tidak punya revocation bawaan; harus rotasi manual.
- Key management jadi tanggung jawab kita, bukan vendor.

## Verifikasi

- `sops filestatus` di pre-commit dan CI.
- Test negatif: commit plaintext → gitleaks gagal → pipeline berhenti.
