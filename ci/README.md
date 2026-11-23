# CI (GitLab)

Semua job dipanggil dari `templates/`. Tujuan: pipeline aplikasi cukup `include` template,
tidak menulis YAML 300 baris setiap repo baru.

## Stage

| Stage | Job | Gate |
|---|---|---|
| validate | yamllint, hadolint, shellcheck, kubeconform, commitlint | blocking |
| secret-scan | gitleaks + sops filestatus | **blocking** |
| test | unit test + coverage report | blocking |
| quality | SonarQube scan + `sonar.qualitygate.wait=true` | **blocking** |
| sast | Semgrep OSS | blocking (HIGH) |
| sca | Trivy fs + Syft SBOM | blocking (HIGH/CRITICAL) |
| build | BuildKit rootless → Nexus | — |
| image-scan | Trivy image + `cosign sign` | blocking (HIGH/CRITICAL) |
| policy | Conftest / Kyverno CLI dry-run | blocking |
| release | commit tag baru ke repo GitOps | — |
| deploy | ArgoCD sync dev/staging; prod manual | manual gate |

## Aturan

1. **Tidak ada `kubectl apply` di CI.** Hanya commit ke repo GitOps.
2. **Tidak ada credential cluster di CI.** Argocd hanya diakses untuk read status.
3. **`allow_failure: false`** untuk semua gate keamanan. Gate yang boleh gagal bukan gate.
4. **Cache** pakai Nexus, bukan cache GitLab untuk dependency.
5. **Artifact wajib disimpan**: SBOM, trivy report, sonar report — retensi 90 hari.

## Struktur

```
templates/
├── 00-validate.yml
├── 10-secret-scan.yml
├── 20-test.yml
├── 30-quality.yml
├── 40-build.yml
├── 50-scan-sign.yml
└── 60-release.yml
scripts/
├── build-image.sh       # buildctl/buildx ke Nexus
├── sbom.sh              # syft + attest
├── sign.sh              # cosign keyless (GitLab OIDC)
└── bump-gitops.sh       # update image tag di repo GitOps
```

> Status: **stub**. Diisi saat fase 3 dikerjakan.
