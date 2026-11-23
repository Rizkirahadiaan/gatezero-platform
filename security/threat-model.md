# Threat Model — gatezero-platform

Metode: **STRIDE** per komponen. Diperbarui setiap ada komponen baru.

- Versi: 0.1 (draft)
- Pemilik: platform team
- Cakupan: pipeline CI/CD, registry, cluster produksi, secret management

---

## 1. Aset yang dilindungi

| # | Aset | Dampak bila bocor/dirusak |
|---|---|---|
| A1 | Source code + history Git | IP hilang, injeksi backdoor |
| A2 | Kredensial CI (runner token, OIDC) | eksekusi kode arbitrer di pipeline |
| A3 | CA & join material kubeadm | penguasaan cluster penuh |
| A4 | age private key (root/ci/prod/cluster) | dekripsi seluruh secret |
| A5 | OCI image di Nexus | supply chain poisoning |
| A6 | Data produksi (Postgres) | kebocoran data pengguna |
| A7 | Audit log & log aplikasi | hilangnya forensik |

## 2. Aktor & trust boundary

| Aktor | Kepercayaan |
|---|---|
| Developer | medium — bisa merge ke dev, tidak ke prod |
| CI runner | medium — bisa push image, tidak bisa akses cluster |
| ArgoCD | high — bisa apply ke prod |
| Registry (Nexus) | medium — isinya diverifikasi signature |
| Attacker eksternal | low — hanya ingress publik |
| Dependency pihak ketiga | **low** — diperlakukan sebagai untrusted |

Trust boundary: `developer → GitLab`, `GitLab → Nexus`, `GitOps repo → ArgoCD`,
`ArgoCD → cluster`, `cluster → node OS`.

## 3. Tabel STRIDE

| Kategori | Ancaman konkret | Vektor | Mitigasi | Residual |
|---|---|---|---|---|
| **S**poofing | Image palsu menyerupai image resmi | push ke registry dengan nama sama | Cosign sign + Kyverno `verifyImages`, tag immutable `semver+sha` | low |
| S | Penyerang menyamar sebagai ArgoCD | kubeconfig/SA token dicuri | SA token audience-scoped, RBAC minimal, audit log | low |
| S | Akses SSH ke node | key dicuri | key-only + SSH CA short-lived + nftables batasi sumber | low |
| **T**ampering | Manifest diubah di cluster (drift) | `kubectl edit` langsung | ArgoCD `selfHeal`, admission Kyverno, RBAC tolak write manusia | low |
| T | Secret di repo diubah | commit tanpa review | protected branch + 2 approval prod + signed commit | low |
| T | Image di registry dimodifikasi | kredensial push bocor | immutable tag + cosign verify saat admission | low |
| T | Dependency confusion | paket nama mirip di registry publik | Nexus group + scoped registry + Renovate allowlist | medium |
| **R**epudiation | Tidak ada jejak siapa deploy apa | akses langsung ke cluster | audit log apiserver → Loki, ArgoCD history, signed commit | low |
| **I**nformation disclosure | Secret terbaca di repo/CI log | commit plaintext, `echo $SECRET` | SOPS, masked var, gitleaks, `set +x` di script | medium |
| I | Secret terbaca di etcd | disk node dicuri | encryption-at-rest + SOPS | low |
| I | Bocor lewat log aplikasi | logging PII | redaksi di OTel processor, review log policy | medium |
| I | Metadata registry terbuka | Nexus anonim read | auth required, RBAC per repo, network policy | low |
| **D**enial of service | Resource exhaustion oleh workload | tanpa limit | ResourceQuota + LimitRange + PDB + PSA | medium |
| D | Pipeline membanjiri registry | build loop | rate limit, retention policy, concurrency limit runner | medium |
| D | Node disk penuh (image/log) | tanpa garbage collection | kubelet GC threshold, Loki retention, Nexus cleanup task | medium |
| **E**levation of privilege | Container escape | privileged pod, hostPath | PSA restricted + Kyverno deny privileged/hostPath + seccomp/apparmor | low |
| E | Runner dipakai pivot ke cluster | runner punya SA token | runner di namespace terpisah, tanpa RBAC ke app namespace, `automountServiceAccountToken: false` | medium |
| E | `:latest` + `imagePullPolicy: Always` | tag diganti | Kyverno tolak tag non-immutable | low |

## 4. Ancaman yang **tidak** dimitigasi (disadari)

| Ancaman | Alasan | Rencana |
|---|---|---|
| Kompromi host Nutanix / hypervisor | di luar cakupan aplikasi | serahkan ke tim infra, dokumentasikan asumsi |
| Supply chain serangan pada upstream image builder | BuildKit image dari Docker Hub | pin digest + verifikasi provenance (SLSA) sebagai backlog |
| Insider dengan akses root ke node | perlu akses fisik/console | audit + break-glass procedure |

## 5. Skenario demo (dipakai di portofolio)

1. Secret plaintext → gitleaks blokir.
2. Dependency CVE → Trivy blokir → Renovate perbaiki.
3. Image tanpa signature → Kyverno tolak.
4. Pod privileged → PSA + Kyverno tolak.
5. Drift manual di cluster → ArgoCD kembalikan.

## 6. Review

Threat model di-review setiap: komponen baru, perubahan trust boundary, dan sebelum rilis mayor.
