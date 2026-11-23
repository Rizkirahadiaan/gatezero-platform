# Instalasi Kubernetes dengan kubeadm — Production Runbook

> **Tujuan dokumen:** dari 3 VM kosong menjadi cluster Kubernetes HA yang siap menerima ArgoCD.
> Ditulis untuk dijalankan **berurutan**. Setiap langkah punya cara verifikasi.
>
> Estimasi waktu: **2–3 jam** (tanpa hardening OS mendalam).
> Prasyarat hardening OS + benchmark: lihat `infra/vm/` dan `infra/benchmark/`.

---

## Daftar Isi

1. [Ruang lingkup & hasil akhir](#1-ruang-lingkup--hasil-akhir)
2. [Variabel & topologi](#2-variabel--topologi)
3. [Prasyarat infrastruktur](#3-prasyarat-infrastruktur)
4. [Persiapan OS (semua node)](#4-persiapan-os-semua-node)
5. [Container runtime: containerd](#5-container-runtime-containerd)
6. [Tool Kubernetes + versi di-pin](#6-tool-kubernetes--versi-di-pin)
7. [VIP API server: kube-vip](#7-vip-api-server-kube-vip)
8. [Konfigurasi kubeadm](#8-konfigurasi-kubeadm)
9. [Init control plane pertama](#9-init-control-plane-pertama)
10. [Join control plane kedua & ketiga](#10-join-control-plane-kedua--ketiga)
11. [Join worker node](#11-join-worker-node)
12. [CNI: Cilium](#12-cni-cilium)
13. [Gateway API + cert-manager](#13-gateway-api--cert-manager)
14. [Storage & metrics-server](#14-storage--metrics-server)
15. [Hardening pasca-install](#15-hardening-pasca-install)
16. [Backup etcd & PKI](#16-backup-etcd--pki)
17. [Verifikasi akhir](#17-verifikasi-akhir)
18. [Upgrade & maintenance](#18-upgrade--maintenance)
19. [Reset / teardown](#19-reset--teardown)
20. [Troubleshooting](#20-troubleshooting)
21. [Checklist produksi](#21-checklist-produksi)

---

## 1. Ruang lingkup & hasil akhir

Yang akan terbentuk:

```
                        ┌─────────────────────────────┐
   kubectl/argocd  ───► │ VIP 10.10.20.10:6443        │  (kube-vip, ARP)
                        └──────────┬──────────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
  ┌─────▼─────┐             ┌──────▼────┐              ┌──────▼────┐
  │ k8s-cp-01 │             │ k8s-cp-02 │              │ k8s-cp-03 │
  │ apiserver │             │ apiserver │              │ apiserver │
  │ etcd      │◄───────────►│ etcd      │◄────────────►│ etcd      │
  └───────────┘             └───────────┘              └───────────┘
        │                          │                          │
        └──────────────────────────┼──────────────────────────┘
                                   │  Cilium (VXLAN, kube-proxy replacement)
        ┌──────────────────────────┼──────────────────────────┐
  ┌─────▼─────┐             ┌──────▼────┐              ┌──────▼────┐
  │ k8s-w-01  │             │ k8s-w-02  │              │ k8s-w-03  │
  └───────────┘             └───────────┘              └───────────┘
```

**Yang TIDAK termasuk di dokumen ini** (sudah ada / terpisah):

| Kebutuhan | Lokasi dokumen |
|---|---|
| GitLab CE | sudah berjalan di VM sendiri |
| Nexus / SonarQube | VM sendiri, `docker compose` |
| Hardening OS + CIS | `docs/adr/0010-cis-hardening-exceptions.md`, `infra/vm/` |
| Benchmark performa | `infra/benchmark/README.md` |
| ArgoCD & GitOps | `platform/gitops/README.md` |
| Secret management | `docs/adr/0005-sops-age-secret-management.md` |

---

## 2. Variabel & topologi

> Ganti nilai di tabel ini **sebelum** menyalin perintah. Konsisten di seluruh dokumen.

| Variabel | Nilai contoh | Keterangan |
|---|---|---|
| `VIP` | `10.10.20.10` | Virtual IP API server |
| `LB_HOST` | `k8s-api.gatezero.lab` | DNS → VIP |
| `POD_CIDR` | `10.244.0.0/16` | harus tidak overlap dengan jaringan Nutanix |
| `SVC_CIDR` | `10.96.0.0/12` | |
| `IFACE` | `ens192` | cek `ip -br a` di VM |
| `K8S_VER` | `1.34` | pin N-1 dari rilis terbaru |
| `NEXUS` | `nexus.gatezero.lab` | artifact hub |

| Host | IP | vCPU | RAM | vDisk 1 (OS) | vDisk 2 (data) |
|---|---|---|---|---|---|
| `k8s-cp-01` | `10.10.20.11` | 4 | 8 GB | 60 GB | 40 GB `etcd` |
| `k8s-cp-02` | `10.10.20.12` | 4 | 8 GB | 60 GB | 40 GB `etcd` |
| `k8s-cp-03` | `10.10.20.13` | 4 | 8 GB | 60 GB | 40 GB `etcd` |
| `k8s-w-01` | `10.10.20.21` | 8 | 16 GB | 200 GB | — |
| `k8s-w-02` | `10.10.20.22` | 8 | 16 GB | 200 GB | — |
| `k8s-w-03` | `10.10.20.23` | 8 | 16 GB | 200 GB | — |
| VIP | `10.10.20.10` | — | — | — | — |

**OS:** Ubuntu 24.04 LTS, minimal install, tanpa desktop.

### Layout partisi

Aturan yang mengatur layout ini:

1. **etcd selalu di vDisk terpisah** — image pull tidak boleh memblokir `fsync` etcd.
2. **`/var/lib/containerd` selalu filesystem sendiri** — supaya kubelet bisa membedakan
   `nodefs` dan `imagefs`, dan eviction bekerja independen.
3. **Data disk pakai `LABEL=`, bukan `/dev/sdX`** — urutan device Nutanix bisa berubah.
4. **Tidak ada swap** dan **tidak ada `nofail`** untuk etcd/containerd.

#### Control plane — vDisk 1 (60 GB, `/dev/sda`)

```
/dev/sda  60 GB
├── sda1    1 GB    EFI System (ef00)        /boot/efi              vfat
├── sda2    2 GB    Linux filesystem (8300)  /boot                  ext4
└── sda3   ~57 GB   Linux LVM (8e00)  ──►    VG vg0
     ├── lv_root        18 GB   /                     xfs
     ├── lv_containerd  18 GB   /var/lib/containerd   xfs
     ├── lv_var         12 GB   /var                  xfs
     ├── lv_log          5 GB   /var/log              xfs
     └── lv_home         2 GB   /home                 xfs
         sisa VG ~2 GB  (cadangan untuk pertumbuhan)
```

#### Control plane — vDisk 2 (40 GB, `/dev/sdb`)

```
/dev/sdb  40 GB
└── sdb1   40 GB    Linux filesystem (8300)   /var/lib/etcd   ext4  LABEL=etcd
```

#### Worker — vDisk 1 (200 GB, `/dev/sda`)

```
/dev/sda  200 GB
├── sda1    1 GB    EFI System (ef00)        /boot/efi              vfat
├── sda2    2 GB    Linux filesystem (8300)  /boot                  ext4
└── sda3  ~197 GB   Linux LVM (8e00)  ──►    VG vg0
     ├── lv_root         18 GB   /                     xfs
     ├── lv_containerd  120 GB   /var/lib/containerd   xfs
     ├── lv_var          40 GB   /var                  xfs
     ├── lv_log          15 GB   /var/log              xfs
     └── lv_home          2 GB   /home                 xfs
         sisa VG ~2 GB
```

> Worker hanya punya satu vDisk, tapi tetap mendapat `nodefs`/`imagefs` terpisah
> karena `/var/lib/containerd` adalah **LV sendiri** — bukan karena disk berbeda.
> Yang penting adalah filesystem-nya berbeda, bukan device-nya.

#### `/etc/fstab`

```fstab
# --- control plane ---
UUID=<esp>        /boot/efi            vfat   umask=0077                        0 1
UUID=<boot>       /boot                ext4   defaults                          0 2
/dev/vg0/lv_root        /                     xfs    defaults                    0 0
/dev/vg0/lv_var         /var                  xfs    defaults,noatime            0 0
/dev/vg0/lv_containerd  /var/lib/containerd   xfs    defaults,noatime,nodev,nosuid 0 0
/dev/vg0/lv_log         /var/log             xfs    defaults,nodev,nosuid,noatime 0 0
/dev/vg0/lv_home        /home                xfs    defaults,nodev,nosuid,noatime 0 0

# etcd: TANPA nofail. Disk hilang = node HARUS gagal boot.
LABEL=etcd        /var/lib/etcd        ext4   defaults,noatime,nodev,nosuid     0 2
```

```fstab
# --- worker ---
/dev/vg0/lv_root        /                     xfs    defaults                    0 0
/dev/vg0/lv_var         /var                  xfs    defaults,noatime            0 0
/dev/vg0/lv_containerd  /var/lib/containerd   xfs    defaults,noatime,nodev,nosuid 0 0
/dev/vg0/lv_log         /var/log             xfs    defaults,nodev,nosuid,noatime 0 0
/dev/vg0/lv_home        /home                xfs    defaults,nodev,nosuid,noatime 0 0
```

> ⚠️ **`nofail` pada `/var/lib/etcd` adalah bug fatal**, bukan kenyamanan.
> Kalau disk gagal mount tapi node tetap boot, etcd membuat database kosong di disk OS,
> node join ulang sebagai member "baru", dan **quorum/data cluster hilang**.
> Tanpa `nofail`, node gagal boot → alarm berbunyi → kamu sadar.

#### BIOS, bukan UEFI

Ganti `sda1` menjadi 1 MB `bios_grub` (ef02), lalu `sda2` jadi `/boot` 2 GB.
AHV mendukung keduanya; pilih satu dan pakai konsisten di golden image.

#### Kenapa `/var/lib/containerd` dipisah

```
tanpa filesystem terpisah:
  nodefs  = /var   (termasuk image)
  imagefs = sama   →  kubelet: "using nodefs for imagefs"
  → evictionHard.imagefs.available DIABAIKAN
  → satu image 8 GB bisa menghabiskan /var, kubelet mati

dengan filesystem terpisah:
  nodefs  = /var                  (12 GB CP / 40 GB worker)
  imagefs = /var/lib/containerd   (18 GB CP / 120 GB worker)
  → eviction bekerja independen
```

Verifikasi bahwa kubelet benar-benar melihat dua filesystem:

```bash
kubectl get --raw "/api/v1/nodes/k8s-w-01/proxy/stats/summary" \
  | jq '{nodefs: .node.fs, imagefs: .node.runtime.imagefs}'
```

#### Menambah kapasitas

LVM membuat ini bisa dilakukan online, tanpa rebuild node:

```bash
# 1. tambah ukuran vDisk di Prism, lalu resize partisi
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3

# 2. tambah LV yang penuh, lalu grow filesystem
sudo lvextend -L +10G /dev/vg0/lv_var
sudo xfs_growfs /var

# untuk data disk ext4 (etcd)
sudo growpart /dev/sdb 1
sudo resize2fs /dev/sdb1
```

> **Catatan sizing:** 60 GB untuk OS control plane cukup untuk lab, tapi sempit untuk
> upgrade beruntun dan retensi log. Kalau bisa, pakai **80 GB** — `lv_var` dan `lv_log`
> mendapat ruang lebih lega tanpa mengubah layout lain.


### Port yang harus terbuka

| Port | Proto | Sumber | Tujuan |
|---|---|---|---|
| 22 | TCP | jumpbox saja | semua |
| 6443 | TCP | semua node + jumpbox | CP / VIP |
| 2379–2380 | TCP | CP peers | CP |
| 10257, 10259 | TCP | CP peers | CP |
| 10250 | TCP | CP | semua node |
| 4789 atau 8472 | UDP | cluster | semua (VXLAN Cilium) |
| 4240 | TCP | cluster | semua (Cilium health) |
| 30000–32767 | TCP | LB/Gateway | worker |

> Dokumentasikan juga di `docs/network-matrix.md`.

---

## 3. Prasyarat infrastruktur

Checklist sebelum menyentuh OS:

- [ ] 3 CP + 3 worker dibuat dari **golden image** (bukan clone yang berbagi `machine-id`)
- [ ] Setiap CP punya **vDisk terpisah** untuk `/var/lib/etcd` (lihat ADR-0009)
- [ ] `chrony` menunjuk NTP internal (jangan `pool.ntp.org` publik)
- [ ] DNS `k8s-api.gatezero.lab` → `10.10.20.10`
- [ ] VLAN yang sama untuk semua node (kube-vip mode ARP butuh L2 yang sama)
- [ ] MTU: jika Nutanix memakai jumbo frame, catat MTU (akan dipakai Cilium)
- [ ] Snapshot/Protection Domain VM untuk DR (bukan untuk backup etcd)

**Cek `machine-id` unik** (kalau hasil clone):

```bash
# HARUS berbeda di setiap node
cat /etc/machine-id

# Kalau ada yang sama:
sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
sudo systemd-machine-id-setup
sudo rm -f /etc/ssh/ssh_host_*
sudo ssh-keygen -A
sudo systemctl restart ssh
```

> ⚠️ `machine-id` duplikat membuat kubelet, journald, dan DHCP berperilaku tidak terduga.
> Ini penyebab paling sering "node join tapi aneh".

---

## 4. Persiapan OS (semua node)

Jalankan **di semua 6 node**.

### 4.1 Update & paket dasar

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y \
  apt-transport-https ca-certificates curl gnupg jq \
  chrony nfs-common open-iscsi conntrack socat ebtables ethtool
```

### 4.2 Time sync (wajib)

```bash
sudo tee /etc/chrony/chrony.conf >/dev/null <<'EOF'
server ntp1.gatezero.lab iburst
server ntp2.gatezero.lab iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
sudo systemctl enable --now chrony
```

**Verifikasi:**

```bash
chronyc tracking | grep -E 'Leap|System time'
# "Leap status : Normal" dan offset < 100ms
```

> ⚠️ Clock drift merusak TLS, etcd, dan CertificateSigningRequest. Ini bukan opsional.

### 4.3 Swap off (permanen)

```bash
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
```

**Verifikasi:**

```bash
free -h | grep -i swap     # Swap: 0B 0B 0B
swapon --show              # kosong
```

> Kubernetes bisa jalan dengan swap (fitur `NodeSwap`), tapi untuk produksi yang
> ingin perilaku memori prediktabel, matikan.

### 4.4 Kernel module

```bash
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

**Verifikasi:**

```bash
lsmod | grep -E 'overlay|br_netfilter'
```

### 4.5 Sysctl wajib Kubernetes

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/90-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
fs.inotify.max_user_watches         = 1048576
fs.inotify.max_user_instances       = 8192
net.core.somaxconn                  = 32768
EOF

sudo sysctl --system
```

**Verifikasi:**

```bash
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables fs.inotify.max_user_watches
# ip_forward = 1, bridge-nf-call-iptables = 1, watches = 1048576
```

> `fs.inotify.*` dinaikkan karena Prometheus/ArgoCD/CSI membuka banyak watch dan
> default 8192 terlalu kecil → gejala: pod stuck `ContainerCreating` tanpa error jelas.

### 4.6 Mount `/var/lib/etcd` (khusus control plane)

```bash
# cek vDisk kedua
lsblk

# asumsi disk kosong: /dev/sdb
sudo mkfs.ext4 -L etcd /dev/sdb
sudo mkdir -p /var/lib/etcd

echo 'LABEL=etcd /var/lib/etcd ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a
```

**Verifikasi:**

```bash
df -h /var/lib/etcd     # harus menunjuk vDisk 40G, bukan disk OS
```

> ⚠️ Gunakan `LABEL=`, bukan `/dev/sdb` — urutan device di Nutanix bisa berubah setelah reboot.
> Ini menyelamatkan etcd dari mount ke disk yang salah.

### 4.7 Ulimit

```bash
cat <<'EOF' | sudo tee /etc/security/limits.d/99-k8s.conf
*   soft nofile 1048576
*   hard nofile 1048576
*   soft nproc  65535
*   hard nproc  65535
EOF

cat <<'EOF' | sudo tee /etc/systemd/system.conf.d/99-k8s.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

sudo systemctl daemon-reexec
```

### 4.8 Verifikasi blok 4

```bash
echo "--- swap ---";  swapon --show
echo "--- time ---";  chronyc tracking | grep -E 'Leap|System time'
echo "--- sysctl ---"; sysctl net.ipv4.ip_forward
echo "--- etcd disk ---"; df -h /var/lib/etcd 2>/dev/null || echo "(worker: n/a)"
echo "--- ulimit ---"; ulimit -n
```

---

## 5. Container runtime: containerd

### 5.1 Install dari repo Docker (menyediakan containerd 2.x)

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y containerd.io
```

### 5.2 Generate config default

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
```

### 5.3 Wajib: `SystemdCgroup = true`

```bash
# Cari dulu, jangan asal sed
grep -n 'SystemdCgroup' /etc/containerd/config.toml
```

Kalau hasilnya `SystemdCgroup = false`:

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml   # harus true
```

> ⚠️ `SystemdCgroup=false` adalah sumber masalah klasik: pod jalan tapi
> resource limit tidak dipatuhi dan node jadi tidak stabil saat beban tinggi.

### 5.4 Samakan sandbox image dengan versi Kubernetes

```bash
# Ambil nilai yang diharapkan kubeadm
kubeadm config images list 2>/dev/null | grep pause || true

# Set sandbox_image ke versi pause yang sesuai (contoh: 3.10)
grep -n 'sandbox_image' /etc/containerd/config.toml
```

Jika berbeda dari output `kubeadm config images list`, samakan nilainya di `config.toml`,
lalu:

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Verifikasi:**

```bash
sudo systemctl is-active containerd
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock version
```

### 5.5 (Opsional, setelah Nexus siap) registry mirror

Agar semua image lewat Nexus (cache + audit + kurangi egress):

```bash
sudo mkdir -p /etc/containerd/certs.d/{docker.io,registry.k8s.io}

sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml >/dev/null <<EOF
server = "https://registry.k8s.io"
[host."https://nexus.gatezero.lab:8084"]
  capabilities = ["pull", "resolve"]
EOF

sudo tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<EOF
server = "https://registry-1.docker.io"
[host."https://nexus.gatezero.lab:8083"]
  capabilities = ["pull", "resolve"]
EOF
```

Pastikan containerd membaca direktori tersebut:

```bash
grep -n 'config_path' /etc/containerd/config.toml
# idealnya: config_path = "/etc/containerd/certs.d"
```

Kalau baris itu tidak ada, tambahkan di section registry CRI lalu restart containerd.

> Lakukan ini **sebelum** `kubeadm init` supaya image system ikut lewat Nexus.

---

## 6. Tool Kubernetes + versi di-pin

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

> Sesuaikan `v1.34` dengan versi pilihanmu. **Pin ke minor tertentu** — jangan
> ikut `stable` apa adanya, karena `apt upgrade` bisa melompatkan versi di tengah jalan.

**Verifikasi (harus sama di semua node):**

```bash
kubeadm version -o short
kubectl version --client
kubelet --version
dpkg -l kubelet kubeadm kubectl | grep ^hi
```

### Kebijakan version skew

| Komponen | Boleh lebih rendah dari apiserver |
|---|---|
| kubelet | 3 minor |
| kube-proxy | 3 minor (tidak dipakai, Cilium) |
| kubectl | 1 minor |

Upgrade **satu minor sekaligus**, tidak boleh melompat.

### Nonaktifkan auto-upgrade paket k8s

```bash
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet   # jangan start dulu, akan crashloop sampai init
```

---

## 7. VIP API server: kube-vip

Tujuan: `https://10.10.20.10:6443` selalu hidup selama ≥1 control plane hidup.

### 7.1 Generate manifest (cara resmi, versi-akurat)

Jalankan **di setiap** control plane:

```bash
export VIP=10.10.20.10
export IFACE=ens192
export KVVERSION=v0.8.7   # cek rilis terbaru

sudo mkdir -p /etc/kubernetes/manifests

# Cara paling aman: pakai image kube-vip untuk generate manifest
sudo ctr -n k8s.io images pull ghcr.io/kube-vip/kube-vip:${KVVERSION}
sudo ctr -n k8s.io run --rm --net-host ghcr.io/kube-vip/kube-vip:${KVVERSION} vip \
  /kube-vip manifest pod \
  --interface ${IFACE} \
  --address ${VIP} \
  --controlplane \
  --services \
  --arp \
  --leaderElection \
  | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

> Kalau menarik image dari internet tidak diizinkan, ambil manifest dari repo kube-vip
> pada tag yang sama, atau tulis manual dengan `vip_arp: "true"` dan `vip_interface`.

### 7.2 Verifikasi VIP aktif

Setelah kubelet membaca `/etc/kubernetes/manifests`, pod statis kube-vip akan jalan
(meski apiserver belum ada).

```bash
sudo crictl ps | grep kube-vip
# ada container kube-vip dalam state Running

# dari node lain:
ping -c 2 10.10.20.10
ip -br a | grep ${IFACE}     # VIP muncul sebagai /32 di node pemegang
```

> `curl -k https://10.10.20.10:6443/healthz` akan **gagal** sampai apiserver hidup.
> Yang penting di tahap ini: VIP bisa di-ping dan muncul di salah satu CP.

### 7.3 Alternatif kalau ARP tidak diizinkan VLAN

| Opsi | Catatan |
|---|---|
| HAProxy + keepalived di 2 VM kecil | klasik, mudah diaudit, +2 VM |
| BGP dengan Cilium | perlu konfigurasi router; bagus untuk skala besar |
| Cloud/Nutanix LB | tidak tersedia untuk API server internal |

Catat pilihanmu di ADR bila berbeda dari kube-vip.

---

## 8. Konfigurasi kubeadm

File ini **hanya** dipakai untuk init CP pertama. Node lain join lewat
ConfigMap `kubeadm-config` yang dibuat otomatis.

Simpan versi repo di `platform/bootstrap/kubeadm/kubeadm-config.yaml` (placeholder),
lalu **salin ke `/root/kubeadm-config.yaml` di CP-01** sebelum init:

```bash
scp kubeadm-config.yaml root@10.10.20.11:/root/kubeadm-config.yaml
# di CP-01: sesuaikan advertiseAddress (10.10.20.11) dan nodeRegistration.name (k8s-cp-01)
```

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.10.20.11      # IP CP-01 — WAJIB beda per node
  bindPort: 6443
nodeRegistration:
  name: k8s-cp-01
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  kubeletExtraArgs:
    - name: protect-kernel-defaults
      value: "true"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: gatezero
kubernetesVersion: v1.34.0
controlPlaneEndpoint: "10.10.20.10:6443"
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.k8s.io
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - 10.10.20.10
    - 10.10.20.11
    - 10.10.20.12
    - 10.10.20.13
    - k8s-api.gatezero.lab
  extraArgs:
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: encryption-provider-config
      value: /etc/kubernetes/enc/encryption-config.yaml
    - name: request-timeout
      value: 60s
    - name: enable-admission-plugins
      value: NodeRestriction,PodSecurity
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      pathType: DirectoryOrCreate
    - name: enc-config
      hostPath: /etc/kubernetes/enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: use-service-account-credentials
      value: "true"
    - name: bind-address
      value: 0.0.0.0
scheduler:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: listen-metrics-urls
        value: http://0.0.0.0:2381
      - name: quota-backend-bytes
        value: "8589934592"
      - name: heartbeat-interval
        value: "100"
      - name: election-timeout
        value: "1000"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
protectKernelDefaults: true
rotateCertificates: true
serverTLSBootstrap: true
readOnlyPort: 0
clusterDomain: cluster.local
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
systemReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 1Gi
kubeReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 2Gi
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
```

### 8.1 Penjelasan keputusan penting

| Setting | Alasan |
|---|---|
| `controlPlaneEndpoint` = VIP | semua komponen bicara ke satu alamat; CP bisa mati satu-satu |
| `certSANs` lengkap | sertifikat valid untuk IP & DNS, menghindari `x509: certificate is valid for...` |
| `audit-*` | tanpa audit log, investigasi insiden tidak mungkin |
| `encryption-provider-config` | Secret tidak tersimpan plaintext di etcd |
| `enable-admission-plugins: NodeRestriction,PodSecurity` | batasi kubelet + baseline PSA |
| `use-service-account-credentials` | controller manager punya identitas sendiri, bukan `system:kube-controller-manager` untuk semua |
| `protectKernelDefaults` | kubelet menolak jalan kalau sysctl tidak sesuai (fail fast) |
| `readOnlyPort: 0` | menutup kubelet port 10255 tanpa auth (temuan kube-bench klasik) |
| `systemReserved`/`kubeReserved` | mencegah pod menghabiskan memori sampai kubelet OOM |
| `heartbeat-interval`/`election-timeout` | toleransi latency Nutanix tanpa flapping |
| `quota-backend-bytes: 8Gi` | default 2Gi terlalu kecil; 8Gi mencegah `etcdserver: mvcc: database space exceeded` |

### 8.2 Siapkan direktori audit & encryption (CP-01)

```bash
sudo mkdir -p /etc/kubernetes/audit /etc/kubernetes/enc /var/log/kubernetes
```

**Audit policy** — `/etc/kubernetes/audit/policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # jangan catat trafik read-only yang berisik
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - { group: "", resources: ["endpoints", "services"] }
  - level: None
    userGroups: ["system:authenticated"]
    nonResourceURLs: ["/api*", "/version", "/healthz*", "/livez*", "/readyz*", "/openapi*"]
  # perubahan Secret/ConfigMap: catat isi request (tanpa body respons)
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - { group: "", resources: ["secrets", "configmaps"] }
  # perubahan RBAC: catat lengkap
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - { group: "rbac.authorization.k8s.io", resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"] }
  - level: Metadata
```

**Encryption at rest** — generate key 32 byte, lalu simpan di SOPS:

```bash
KEY=$(head -c 32 /dev/urandom | base64)

sudo mkdir -p /etc/kubernetes/enc
sudo tee /etc/kubernetes/enc/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets", "configmaps"]
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}
EOF
sudo chmod 600 /etc/kubernetes/enc/encryption-config.yaml

# Simpan salinan terenkripsi untuk recovery (JANGAN plaintext di repo).
# Dilakukan di jumpbox: salin dulu lewat jalur aman, lalu enkripsi dengan SOPS.
#   scp root@10.10.20.11:/etc/kubernetes/enc/encryption-config.yaml /tmp/
#   sops -e /tmp/encryption-config.yaml \
#     > platform/bootstrap/kubeadm/encryption-config.enc.yaml
#   rm -f /tmp/encryption-config.yaml
```

> ⚠️ **Kehilangan key ini = semua Secret tidak bisa dibaca.** Simpan salinan offline
> bersama backup PKI. `aescbc` dipilih karena didukung semua versi; `kms` v2 lebih baik
> tapi butuh KMS plugin (OpenBao) yang belum ada di tahap bootstrap.

**Verifikasi:**

```bash
sudo ls -l /etc/kubernetes/audit/policy.yaml /etc/kubernetes/enc/encryption-config.yaml
```

### 8.3 Preflight

```bash
sudo kubeadm init --config /root/kubeadm-config.yaml --dry-run
```

Perbaiki semua error **sebelum** init sungguhan. Yang umum: port terpakai, swap aktif,
containerd tidak jalan, `br_netfilter` belum load.

---

## 9. Init control plane pertama

### 9.1 Siapkan certificate key di SOPS

```bash
# di jumpbox
CERT_KEY=$(kubeadm certs certificate-key)

cat > /tmp/cert-key.yaml <<EOF
cert_key: ${CERT_KEY}
EOF
sops -e /tmp/cert-key.yaml > platform/bootstrap/kubeadm/cert-key.enc.yaml
rm -f /tmp/cert-key.yaml
```

### 9.2 Init

```bash
CERT_KEY=$(sops -d platform/bootstrap/kubeadm/cert-key.enc.yaml | awk '/cert_key:/ {print $2}')

sudo kubeadm init \
  --config /root/kubeadm-config.yaml \
  --upload-certs \
  --certificate-key "${CERT_KEY}" \
  --skip-phases=addon/kube-proxy
```

> `--skip-phases=addon/kube-proxy` karena Cilium menggantikan kube-proxy (ADR-0008).

### 9.3 Kubeconfig untuk operator

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

> Untuk akses jarak jauh, salin `admin.conf` lewat jalur aman (bukan `scp` ke laptop
> tanpa enkripsi). Di jumpbox, file ini juga dienkripsi SOPS.

### 9.4 Verifikasi

```bash
kubectl get nodes -o wide
# k8s-cp-01   NotReady   control-plane    <- normal, CNI belum ada

kubectl -n kube-system get pods
# apiserver, controller-manager, scheduler, etcd Running
# coredns Pending (menunggu CNI)

kubectl -n kube-system get pods -l app=kube-vip
```

**Cek etcd sehat sebelum lanjut:**

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
```

**Cek sertifikat:**

```bash
sudo kubeadm certs check-expiration
# semua > 1 tahun
```

> 🚨 **Jangan lanjut** kalau apiserver tidak `Running` atau etcd error. Join CP berikutnya
> akan memperburuk keadaan (etcd member setengah jadi).

---

## 10. Join control plane kedua & ketiga

Jalankan **berurutan**, satu node selesai dulu sebelum yang lain.

### 10.1 Ambil join command

Dari CP-01:

```bash
CERT_KEY=$(sops -d platform/bootstrap/kubeadm/cert-key.enc.yaml | awk '/cert_key:/ {print $2}')
kubeadm token create --print-join-command
```

### 10.2 Join CP-02

```bash
sudo kubeadm join 10.10.20.10:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key "${CERT_KEY}" \
  --apiserver-advertise-address 10.10.20.12 \
  --node-name k8s-cp-02
```

### 10.3 Verifikasi CP-02

```bash
kubectl get nodes
# k8s-cp-02   NotReady   control-plane

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
# harus 2 member, keduanya started
```

### 10.4 Join CP-03

Ulangi dengan `--apiserver-advertise-address 10.10.20.13 --node-name k8s-cp-03`.

### 10.5 Verifikasi quorum

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379,https://10.10.20.12:2379,https://10.10.20.13:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health -w table
# 3/3 healthy
```

> Angka **3** adalah minimum untuk toleransi 1 node mati. 2 CP lebih buruk daripada 1
> (quorum hilang saat salah satu mati) — jangan berhenti di 2.

### 10.6 Hapus Secret berisi certificate key

```bash
kubectl -n kube-system delete secret kubeadm-certs
kubectl -n kube-system get secret | grep kubeadm
# hanya kubeadm-config & kubeadm-token tersisa
```

---

## 11. Join worker node

```bash
sudo kubeadm join 10.10.20.10:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --node-name k8s-w-01
```

Ulangi untuk `k8s-w-02`, `k8s-w-03` (sesuaikan `--node-name`).

**Verifikasi:**

```bash
kubectl get nodes -o wide
# semua node muncul, status NotReady sampai Cilium terpasang
```

---

## 12. CNI: Cilium

### 12.1 Install Helm & repo

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm search repo cilium/cilium --versions | head -5
```

### 12.2 Values

Simpan sebagai `platform/bootstrap/cilium/values.yaml`:

```yaml
cluster:
  name: gatezero
  id: 1

kubeProxyReplacement: true
k8sServiceHost: 10.10.20.10
k8sServicePort: 6443

routingMode: tunnel
tunnelProtocol: vxlan
# MTU: 1500 - 50 (VXLAN) = 1450. Kalau jumbo frame 9000 -> 8950
MTU: 1450

ipam:
  mode: kubernetes

operator:
  replicas: 2
  tolerations: []

l2announcements:
  enabled: true

gatewayAPI:
  enabled: true

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

prometheus:
  enabled: true
  serviceMonitor:
    enabled: false   # aktifkan setelah kube-prometheus-stack terpasang

bpf:
  masquerade: true

encryption:
  enabled: false      # mTLS WireGuard: ubah ke true setelah stabil (lihat catatan)
```

### 12.3 Install

```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values platform/bootstrap/cilium/values.yaml \
  --wait --timeout 10m
```

### 12.4 Verifikasi (semua harus hijau)

```bash
cilium status --wait

kubectl -n kube-system get pods -l k8s-app=cilium
# satu pod per node, semua Running

kubectl get nodes
# semua Ready

kubectl -n kube-system get ds kube-proxy
# NotFound  <- benar, kube-proxy tidak ada

cilium connectivity test
# opsional tapi sangat disarankan: menguji NetworkPolicy, DNS, LB, Gateway
```

### 12.5 Pastikan tidak ada kube-proxy tertinggal

```bash
kubectl -n kube-system get ds
# tidak boleh ada kube-proxy

# kalau ada sisa:
kubectl -n kube-system delete ds kube-proxy --ignore-not-found
kubectl -n kube-system delete cm kube-proxy --ignore-not-found
```

### 12.6 Catatan MTU

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep MTU
```

Kalau Nutanix memakai jumbo frame, ukur dulu:

```bash
ping -M do -s 8972 -c 2 <node-lain>
# sukses -> MTU 9000 di path
```

Lalu set `MTU: 8950`. **MTU salah** menghasilkan gejala paling menyesatkan:
`ping` normal, tapi TLS handshake menggantung dan `kubectl exec` timeout.

### 12.7 Opsi enkripsi WireGuard

```yaml
encryption:
  enabled: true
  type: wireguard
```

Bagus untuk demo keamanan, tapi **ukur dulu** dampak throughput-nya
(`infra/benchmark`). Aktifkan setelah cluster stabil, bukan saat instalasi awal.

---

## 13. Gateway API + cert-manager

### 13.1 Gateway API CRD

```bash
GATEWAY_API_VER=v1.2.1   # cek rilis terbaru
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VER}/standard-install.yaml
```

### 13.2 cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set prometheus.enabled=true \
  --wait
```

### 13.3 Cloudflare API token dari SOPS

```bash
# token hanya ada saat apply, tidak pernah tersimpan plaintext di disk
sops exec-file platform/bootstrap/cert-manager/cloudflare-token.enc.yaml \
  'kubectl create secret generic cloudflare-api-token \
     --namespace cert-manager \
     --from-file=api-token={} \
     --dry-run=client -o yaml | kubectl apply -f -'
```

### 13.4 ClusterIssuer + wildcard Certificate

`platform/bootstrap/cert-manager/clusterissuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@gatezero.lab
    privateKeySecretRef:
      name: letsencrypt-dns-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - gatezero.lab
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-gatezero
  namespace: cert-manager
spec:
  secretName: wildcard-gatezero-tls
  issuerRef:
    name: letsencrypt-dns
    kind: ClusterIssuer
  dnsNames:
    - "*.apps.gatezero.lab"
```

```bash
kubectl apply -f platform/bootstrap/cert-manager/clusterissuer.yaml
kubectl -n cert-manager get certificate,certificaterequest,order,challenge
# Certificate READY=True dalam 1-3 menit
```

> DNS-01 dipilih karena cluster berada di jaringan privat. HTTP-01 menuntut
> port 80 terbuka dari internet — tidak perlu di sini.

---

## 14. Storage & metrics-server

### 14.1 Nutanix CSI (PVC untuk Prometheus/Postgres)

Ikuti panduan Nutanix CSI resmi untuk AHV. Yang perlu disiapkan:

| Kebutuhan | Catatan |
|---|---|
| Prism Element endpoint + credential | simpan di Secret **dari SOPS**, jangan ConfigMap |
| StorageClass | `nutanix-volume`, `allowVolumeExpansion: true` |
| Default StorageClass | tandai satu sebagai default |
| SnapshotClass | untuk Velero |

```bash
kubectl -n kube-system get pods -l app=nutanix-csi
kubectl get sc
kubectl get sc nutanix-volume -o jsonpath='{.metadata.annotations}'
```

**Uji PVC:**

```bash
kubectl create -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc smoke-pvc -w
# harus Bound < 60s
kubectl delete pvc smoke-pvc
```

### 14.2 metrics-server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args={--kubelet-preferred-address-types=InternalIP}
```

**Karena `serverTLSBootstrap: true`, sertifikat kubelet perlu di-approve:**

```bash
kubectl get csr
kubectl certificate approve <csr-name>   # untuk setiap node
# atau sekaligus (setelah yakin semua sah):
kubectl get csr -o name | xargs kubectl certificate approve
```

**Verifikasi:**

```bash
kubectl top nodes
# harus menampilkan CPU/MEM, bukan error "metrics not available"
```

> Kalau tetap gagal, cek `kubectl -n kube-system logs deploy/metrics-server`.
> Jangan langsung menambahkan `--kubelet-insecure-tls` — itu mematikan verifikasi TLS
> dan akan ditandai kube-bench.

---

## 15. Hardening pasca-install

### 15.1 Pod Security Admission

```bash
for ns in apps-dev apps-staging apps-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$ns" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite
done

kubectl label namespace gitlab-runner \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

### 15.2 Verifikasi encryption at rest

```bash
# tulis secret uji
kubectl -n default create secret generic enc-test --from-literal=token=supersecret

# harus muncul prefix "k8s:enc:aescbc:v1:key1"
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-test | head -c 200

kubectl -n default delete secret enc-test
```

**Kalau secret lama masih plaintext**, tulis ulang seluruh Secret:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

### 15.3 Kubelet certificate rotation

```bash
kubectl get csr
# setelah 24 jam akan ada CSR baru otomatis -> approve atau aktifkan auto-approve
```

Auto-approve (dokumentasikan sebagai keputusan keamanan):

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-csr-autoapprove
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:nodes
EOF
```

### 15.4 RBAC manusia: SSO, bukan cluster-admin

Jangan bagikan `admin.conf` ke tim. Pasang Dex/OIDC yang menunjuk GitLab, lalu:

```yaml
# contoh RoleBinding untuk developer (bukan ClusterRoleBinding)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-edit
  namespace: apps-dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: gatezero-developers
```

Tambahkan ke apiserver (`extraArgs`) setelah issuer OIDC stabil:

```yaml
- name: oidc-issuer-url
  value: https://gitlab.gatezero.lab
- name: oidc-client-id
  value: gatezero-k8s
- name: oidc-username-claim
  value: email
- name: oidc-groups-claim
  value: groups
```

### 15.5 Audit log ke Loki

```bash
# setelah Loki terpasang, Alloy membaca:
#   /var/log/kubernetes/audit.log
# pastikan rotasi (maxsize/maxbackup di ConfigMap apiserver) tidak menghapus
# log sebelum terkirim
```

### 15.6 Kubernetes benchmark

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: kube-system
spec:
  template:
    spec:
      hostPID: true
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--targets", "master,node", "--json"]
          volumeMounts:
            - { name: var-lib-etcd, mountPath: /var/lib/etcd, readOnly: true }
            - { name: etc-kubernetes, mountPath: /etc/kubernetes, readOnly: true }
            - { name: etc-systemd, mountPath: /etc/systemd, readOnly: true }
      restartPolicy: Never
      volumes:
        - { name: var-lib-etcd, hostPath: { path: /var/lib/etcd } }
        - { name: etc-kubernetes, hostPath: { path: /etc/kubernetes } }
        - { name: etc-systemd, hostPath: { path: /etc/systemd } }
EOF

kubectl -n kube-system logs job/kube-bench | tee kube-bench-$(date +%F).log
```

Target (ADR-0010): control plane ≥ 90%, worker ≥ 85%. Setiap FAIL → remediasi di
`platform/bootstrap/` atau masuk daftar pengecualian **dengan alasan**.

---

## 16. Backup etcd & PKI

### 16.1 Snapshot otomatis (systemd timer)

`/usr/local/bin/etcd-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR=/var/backups/etcd
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$BACKUP_DIR"

ETCDCTL_API=3 etcdctl snapshot save "$BACKUP_DIR/etcd-${STAMP}.db" \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

etcdutl snapshot status "$BACKUP_DIR/etcd-${STAMP}.db" -w table

# simpan lokal 7 hari
find "$BACKUP_DIR" -name 'etcd-*.db' -mtime +7 -delete

# kirim ke S3 (kredensial dari file 0600, bukan env global)
aws s3 cp "$BACKUP_DIR/etcd-${STAMP}.db" \
  "s3://gatezero-backup/etcd/${HOSTNAME}/etcd-${STAMP}.db" \
  --endpoint-url "$S3_ENDPOINT"
```

```bash
sudo chmod 700 /usr/local/bin/etcd-backup.sh

sudo tee /etc/systemd/system/etcd-backup.service >/dev/null <<'EOF'
[Unit]
Description=etcd snapshot backup
[Service]
Type=oneshot
EnvironmentFile=/etc/etcd-backup.env
ExecStart=/usr/local/bin/etcd-backup.sh
EOF

sudo tee /etc/systemd/system/etcd-backup.timer >/dev/null <<'EOF'
[Unit]
Description=etcd snapshot backup every 6h
[Timer]
OnCalendar=*-*-* 00/6:17:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now etcd-backup.timer
systemctl list-timers etcd-backup.timer
```

> ⚠️ **Jangan andalkan snapshot VM Nutanix untuk etcd.** Snapshot AHV tidak
> crash-consistent dengan WAL etcd (ADR-0009). Snapshot VM tetap dipakai untuk
> GitLab/Nexus dengan pre-freeze.

### 16.2 Backup PKI (sekali, lalu setiap CA renew)

```bash
sudo tar czf /root/k8s-pki-$(date +%F).tar.gz -C /etc/kubernetes pki
sudo chmod 600 /root/k8s-pki-*.tar.gz

# enkripsi dengan age root key, simpan offline + satu salinan di password manager
age -r age1ROOT_PUBLIC_KEY -o k8s-pki-$(date +%F).tar.gz.age /root/k8s-pki-$(date +%F).tar.gz
```

### 16.3 Uji restore (wajib, minimal sekali)

```bash
sudo etcdutl snapshot restore /var/backups/etcd/etcd-<stamp>.db \
  --data-dir /var/lib/etcd-restore

# di cluster uji: arahkan etcd dataDir ke /var/lib/etcd-restore
# catat waktu restore -> itulah RTO-mu yang sebenarnya
```

Tulis hasilnya di `docs/runbooks/etcd-restore.md`.

---

## 17. Verifikasi akhir

Jalankan **semua** perintah ini; semuanya harus lulus sebelum menyerahkan cluster ke ArgoCD.

```bash
# 1. node & versi
kubectl get nodes -o wide
kubectl version

# 2. komponen sistem
kubectl -n kube-system get pods -o wide
# semua Running, tidak ada CrashLoopBackOff / Pending

# 3. tidak ada kube-proxy
kubectl -n kube-system get ds | grep -c kube-proxy || echo "OK: tidak ada kube-proxy"

# 4. etcd quorum
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.10.20.11:2379,https://10.10.20.12:2379,https://10.10.20.13:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health -w table

# 5. sertifikat
sudo kubeadm certs check-expiration

# 6. Cilium
cilium status
cilium connectivity test

# 7. DNS
kubectl run dnstest --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

# 8. metrics
kubectl top nodes

# 9. storage
kubectl get sc

# 10. encryption at rest (ulangi tes secret di 15.2)

# 11. API server lewat VIP (bukan IP node)
curl -k https://10.10.20.10:6443/healthz     # -> ok

# 12. audit log ada isinya
sudo tail -5 /var/log/kubernetes/audit.log

# 13. kube-bench sudah dijalankan, skor dicatat
```

### Uji HA: matikan satu control plane

Ini yang membedakan "cluster HA" dari "cluster yang katanya HA".

```bash
# di CP-03
sudo systemctl stop kubelet
sudo systemctl stop containerd
# atau: sudo shutdown -h now

# dari jumpbox, teruskan kerja:
kubectl get nodes           # CP-03 NotReady, sisanya Ready
kubectl create ns ha-test   # harus berhasil
kubectl -n kube-system get pods   # apiserver tetap melayani

# hidupkan kembali
sudo systemctl start containerd kubelet
# tunggu, lalu: kubectl get nodes -> CP-03 Ready
```

> Lakukan ini di luar jam kerja, dan **hanya satu node sekaligus**.
> Catat hasilnya di README sebagai bukti HA benar-benar diuji.

---

## 18. Upgrade & maintenance

### 18.1 Upgrade minor (contoh 1.34.0 → 1.34.5)

Satu node per waktu. **Control plane dulu, worker belakangan.**

```bash
# 1. CP-01
sudo apt-mark unhold kubeadm
sudo apt-get update && sudo apt-get install -y kubeadm=1.34.5-1.1
sudo apt-mark hold kubeadm

sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.34.5

# 2. drain sebelum upgrade kubelet
kubectl drain k8s-cp-01 --ignore-daemonsets --delete-emptydir-data

sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.5-1.1 kubectl=1.34.5-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet

kubectl uncordon k8s-cp-01
kubectl get nodes
```

### 18.2 Upgrade CP-02 & CP-03

```bash
sudo kubeadm upgrade node     # bukan "apply"
# lanjut drain -> upgrade kubelet -> uncordon
```

### 18.3 Upgrade worker

```bash
kubectl drain k8s-w-01 --ignore-daemonsets --delete-emptydir-data
# di node:
sudo kubeadm upgrade node
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.5-1.1 kubectl=1.34.5-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon k8s-w-01
```

### 18.4 Upgrade minor berikutnya (1.34 → 1.35)

Ubah repo apt ke `v1.35`, lalu ulangi pola di atas. **Tidak boleh melompat minor.**

### 18.5 Renew sertifikat

```bash
sudo kubeadm certs renew all
sudo systemctl restart kubelet
# apiserver/controller/scheduler adalah static pod -> restart otomatis
sudo kubeadm certs check-expiration
```

### 18.6 Perawatan rutin

| Interval | Tugas |
|---|---|
| Harian | cek alert etcd quota, node disk, pod restart |
| Mingguan | `kube-bench` + Kubescape, review audit log anomali |
| Bulanan | patch OS (rolling), cek `kubeadm certs check-expiration` |
| Kuartalan | uji restore etcd, uji HA (matikan 1 CP), review exception list CIS |
| Tahunan | upgrade minor (maks 3 versi tertinggal) |

---

## 19. Reset / teardown

### Satu node (worker)

```bash
kubectl drain k8s-w-03 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k8s-w-03

# di node:
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet /var/lib/etcd
sudo systemctl restart containerd
```

### Control plane (hati-hati)

```bash
# 1. hapus member etcd dulu, dari CP lain
sudo ETCDCTL_API=3 etcdctl member remove <member-id>

# 2. baru reset node
sudo kubeadm reset -f
```

### Cluster penuh

```bash
# semua node
sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet /var/lib/etcd
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo ipvsadm --clear 2>/dev/null || true

# hapus interface Cilium kalau ada
sudo ip link delete cilium_host 2>/dev/null || true
sudo ip link delete cilium_net 2>/dev/null || true
```

---

## 20. Troubleshooting

| Gejala | Penyebab paling sering | Perbaikan |
|---|---|---|
| `kubeadm init` gagal di preflight "swap" | swap masih aktif | `swapoff -a`, cek `/etc/fstab` |
| `[ERROR CRI]: container runtime is not running` | containerd mati / socket salah | `systemctl status containerd`, cek `criSocket` |
| `x509: certificate is valid for ...` | `certSANs` kurang | tambah IP/DNS, `kubeadm init phase certs apiserver` |
| node `NotReady` setelah join | CNI belum terpasang | pasang Cilium; cek `kubectl -n kube-system get pods` |
| pod stuck `ContainerCreating` | inotify habis / CNI belum siap / PVC belum Bound | naikkan `fs.inotify.*`, cek `describe pod` events |
| `kubectl exec` timeout, ping normal | **MTU mismatch** | set MTU Cilium = path MTU − 50 |
| `metrics not available` | CSR kubelet belum di-approve | `kubectl get csr` lalu approve |
| etcd `request timed out` / leader flapping | disk lambat / fsync tinggi | cek `etcd_disk_wal_fsync_duration_seconds`, pindahkan etcd ke vDisk SSD |
| apiserver tidak bisa diakses via VIP | kube-vip tidak jalan | `crictl ps \| grep kube-vip`, cek `--interface` |
| `etcdserver: mvcc: database space exceeded` | kuota 2Gi default | naikkan `quota-backend-bytes`, lalu `etcdctl defrag` |
| node jadi `NotReady` setelah hardening | sysctl/module diblokir | cek `journalctl -u kubelet`, review exception list CIS |
| secret tidak terbaca setelah restart | encryption key hilang | restore `encryption-config.yaml` dari SOPS |

### Perintah diagnosa cepat

```bash
# kubelet
sudo journalctl -u kubelet -n 100 --no-pager
sudo systemctl status kubelet

# container runtime
sudo crictl ps -a
sudo crictl logs <container-id>
sudo journalctl -u containerd -n 50 --no-pager

# control plane
kubectl -n kube-system logs -l component=kube-apiserver --tail=50
kubectl -n kube-system logs -l component=kube-controller-manager --tail=50
kubectl -n kube-system logs -l component=kube-scheduler --tail=50

# etcd
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table

# jaringan
cilium status --verbose
cilium-dbg monitor --type drop
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50

# CSR
kubectl get csr
kubectl describe csr <name>
```

---

## 21. Checklist produksi

### Sebelum init
- [ ] 3 CP + 3 worker, semua `machine-id` unik
- [ ] vDisk etcd terpisah & ter-mount via `LABEL=`
- [ ] chrony sinkron (offset < 100ms)
- [ ] swap off permanen
- [ ] `SystemdCgroup = true` terverifikasi
- [ ] versi kubelet/kubeadm/kubectl identik & di-hold
- [ ] VIP bisa di-ping dari semua node
- [ ] DNS `k8s-api` → VIP
- [ ] audit policy + encryption key siap, key tersimpan di SOPS + offline

### Setelah init
- [ ] 3/3 etcd healthy, quorum teruji
- [ ] semua node `Ready`
- [ ] tidak ada kube-proxy
- [ ] `cilium connectivity test` lulus
- [ ] `kubeadm certs check-expiration` > 1 tahun
- [ ] `kubeadm-certs` Secret dihapus
- [ ] encryption at rest terbukti (`k8s:enc:aescbc:v1`)
- [ ] audit log terisi
- [ ] PSA `restricted` di namespace app
- [ ] `kubectl top nodes` bekerja
- [ ] StorageClass default + PVC smoke test `Bound`
- [ ] etcd backup timer aktif dan **restore sudah diuji**
- [ ] backup PKI terenkripsi & disimpan offline
- [ ] kube-bench dijalankan, skor dicatat, FAIL sudah ditriase
- [ ] uji HA: 1 CP dimatikan, cluster tetap melayani
- [ ] `admin.conf` tidak dibagikan; akses manusia via OIDC + RoleBinding

### Serah terima
- [ ] ArgoCD terpasang & root Application sync (lihat `platform/gitops/`)
- [ ] metrik cluster masuk Prometheus
- [ ] alert etcd/disk/node aktif
- [ ] runbook `docs/runbooks/` terisi untuk kasus di tabel troubleshooting

---

## Lampiran A — Ringkasan perintah (cheat sheet)

```bash
# --- semua node ---
swapoff -a; sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
modprobe overlay br_netfilter
sysctl --system
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd
apt-mark hold kubelet kubeadm kubectl

# --- cp-01 ---
kubeadm init --config /root/kubeadm-config.yaml --upload-certs \
  --certificate-key "$CERT_KEY" --skip-phases=addon/kube-proxy
mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config

# --- cp-02, cp-03 ---
kubeadm join 10.10.20.10:6443 --token "$TOK" \
  --discovery-token-ca-cert-hash "sha256:$HASH" \
  --control-plane --certificate-key "$CERT_KEY" \
  --apiserver-advertise-address <IP-CP> --node-name <NAMA-CP>

# --- worker ---
kubeadm join 10.10.20.10:6443 --token "$TOK" \
  --discovery-token-ca-cert-hash "sha256:$HASH" --node-name <NAMA-W>

# --- cni ---
helm upgrade --install cilium cilium/cilium -n kube-system \
  -f platform/bootstrap/cilium/values.yaml --wait

# --- bersih-bersih ---
kubectl -n kube-system delete secret kubeadm-certs
```

## Lampiran B — Referensi

| Topik | Dokumen |
|---|---|
| Kenapa kubeadm | `docs/adr/0001-kubeadm-over-k3s.md` |
| Cilium vs alternatif | `docs/adr/0008-cilium-cni-kube-proxy-replacement.md` |
| etcd disk & backup | `docs/adr/0009-etcd-dedicated-disk-and-backup.md` |
| Pengecualian CIS | `docs/adr/0010-cis-hardening-exceptions.md` |
| Benchmark VM | `infra/benchmark/README.md` |
| Restore etcd | `docs/runbooks/etcd-restore.md` |
