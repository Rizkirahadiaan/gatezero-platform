# GitOps (ArgoCD)

## Pola

**App-of-apps**: satu root Application berisi daftar Application lain. Root ini yang di-bootstrap
manual sekali; selanjutnya semua perubahan lewat Git.

```
gitops/
├── argocd/apps/          # definisi Application (per komponen & per environment)
├── argocd/projects/      # AppProject (batas RBAC + source/destination repo)
├── overlays/local/       # overlay untuk cluster lokal (dev laptop)
├── overlays/dev/         # cluster dev
├── overlays/prod/        # cluster produksi
└── .sops.yaml            # aturan enkripsi (relatif terhadap direktori ini)
```

## Konvensi

- **Satu Application per environment.** Jangan satu Application untuk semua env.
- **Prod = manual sync.** `syncPolicy.automated` hanya untuk dev/staging.
- **`prune: true` + `selfHeal: true`** di dev; di prod `selfHeal: true` tapi `prune` manual.
- **Sync wave** dipakai untuk urutan: CRD → operator → workload.
- **Image tag immutable**: `{semver}-{gitsha}`, bukan `latest`, bukan `stable`.
- **SOPS decryption via CMP sidecar** (`ksops`), bukan plugin yang sudah tidak dirawat.

## Alur perubahan image

```
CI build -> push ke Nexus -> commit tag baru ke overlays/<env>/kustomization.yaml
   -> ArgoCD detect OutOfSync -> sync -> Kyverno verify signature -> pod jalan
```

CI **tidak** memegang kredensial cluster. Ini inti dari pull-based deployment.

> **Status:** manifest belum ada. Item `G3`-`G9` di [ROADMAP](../../ROADMAP.md).
