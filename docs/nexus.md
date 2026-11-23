# Nexus OSS — artifact hub

> Dokumen ini ada di `docs/` karena Nexus berjalan di **VM sendiri** (Docker Compose),
> bukan di dalam cluster.

## Peran

Satu titik masuk untuk semua artifact. Selain memenuhi kebutuhan registry, Nexus dipakai sebagai
**pull-through cache** sehingga image/dependency tidak diambil langsung dari internet setiap build.

| Repository | Tipe | Format | Dipakai untuk |
|---|---|---|---|
| `oci-hosted` | hosted | docker | image aplikasi hasil build CI |
| `docker-proxy` | proxy | docker | `docker.io` |
| `k8s-proxy` | proxy | docker | `registry.k8s.io` (system image) |
| `npm-proxy` | proxy | npm | dependency Node |
| `maven-central` | proxy | maven2 | dependency Java |
| `pypi-proxy` | proxy | pypi | dependency Python |
| `raw-releases` | hosted | raw | SBOM, laporan scan, binary |

## Hal yang sering terlewat

- **Docker connector butuh port sendiri** (mis. `8082`) atau reverse proxy dengan subdomain.
  Nexus tidak memakai path prefix untuk registry.
- **Cleanup policy wajib aktif** sebelum disk penuh. Jalankan task `compact blob store` berkala.
- **Retention**: image yang di-referensikan manifest `prod` tidak boleh dihapus. Pakai
  `Cleanup Policy` berbasis `lastDownloaded`/`lastBlobUpdated`, bukan "hapus semua".
- **Credential** dibaca aplikasi sebagai `dockerconfigjson` Secret — dibuat dari SOPS, bukan
  `docker login` manual.
- **Jangan simpan secret di repository raw.** Nexus bukan secret store.

## Port yang dipakai cluster

| Port | Repository | Dipakai oleh |
|---|---|---|
| 8082 | `oci-hosted` | push image dari CI, pull di cluster |
| 8083 | `docker-proxy` | mirror `docker.io` (containerd) |
| 8084 | `k8s-proxy` | mirror `registry.k8s.io` (containerd) |

Konfigurasi containerd mengacu ke port di atas — lihat
[`platform/bootstrap/kubeadm/INSTALL.md`](../platform/bootstrap/kubeadm/INSTALL.md) bagian 5.5.

## Format credential (dienkripsi SOPS)

```yaml
# overlays/prod/nexus-pull.enc.yaml
apiVersion: v1
kind: Secret
metadata:
  name: nexus-pull
  namespace: apps
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: '{"auths":{"nexus.gatezero.lab:8082":{"auth":"..."}}}'
```

> Status: **stub**. Isi setelah fase 2 dikerjakan.
