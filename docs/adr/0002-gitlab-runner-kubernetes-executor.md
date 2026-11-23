# ADR-0002: GitLab Runner dengan kubernetes executor di dalam cluster

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** GitLab self-managed sudah berjalan di VM sendiri. Perlu runner untuk build &
  scan tanpa memberi CI akses langsung ke cluster.

## Keputusan

Satu runner manager (Deployment) dengan **kubernetes executor**, terdaftar ke GitLab yang sudah
ada menggunakan **runner authentication token** (`glrt-…`, GitLab 17+). Setiap job berjalan
sebagai pod ephemeral di namespace `gitlab-runner`.

## Detail penting

| Aspek | Keputusan |
|---|---|
| Eksekusi build | job memanggil **remote rootless BuildKit**, bukan DinD privileged |
| Namespace | `gitlab-runner`, terpisah dari `apps` |
| ServiceAccount | `automountServiceAccountToken: false` — CI tidak butuh akses API k8s |
| Concurrency | 4 job paralel, resource request/limit eksplisit |
| Cache | Nexus (bukan cache GitLab) untuk dependency |
| Kredensial | token runner disimpan sebagai Secret dari SOPS |

## Konsekuensi

### Positif
- Runner elastis: job selesai → pod mati → tidak ada sisa state/build cache berbahaya.
- Tidak perlu VM tambahan atau `docker` daemon di host.
- Isolasi per job lebih baik daripada docker executor di VM bersama.

### Negatif
- Butuh rootless BuildKit sebagai layer tambahan (lihat ADR-0004).
- Cold start image pull lebih lambat; dimitigasi oleh cache Nexus + `imagePullPolicy: IfNotPresent`.
- Perlu perhatian pada `kernel.apparmor_restrict_unprivileged_userns` di worker.

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| Docker executor di VM | Job berbagi daemon Docker → satu escape = semua job terekspos |
| DinD privileged | Melanggar baseline PSA/Kyverno yang kita bangun sendiri |
| Shell executor | Tidak reproducible, mencemari host |

## Catatan

Runner sengaja **tidak** diberi RBAC ke namespace aplikasi. CI tidak boleh bisa deploy —
deployment adalah wewenang ArgoCD (ADR-0006).
