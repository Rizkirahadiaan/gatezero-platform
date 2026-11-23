# Bootstrap

Semua langkah instalasi awal, dibuat **idempoten** dan bisa dijalankan ulang.

| Direktori | Isi |
|---|---|
| `kubeadm/` | config cluster HA, kube-vip, manifest join, script init |
| `cilium/` | values Cilium (kube-proxy replacement, L2 LB, Gateway API, Hubble) |
| `cert-manager/` | issuer Let's Encrypt DNS-01 + wildcard certificate |

## 📖 Runbook instalasi

Langkah lengkap dari 3 VM kosong → cluster HA siap menerima ArgoCD:

### ➡️ [`kubeadm/INSTALL.md`](kubeadm/INSTALL.md)

21 bagian: prasyarat & topologi, hardening OS, containerd, kube-vip, kubeadm config,
init, join CP/worker, Cilium, Gateway API + cert-manager, storage, encryption at rest,
backup etcd, verifikasi HA, upgrade, troubleshooting, checklist produksi.

### ➡️ [`ansible/`](ansible/) — versi otomasi

Playbook yang mengeksekusi runbook di atas secara idempoten:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
cp secrets.env.example secrets.env      # isi, lalu enkripsi dengan SOPS
./run.sh site.yml
```

Bedanya: `INSTALL.md` menjelaskan **kenapa**, `ansible/` mengeksekusi **apa**.
Kalau keduanya berbeda, `INSTALL.md` yang benar.

## Urutan eksekusi (jangan diubah)

```
1. provision VM + cloud-init
2. hardening OS (infra/vm/HARDENING.md)   <- sebelum k8s
3. benchmark baseline (infra/benchmark)
4. kubeadm init HA + join            <- INSTALL.md
5. cilium
6. cert-manager + gateway
7. argocd (bootstrap app-of-apps)
```

Alasan urutan: hardening setelah cluster jadi akan memutus kubelet/koneksi, dan baseline
performa harus diambil sebelum hardening supaya delta-nya bisa diukur.

## Prasyarat ringkas

- 3 VM control plane (4 vCPU / 8 GB / 60 GB + vDisk etcd 40 GB)
- 3 VM worker (8 vCPU / 16 GB / 200 GB)
- VIP `10.10.20.10` di VLAN yang sama (mode ARP kube-vip)
- DNS: `k8s-api.kirahadian.local` → VIP
- Ubuntu 24.04, chrony sinkron, swap off, containerd 2.x

## Secret bootstrap

`kubeadm` butuh dua material rahasia yang harus didistribusikan ke node lain:

| Material | Cara distribusi |
|---|---|
| `--certificate-key` | `kubeadm/cert-key.enc.yaml` (SOPS) |
| bootstrap token / discovery file | `kubeadm/bootstrap-token.enc.yaml` (SOPS) |
| encryption-at-rest key | `kubeadm/encryption-config.enc.yaml` (SOPS + salinan offline) |

Keduanya dibaca di jumpbox lewat `sops -d`, tidak pernah masuk shell history atau CI variable
plaintext. Setelah semua node join, hapus Secret `kube-system/kubeadm-certs`.

> Aturan SOPS untuk direktori ini ada di `platform/bootstrap/.sops.yaml` (memakai **root key**),
> terpisah dari `platform/gitops/.sops.yaml` karena `sops` mencari config ke folder atas.
