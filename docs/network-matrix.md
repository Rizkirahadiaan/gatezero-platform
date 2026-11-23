# Network Matrix

Satu tabel untuk menjawab: **"port apa, dari mana, ke mana, dan kenapa"**.

Dirujuk oleh:
- [`platform/bootstrap/kubeadm/INSTALL.md`](../platform/bootstrap/kubeadm/INSTALL.md) §3
- [`infra/vm/ansible/roles/nftables_firewall`](../infra/vm/ansible/roles/nftables_firewall)
- [`infra/vm/HARDENING.md`](../infra/vm/HARDENING.md) §10

---

## 1. Zona

| Zona | CIDR | Isi |
|---|---|---|
| `admin` | `10.10.20.0/24` | jumpbox, akses operator, Ansible controller |
| `cluster` | `10.10.20.0/24` | 3 control plane + 3 worker |
| `services` | `10.10.20.0/24` | GitLab, SonarQube, Nexus, object storage |
| `world` | `0.0.0.0/0` | hanya untuk layanan yang memang publik |

> Saat ini semuanya satu flat VLAN. Kalau nanti dipisah, ubah
> `firewall_admin_cidrs` / `firewall_cluster_cidrs` di
> `infra/vm/ansible/inventory/group_vars/all/main.yml`.

---

## 2. Port per peran VM

### jumpbox — `10.10.20.5`

| Port | Proto | Sumber | Tujuan |
|---|---|---|---|
| 22 | TCP | admin | SSH / Ansible controller |

### gitlab-prod — `10.10.20.6`

| Port | Proto | Sumber | Tujuan |
|---|---|---|---|
| 22 | TCP | admin | SSH |
| 80, 443 | TCP | world | Web UI + Git over HTTPS |
| 2222 | TCP | cluster | Git over SSH (port alternatif agar 22 bebas) |

### svc-sonar-01 — `10.10.20.7`

| Port | Proto | Sumber | Tujuan |
|---|---|---|---|
| 22 | TCP | admin | SSH |
| 9000 | TCP | cluster | SonarQube web + scanner API |

### svc-nexus-01 — `10.10.20.8`

| Port | Proto | Sumber | Tujuan |
|---|---|---|---|
| 22 | TCP | admin | SSH |
| 8081 | TCP | cluster | Nexus UI + REST API |
| 8082 | TCP | cluster | Docker **hosted** (`oci-hosted`) |
| 8083 | TCP | cluster | Docker **proxy** (`docker.io` mirror) |
| 8084 | TCP | cluster | Docker **proxy** (`registry.k8s.io` mirror) |

### svc-s3-01 — `10.10.20.9`

| Port | Proto | Sumber | Tujuan |
|---|---|---|---|
| 22 | TCP | admin | SSH |
| 9000 | TCP | cluster | S3 API (Loki, Tempo, Thanos, Velero, etcd backup) |
| 9001 | TCP | admin | S3 console |

> Nexus OSS **tidak bisa** memakai path prefix untuk registry. Karena itu ia
> butuh port sendiri atau subdomain terpisah — lihat [`nexus.md`](nexus.md).

---

## 3. Port node Kubernetes

### Control plane (`10.10.20.11–13`)

| Port | Proto | Sumber | Tujuan | Keterangan |
|---|---|---|---|---|
| 22 | TCP | admin | SSH | |
| 6443 | TCP | cluster + admin | kube-apiserver | juga target VIP `10.10.20.10` |
| 2379 | TCP | CP peers + monitoring | etcd client | TLS + client-cert-auth |
| 2380 | TCP | CP peers | etcd peer | |
| 2381 | TCP | monitoring | etcd metrics | **HTTP tanpa auth** — batasi |
| 10257 | TCP | CP peers | controller-manager | |
| 10259 | TCP | CP peers | scheduler | |
| 10250 | TCP | CP + monitoring | kubelet API | |
| 4240 | TCP | cluster | Cilium health | |
| 8472 | **UDP** | cluster | VXLAN Cilium | |
| 9100 | TCP | monitoring | node-exporter | |

### Worker (`10.10.20.21–23`)

| Port | Proto | Sumber | Tujuan | Keterangan |
|---|---|---|---|---|
| 22 | TCP | admin | SSH | |
| 10250 | TCP | CP + monitoring | kubelet API | |
| 4240 | TCP | cluster | Cilium health | |
| 8472 | **UDP** | cluster | VXLAN Cilium | |
| 9100 | TCP | monitoring | node-exporter | |
| 30000–32767 | TCP | LB/Gateway | NodePort | hanya jika Gateway memakai NodePort |

---

## 4. Arah koneksi

```
   admin (operator)
        │ 22 / 6443 / 8081 / 9000
        ▼
   ┌──────────┐        ┌──────────────┐
   │ jumpbox  │───────►│  services    │  GitLab :443, Nexus :8081–8084,
   └────┬─────┘        │  VM          │  Sonar :9000, S3 :9000
        │              └──────┬───────┘
        │ 6443                │ 6443 (CI push image, sonar scan)
        ▼                     ▼
   ┌────────────────────────────────────┐
   │ VIP 10.10.20.10:6443               │
   └──────┬──────────────┬──────────────┘
          │              │
   ┌──────▼──────┐ ┌─────▼───────┐
   │ CP  x3      │ │ Worker x3   │
   │ etcd 2379/  │ │ kubelet     │
   │ 2380, VXLAN │ │ 10250, VXLAN│
   └─────────────┘ └─────────────┘
```

**Egress wajib dari node & VM:**

| Tujuan | Port | Kenapa |
|---|---|---|
| Nexus | 8081–8084 | image & dependency (kalau mirror aktif) |
| DNS internal | 53 | resolusi |
| NTP internal | 123/UDP | waktu (kritis untuk etcd & TLS) |
| Internet | 443 | hanya jika tidak memakai mirror Nexus |

Bila `nexus_mirror_enabled: true`, node **tidak perlu** akses langsung ke `docker.io`
atau `registry.k8s.io` — semuanya lewat Nexus.

---

## 5. Implementasi di nftables

Role [`nftables_firewall`](../infra/vm/ansible/roles/nftables_firewall) memetakan tabel di atas
ke variabel inventory:

| Variabel | Arti | Contoh |
|---|---|---|
| `firewall_admin_cidrs` | sumber yang boleh SSH | `10.10.20.0/24` |
| `firewall_cluster_cidrs` | sumber trafik internal | `10.10.20.0/24` |
| `firewall_allowed_tcp` | port dari jaringan cluster | `[6443, 2379, ...]` |
| `firewall_allowed_udp` | port UDP dari cluster | `[8472]` |
| `firewall_allowed_from_world_tcp` | port publik | `[80, 443]` |
| `firewall_extra_allowed_tcp` | port tambahan dari admin | `[9100]` |

Port per host didefinisikan di [`inventory/hosts.yml`](../infra/vm/ansible/inventory/hosts.yml).

> ⚠️ **Jangan** memasang `ufw` bersamaan dengan Cilium. Role akan gagal kalau `ufw` aktif.

---

## 6. Verifikasi

```bash
# port yang benar-benar listen
sudo ss -tulpn

# ruleset aktif
sudo nft list ruleset

# uji dari jumpbox
nc -zv 10.10.20.10 6443
nc -zvu 10.10.20.21 8472

# uji dari dalam cluster (pod)
kubectl run nettest --rm -it --image=nicolaka/netshoot --restart=Never -- \
  nc -zv 10.10.20.8 8082
```

---

## 7. Yang paling sering terlewat

| Item | Gejala kalau salah |
|---|---|
| **8472/UDP (VXLAN)** | pod antar-node tidak bisa saling ping, DNS timeout |
| **4240/TCP (Cilium health)** | `cilium status` degraded, endpoint tidak sehat |
| **2380/TCP (etcd peer)** | member kedua tidak bisa join, quorum gagal |
| **10250 dari CP** | `kubectl logs`/`exec` timeout, metrics-server gagal |
| **Egress 53/123** | resolusi gagal, sertifikat & etcd error aneh |
| **NodePort range** | Gateway tidak bisa diakses dari luar |
| **MTU** | ping normal tapi TLS handshake menggantung |

---

## 8. Kalau memisah VLAN

Ubah tiga hal sekaligus, jangan satu-satu:

1. `firewall_admin_cidrs`, `firewall_cluster_cidrs` di `group_vars/all/main.yml`
2. `pod_subnet` / `service_subnet` — pastikan **tidak overlap** dengan LAN mana pun
3. `kubevip_interface` — VIP harus di VLAN yang bisa dijangkau semua node

Setelah itu jalankan `nftables_firewall` ulang dan uji dengan `nc` dari kedua sisi
sebelum menutup sesi SSH yang lama.
