# ADR-0006: ArgoCD dengan model pull-based, bukan push dari CI

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Bagaimana perubahan mencapai cluster produksi.

## Keputusan

**Pull-based GitOps.** CI tidak memiliki kredensial cluster. CI hanya:

1. build & scan image,
2. push ke Nexus,
3. commit tag baru ke repo GitOps (`overlays/<env>/kustomization.yaml`).

ArgoCD (in-cluster) yang menarik perubahan, sync, dan melaporkan status.

## Detail

| Aspek | Keputusan |
|---|---|
| Struktur | app-of-apps, satu root Application |
| Multi-env | `ApplicationSet` per environment |
| Prod sync | **manual** (`syncPolicy.automated` hanya dev/staging) |
| Prune | otomatis di dev, manual di prod |
| Self-heal | aktif di semua env untuk melawan drift |
| Progressive delivery | Argo Rollouts canary (10% → 50% → 100%) |
| Secret | CMP sidecar dengan `ksops`, key dari Secret `sops-age` |
| Notification | ArgoCD Notifications → Slack/Telegram |

## Konsekuensi

### Positif
- Tidak ada kredensial cluster di CI → blast radius kompromi CI mengecil drastis.
- State cluster selalu bisa direkonsiliasi dari Git (DR = restore Git + sync).
- Audit trail alami: setiap perubahan = satu commit.
- Manual gate produksi memberi kontrol tanpa memblokir dev.

### Negatif
- Dua repo (app + gitops) atau satu repo dua direktori → butuh disiplin commit balik.
- Latensi deploy lebih tinggi (polling/sync interval) dibanding `kubectl apply` langsung.
- Debugging butuh melihat ArgoCD, bukan log CI.

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| `kubectl apply` dari CI | CI butuh kredensial cluster penuh; tidak ada rekonsiliasi drift |
| Helm upgrade dari CI | State tidak terdeteksi saat drift; rollback manual |
| Flux | Setara secara fungsional; ArgoCD dipilih karena UI lebih kuat untuk portofolio dan adopsi lebih luas |
