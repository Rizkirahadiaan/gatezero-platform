# Helm charts internal

Chart yang ditulis sendiri (bukan upstream). Upstream chart dipasang ArgoCD langsung dari repo
helm-nya, jangan di-vendor ke sini kecuali perlu patch permanen.

Rencana chart:

| Chart | Isi |
|---|---|
| `demo-api` | Deployment, Service, ServiceMonitor, PodDisruptionBudget, NetworkPolicy |
| `demo-worker` | Deployment, KEDA ScaledObject (opsional), NetworkPolicy |
| `platform-lib` | helper template bersama (label, resource default, security context) |

## Standar wajib di setiap chart

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

Tanpa ini, Kyverno akan menolak workload di namespace `apps`.

> **Status:** chart belum ada. Item `A7` di [ROADMAP](../../ROADMAP.md).
