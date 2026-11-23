# Security

Lapisan keamanan platform. Prinsipnya: **setiap kontrol punya gate otomatis**, dan setiap
pengecualian punya alasan tertulis.

| Direktori | Isi |
|---|---|
| `kyverno/policies/` | admission policy (signature, tag, security context, resource limit) |
| `trivy/` | ignorefile + konfigurasi scan |
| `threat-model.md` | model ancaman STRIDE |

## Kontrol per tahap

| Tahap | Kontrol | Tool | Sifat |
|---|---|---|---|
| Commit | deteksi secret | gitleaks (pre-commit + CI) | blocking |
| Commit | konvensi commit | conventional-pre-commit | blocking |
| MR | SAST | Semgrep | blocking (HIGH) |
| MR | quality gate | SonarQube | blocking |
| Build | SBOM | Syft (CycloneDX) | artifact |
| Build | scan image | Trivy | blocking (HIGH/CRITICAL) |
| Publish | signature | Cosign keyless (GitLab OIDC) | artifact |
| Deploy | verifikasi signature | Kyverno `verifyImages` | blocking |
| Deploy | baseline pod | Pod Security Admission `restricted` | blocking |
| Runtime | anomali syscall | Tetragon / Falco | alert |
| Runtime | CVE berjalan | Trivy Operator | alert |
| Posture | CIS k8s | kube-bench | laporan + trend |
| Posture | framework | Kubescape (NSA/CISA, MITRE) | laporan + trend |
| VM | CIS OS | Lynis + OpenSCAP | laporan + trend |
| Data | secret at rest | SOPS + age, etcd encryption-at-rest | blocking |

## Aturan pengecualian

Menambah entri ke `trivy/ignore.yaml` atau menonaktifkan policy Kyverno **wajib** menyertakan:

1. CVE / kontrol yang dikecualikan
2. Alasan teknis
3. Mitigasi pengganti
4. Tanggal kedaluwarsa (`expired_at`)

Tanpa itu, reviewer menolak. Lihat `docs/adr/0010-cis-hardening-exceptions.md`.
