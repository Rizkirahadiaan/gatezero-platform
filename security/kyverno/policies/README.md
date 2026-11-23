# Kyverno policies

Policy dijalankan sebagai **Enforce** di namespace `apps`, dan **Audit** di `kube-system`.

## Daftar policy yang direncanakan

| File | Tujuan | Mode |
|---|---|---|
| `require-signed-images.yaml` | `verifyImages` — hanya image dengan signature Cosign valid | Enforce |
| `disallow-latest-tag.yaml` | tolak tag `latest` / tanpa tag | Enforce |
| `require-security-context.yaml` | `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL | Enforce |
| `require-resource-limits.yaml` | CPU/memory request & limit wajib | Enforce |
| `disallow-privileged.yaml` | tolak privileged, hostPath, hostNetwork, hostPID | Enforce |
| `require-network-policy.yaml` | setiap namespace app wajib punya NetworkPolicy default-deny | Audit |
| `restrict-registries.yaml` | hanya boleh pull dari Nexus | Enforce |
| `require-probes.yaml` | readiness + liveness probe wajib | Audit |

## Catatan implementasi

- Gunakan **`validationFailureAction: Enforce`** hanya setelah policy diuji dengan `kyverno apply`
  (dry-run) terhadap seluruh manifest di `platform/gitops`.
- Sertakan **`PolicyException`** bernama jelas, bukan mengecualikan seluruh namespace.
- `verifyImages` butuh `attestors` berisi public key Cosign **atau** keyless dengan
  `keyless.subject`/`issuer` GitLab OIDC.

## Uji lokal

```bash
kyverno apply security/kyverno/policies/ \
  --resource platform/gitops/overlays/dev/ --policy-report
```

> **Status:** policy belum ada. Item `E1`-`E2` di [ROADMAP](../../../ROADMAP.md).
