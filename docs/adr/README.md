# Architecture Decision Records

| # | Judul | Status |
|---|---|---|
| [0001](0001-kubeadm-over-k3s.md) | kubeadm (HA, stacked etcd) sebagai distro cluster produksi | Accepted |
| [0002](0002-gitlab-runner-kubernetes-executor.md) | GitLab Runner dengan kubernetes executor di dalam cluster | Accepted |
| [0003](0003-nexus-oss-as-artifact-hub.md) | Nexus OSS sebagai artifact hub tunggal | Accepted |
| [0004](0004-buildkit-rootless-over-kaniko.md) | BuildKit rootless menggantikan Kaniko | Accepted |
| [0005](0005-sops-age-secret-management.md) | SOPS + age sebagai mekanisme secret management | Accepted |
| [0006](0006-argocd-pull-based-gitops.md) | ArgoCD dengan model pull-based, bukan push dari CI | Accepted |
| [0007](0007-cosign-keyless-kyverno-verify.md) | Cosign keyless + verifikasi signature di admission | Accepted |
| [0008](0008-cilium-cni-kube-proxy-replacement.md) | Cilium sebagai CNI sekaligus pengganti kube-proxy/LB/ingress | Accepted |
| [0009](0009-etcd-dedicated-disk-and-backup.md) | vDisk etcd terpisah + backup level API, bukan VM snapshot | Accepted |
| [0010](0010-cis-hardening-exceptions.md) | Daftar pengecualian CIS untuk node Kubernetes | Accepted |
| [0011](0011-observability-stack.md) | Prometheus + Alloy/Loki + Tempo + Grafana | Accepted |
| [0012](0012-sonarqube-community-build-limitation.md) | Strategi quality gate dengan keterbatasan Community Build | Accepted |

## Konvensi

- Status: `Proposed` → `Accepted` → (`Deprecated` | `Superseded by NNNN`)
- ADR **tidak dihapus**. Kalau keputusan berubah, buat ADR baru dan tandai yang lama
  `Superseded by NNNN`.
- Setiap ADR minimal menyebutkan satu alternatif yang ditolak dan alasannya.
