# Runbook — Menjalankan Ansible Bootstrap

Dokumen ini adalah **panduan eksekusi**: dari controller kosong sampai cluster terverifikasi,
lalu cara mengemas dan mempublikasikannya ke Ansible Galaxy.

| Dokumen | Isi |
|---|---|
| [`../kubeadm/INSTALL.md`](../kubeadm/INSTALL.md) | penjelasan manual: **kenapa** setiap langkah |
| [`README.md`](README.md) | ringkasan peran tiap role |
| **RUNBOOK.md** (ini) | urutan perintah: **apa** yang dijalankan, **output apa** yang diharapkan |

---

## Daftar Isi

- [0. Peta eksekusi](#0-peta-eksekusi)
- [1. Prasyarat controller](#1-prasyarat-controller)
- [2. Konfigurasi inventory](#2-konfigurasi-inventory)
- [3. Secret dengan SOPS](#3-secret-dengan-sops)
- [4. Uji konektivitas](#4-uji-konektivitas)
- [5. Eksekusi bertahap](#5-eksekusi-bertahap)
- [6. Eksekusi penuh & uji idempotensi](#6-eksekusi-penuh--uji-idempotensi)
- [7. Handoff setelah cluster jadi](#7-handoff-setelah-cluster-jadi)
- [8. Day-2](#8-day-2)
- [9. Troubleshooting](#9-troubleshooting)
- [10. Teardown](#10-teardown)
- [11. Publikasi ke Ansible Galaxy](#11-publikasi-ke-ansible-galaxy)
- [12. Integrasi CI](#12-integrasi-ci)
- [Lampiran A — perintah ad-hoc](#lampiran-a--perintah-ad-hoc)

---

## 0. Peta eksekusi

```
[controller]                [6 node]                       [hasil]
    │                          │                              │
    ├─ 00-preflight ───────────┼─ validasi secret ────────────┤
    ├─ 10-baseline ───────────►│ chrony, swap, sysctl, ulimit │
    ├─ 20-etcd-disk ──────────►│ format+mount vDisk (CP)      │
    ├─ 30-containerd ─────────►│ runtime + SystemdCgroup      │
    ├─ 40-kubernetes ─────────►│ kubelet/kubeadm/kubectl      │
    ├─ 50-kube-vip ───────────►│ static pod VIP               │
    ├─ 60-init ───────────────►│ CP-01: init + token          │
    ├─ 70-join ───────────────►│ CP-02/03, worker             │
    ├─ 80-addons ─────────────►│ Cilium + addon               │
    └─ 90-verify ─────────────►│ 10 assertion ────────────────┤ cluster siap
```

Estimasi total: **25–45 menit** (dominan: apt, pull image, helm).

---

## 1. Prasyarat controller

> ⚠️ Ansible **tidak** berjalan di PowerShell Windows native.
> Pakai **jumpbox Ubuntu** atau **WSL2**. Repo tetap bisa diedit dari Windows.

### 1.1 Di controller

```bash
# ansible-core >= 2.16
python3 -m pip install --user "ansible-core>=2.16"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

ansible --version    # core 2.16+
```

### 1.2 Tool pendukung

| Tool | Untuk | Cek |
|---|---|---|
| `sops` | dekripsi secret | `sops --version` |
| `age` | key SOPS | `age --version` |
| `git` | checkout repo | `git --version` |
| `ssh` | koneksi node | `ssh -V` |

```bash
# Ubuntu/Debian
sudo apt-get install -y age
# sops: unduh binary dari github.com/getsops/sops/releases (>= 3.8)
```

> Butuh `sops >= 3.8` karena `run.sh` memakai bentuk `sops exec-env FILE -- CMD ARGS`.
> Kalau versimu lebih lama, lihat catatan di [bagian 3.4](#34-kompatibilitas-sops-lama).

### 1.3 Koleksi

```bash
cd platform/bootstrap/ansible
ansible-galaxy collection install -r requirements.yml
```

Verifikasi:

```bash
ansible-galaxy collection list | grep -E 'kubernetes.core|ansible.posix|community.general'
```

Output yang diharapkan (versi boleh berbeda):

```
kubernetes.core    5.0.0
ansible.posix      1.5.4
community.general  9.5.0
```

### 1.4 SSH & sudo

```bash
ssh-copy-id ops@10.10.20.11
ssh ops@10.10.20.11 'sudo -n true && echo "sudo NOPASSWD OK"'
```

Kalau `sudo` butuh password, tambahkan `--ask-become-pass` (`-K`) setiap kali menjalankan
playbook, atau pasang `/etc/sudoers.d/90-ops`:

```
ops ALL=(ALL) NOPASSWD:ALL
```

---

## 2. Konfigurasi inventory

Edit **dua file saja** sebelum eksekusi pertama.

### 2.1 `inventory/hosts.yml`

```yaml
k8s_cp_primary:
  hosts:
    k8s-cp-01:
      ansible_host: 10.10.20.11      # ← IP kamu
```

Checklist:

- [ ] `ansible_host` setiap node benar
- [ ] `k8s_cp_primary` berisi **tepat satu** host (tempat `kubeadm init`)
- [ ] `k8s_cp_secondary` berisi CP lain
- [ ] `k8s_workers` berisi worker
- [ ] `ansible_user` sesuai user SSH

### 2.2 `inventory/group_vars/all/main.yml`

| Variable | Wajib diubah | Kenapa |
|---|---|---|
| `kubevip_address` | ✅ | VIP harus bebas & di VLAN yang sama |
| `kubevip_interface` | ✅ | cek `ip -br a` di node |
| `api_dns_name` | ✅ | harus resolve ke VIP |
| `etcd_device` | ✅ | **salah isi = data hilang** (role menolak, tapi tetap cek) |
| `ntp_servers` | ✅ | jangan pakai pool publik |
| `k8s_pkg_version` | ⚠️ | harus ada di repo (dicek otomatis) |
| `pod_subnet` / `service_subnet` | ⚠️ | tidak boleh overlap dengan LAN |
| `nexus_*` | opsional | hanya kalau `nexus_mirror_enabled: true` |
| `cilium_mtu` | ⚠️ | 1450 untuk MTU 1500; 8950 untuk jumbo frame |

Verifikasi cepat sebelum jalan:

```bash
# CIDR tidak overlap dengan LAN
ansible -i inventory/hosts.yml k8s_cluster -m setup -a 'filter=ansible_default_ipv4' \
  | grep -E 'address'

# cek device etcd ada di setiap CP
ansible -i inventory/hosts.yml k8s_control_plane -b -m command -a 'lsblk -o NAME,SIZE,LABEL,MOUNTPOINT'
```

---

## 3. Secret dengan SOPS

### 3.1 Generate nilai

```bash
# 1) certificate key untuk upload certs & join CP (64 hex char)
#    Boleh dijalankan di mana saja yang punya kubeadm; kalau belum ada,
#    gunakan: openssl rand -hex 32
kubeadm certs certificate-key

# 2) encryption key untuk etcd (32 byte base64)
head -c 32 /dev/urandom | base64
```

### 3.2 Isi & enkripsi

```bash
cd platform/bootstrap/ansible
cp secrets.env.example secrets.env

# edit
#   K8S_CERT_KEY=<hasil langkah 1>
#   K8S_ENCRYPTION_KEY=<hasil langkah 2>
${EDITOR:-vi} secrets.env

sops -e secrets.env > secrets.env.enc
rm -f secrets.env
```

Verifikasi terenkripsi:

```bash
sops filestatus secrets.env.enc     # -> encrypted
head -3 secrets.env.enc             # -> terlihat blok sops, bukan plaintext
```

> 🚨 **Simpan `K8S_ENCRYPTION_KEY` di tempat offline** (password manager / cetak).
> Hilang = semua Secret di etcd tidak bisa dibaca, tidak ada recovery.
> Simpan juga salinan `secrets.env.enc` di lokasi backup terpisah.

### 3.3 Cek isi tanpa membocorkan

```bash
sops -d secrets.env.enc | sed 's/=.*/=<redacted>/'
```

### 3.4 Kompatibilitas sops lama

`sops < 3.8` tidak mendukung `exec-env FILE -- CMD ARGS`. Ganti isi `run.sh` menjadi:

```bash
exec sops exec-env "$SECRETS" "ansible-playbook $PLAYBOOK $*"
```

---

## 4. Uji konektivitas

**Jangan lanjut** kalau salah satu gagal.

```bash
cd platform/bootstrap/ansible

# 1. semua host terjangkau + python ada
ansible -i inventory/hosts.yml k8s_cluster -m ping

# 2. sudo bekerja
ansible -i inventory/hosts.yml k8s_cluster -b -m command -a 'id -u'

# 3. secret terbaca (harus mencetak dua nama variabel)
./run.sh playbooks/00-preflight.yml
```

Output `00-preflight` yang diharapkan:

```
TASK [Cek ansible-core versi minimum] *****************************************
ok: [localhost] => {
    "msg": "ansible-core 2.17.4 OK"
}
TASK [Cek secret dari environment (didekripsi SOPS)] **************************
ok: [localhost] => {
    "msg": "Secret bootstrap tersedia di environment"
}
```

---

## 5. Eksekusi bertahap

Disarankan untuk run pertama. Jalankan **satu per satu** dan periksa hasilnya.

| # | Playbook | Durasi | Yang terjadi | Verifikasi |
|---|---|---|---|---|
| 1 | `00-preflight.yml` | 2 s | validasi secret & versi | lihat §4 |
| 2 | `10-baseline.yml` | 1–3 m | apt, chrony, swap, sysctl, ulimit | `ansible … -a 'chronyc tracking'` |
| 3 | `20-etcd-disk.yml` | 10–30 s | format + mount vDisk etcd | `df -h /var/lib/etcd` |
| 4 | `30-containerd.yml` | 1–3 m | install & konfigurasi runtime | `systemctl is-active containerd` |
| 5 | `40-kubernetes.yml` | 1–2 m | pin & hold paket k8s | `kubeadm version -o short` |
| 6 | `50-kube-vip.yml` | 5 s | static pod VIP | `ping <VIP>` dari node lain |
| 7 | `60-init.yml` | 2–4 m | `kubeadm init` | `kubectl get nodes` |
| 8 | `70-join.yml` | 2–4 m | join CP (serial 1) + worker | `kubectl get nodes` |
| 9 | `80-addons.yml` | 5–10 m | Cilium + addon | `cilium status` |
| 10 | `90-verify.yml` | 30–60 s | 10 assertion | `PLAY RECAP failed=0` |

### 5.1 Baseline

```bash
./run.sh playbooks/10-baseline.yml
```

Perhatikan: **tidak boleh ada `failed`**. Kalau `apt` gagal karena lock, tunggu
`unattended-upgrades` selesai lalu ulangi.

Cek manual:

```bash
ansible -i inventory/hosts.yml k8s_cluster -b -m shell -a \
  'echo "swap: $(swapon --show | wc -l)"; echo "nf: $(sysctl -n fs.inotify.max_user_watches)"; chronyc tracking | grep Leap'
```

Harapan: `swap: 0`, `nf: 1048576`, `Leap status : Normal`.

### 5.2 vDisk etcd

```bash
./run.sh playbooks/20-etcd-disk.yml
```

Output penting (per CP):

```
TASK [Tampilkan hasil mount] **************************************************
ok: [k8s-cp-01] => {
    "msg": "k8s-cp-01: /dev/sdb[/var/lib/etcd] ext4 rw,noatime"
}
```

Kalau muncul `Tolak device yang sudah berisi filesystem lain`, **berhenti**.
Artinya `etcd_device` menunjuk disk yang berisi data. Periksa dengan `lsblk -f`.

### 5.3 containerd

```bash
./run.sh playbooks/30-containerd.yml
```

Output penting:

```
ok: [k8s-cp-01] => {
    "msg": "k8s-cp-01: containerd active, schema v3, SystemdCgroup OK:1"
}
```

`schema v3` = containerd 2.x (key `sandbox`), `v2` = containerd 1.x (key `sandbox_image`).
Keduanya ditangani.

Cek tambahan:

```bash
ansible -i inventory/hosts.yml k8s_cluster -b -m shell -a \
  'systemctl is-active containerd; grep -c "SystemdCgroup = true" /etc/containerd/config.toml'
```

### 5.4 Paket Kubernetes

```bash
./run.sh playbooks/40-kubernetes.yml
```

Kalau muncul:

```
Versi 1.34.5-1.1 tidak tersedia di repo v1.34.
Tersedia: kubeadm | 1.34.6-1.1 | amd64 ...
```

→ sesuaikan `k8s_pkg_version` di `group_vars/all/main.yml` dengan yang tersedia.

### 5.5 kube-vip

```bash
./run.sh playbooks/50-kube-vip.yml
ansible -i inventory/hosts.yml k8s_control_plane -b -m shell -a 'crictl ps | grep kube-vip || true'
```

Sebelum init, pod kube-vip **akan restart** karena `/etc/kubernetes/admin.conf` belum ada.
Itu normal. Yang penting:

```bash
ping -c 2 10.10.20.10     # dari node lain -> harus reply
```

### 5.6 Init

```bash
./run.sh playbooks/60-init.yml
```

Output penting di akhir:

```
TASK [Status awal cluster] ****************************************************
ok: [k8s-cp-01] => {
    "msg": [
        "NAME       STATUS     ROLES           AGE   VERSION",
        "k8s-cp-01  NotReady   control-plane   30s   v1.34.5"
    ]
}
```

`NotReady` **normal** — CNI belum ada. Lanjut.

### 5.7 Join

```bash
./run.sh playbooks/70-join.yml
```

CP di-join **satu per satu** (`serial: 1`) supaya etcd tidak menerima dua member sekaligus.

> ⚠️ Play ini butuh `set_fact` dari langkah 5.6. Kalau dijalankan terpisah, lihat
> [README bagian 7](README.md#7-kalau-ingin-memisahkan-init-dan-join).

Verifikasi quorum:

```bash
ssh ops@10.10.20.11 'sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.10.20.11:2379,https://10.10.20.12:2379,https://10.10.20.13:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health -w table'
```

Harus **3/3 healthy**.

### 5.8 Addon

```bash
./run.sh playbooks/80-addons.yml
```

Yang dilakukan: Gateway API CRD → cert-manager → metrics-server → namespace + label PSA
→ approve CSR kubelet → hapus `kubeadm-certs`.

Output penting:

```
TASK [Tampilkan ringkasan Cilium] **********************************************
ok: [k8s-cp-01] => {
    "msg": [
        "Cilium:         OK",
        "KubeProxyReplacement:   True   [ens192 ...]"
    ]
}
```

### 5.9 Verifikasi

```bash
./run.sh playbooks/90-verify.yml
```

Harus berakhir:

```
PLAY RECAP *********************************************************************
k8s-cp-01 : ok=24 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
```

Dan ringkasan:

```
ok: [k8s-cp-01] => {
    "msg": [
        "Cluster : kirahadian.local",
        "Versi   : 1.34.5",
        "Node    : 6/6 Ready",
        "etcd    : healthy",
        "VIP     : 10.10.20.10:6443"
    ]
}
```

---

## 6. Eksekusi penuh & uji idempotensi

### 6.1 Sekali jalan

```bash
./run.sh site.yml
```

Atau dari root repo: `make bootstrap`.

### 6.2 Uji idempotensi (wajib dicoba sekali)

Jalankan `site.yml` **dua kali**. Run kedua harus hampir tanpa perubahan:

```bash
./run.sh site.yml 2>&1 | tee /tmp/run1.log
./run.sh site.yml 2>&1 | tee /tmp/run2.log

grep -A8 'PLAY RECAP' /tmp/run2.log
```

Yang **tetap** `changed` di run kedua dan itu wajar:

| Task | Alasan |
|---|---|
| `kubeadm token create` | token baru tiap run, TTL 1 jam (lebih aman daripada token permanen) |
| handler `restart chrony` | hanya jika template berubah — biasanya tidak |

Selain itu `changed=0`. Kalau ada `changed` lain, selidiki — biasanya template
berubah karena variabel tidak konsisten.

---

## 7. Handoff setelah cluster jadi

Cluster siap, tapi belum bisa dipakai orang lain. Empat langkah:

### 7.1 Kubeconfig

Ansible sudah menaruhnya di:

```
platform/bootstrap/artifacts/kubeconfig/config
```

```bash
export KUBECONFIG=$PWD/platform/bootstrap/artifacts/kubeconfig/config
kubectl get nodes
```

> File ini setara root. Jangan commit (sudah di `.gitignore`), jangan kirim lewat chat.

### 7.2 kube-bench

```bash
# manifest Job kube-bench ada di INSTALL.md §15.6
kubectl -n kube-system logs job/kube-bench | tee kube-bench-$(date +%F).log
```

Target: control plane ≥ 90%, worker ≥ 85% (ADR-0010).
Setiap FAIL → remediasi lewat role di sini, atau masuk daftar pengecualian **dengan alasan**.

### 7.3 Benchmark performa

```bash
bash ../../../infra/benchmark/scripts/run-all.sh post-k8s
```

Simpan hasilnya — ini baseline untuk membandingkan setelah hardening.

### 7.4 ArgoCD

```bash
cd ../../../..
# lihat platform/gitops/README.md
```

---

## 8. Day-2

| Tugas | Dilakukan dengan | Catatan |
|---|---|---|
| Tambah worker | edit `hosts.yml`, jalankan `40-kubernetes.yml` lalu `70-join.yml` | `70-join` butuh data join — jalankan `site.yml --limit k8s_cp_primary:new-node` |
| Ganti VIP | ubah `kubevip_address`, jalankan `50-kube-vip.yml`, update DNS | penyebab downtime singkat |
| Upgrade minor | **manual** — `INSTALL.md` §18 | tidak diotomasi sengaja |
| Rotasi cert kubeadm | **manual** — `INSTALL.md` §18.5 | |
| Patch OS | `10-baseline.yml` (rolling, satu node) | jangan semua sekaligus |
| Rotasi age key | `sops updatekeys`, lalu `sops rotate` | lihat `docs/adr/0005` |

Tambah worker dengan aman:

```bash
# 1. tambahkan host ke groups k8s_workers di hosts.yml
# 2. siapkan OS + runtime di node baru saja
./run.sh playbooks/10-baseline.yml --limit k8s-w-04
./run.sh playbooks/20-etcd-disk.yml --limit k8s-w-04   # skip otomatis (worker)
./run.sh playbooks/30-containerd.yml --limit k8s-w-04
./run.sh playbooks/40-kubernetes.yml --limit k8s-w-04

# 3. join — butuh token; jalankan penuh agar set_fact tersedia
./run.sh site.yml
```

---

## 9. Troubleshooting

| Gejala | Sebab | Perbaikan |
|---|---|---|
| `K8S_CERT_KEY ... belum terisi` | dipanggil `ansible-playbook` langsung | pakai `./run.sh` |
| `sops: command not found` | sops belum di PATH | install, atau pakai path absolut di `run.sh` |
| `exec-env: unknown flag --` | sops < 3.8 | lihat §3.4 |
| `UNREACHABLE` | SSH key / firewall | `ansible -m ping` per host |
| `apt` lock | unattended-upgrades jalan | `systemctl stop unattended-upgrades`, ulangi |
| `Versi X tidak tersedia` | `k8s_pkg_version` salah | `apt-cache madison kubeadm` |
| `Tolak device yang sudah berisi filesystem` | `etcd_device` salah | `lsblk -f`, jangan paksa |
| containerd restart loop | config.toml tidak valid | `journalctl -u containerd -n 50` |
| `Data join tidak ditemukan` | `70-join` dijalankan terpisah | jalankan `site.yml` |
| Cilium helm timeout | VIP mati / MTU salah | `crictl ps \| grep kube-vip`, cek MTU |
| `metrics-server` gagal | CSR kubelet belum approve | `kubectl get csr` lalu approve |
| `etcd unhealthy` di verify | disk lambat / quorum hilang | cek `etcd_disk_wal_fsync_duration_seconds` |

Debug satu task:

```bash
./run.sh site.yml --start-at-task "Init cluster" -vv
./run.sh site.yml --list-tasks
```

> Task dengan `no_log: true` (token, key) tidak menampilkan detail meski `-vvv`.
> Untuk mendiagnosis, jalankan perintahnya manual di node.

---

## 10. Teardown

```bash
# worker
kubectl drain k8s-w-03 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k8s-w-03
ssh ops@10.10.20.23 'sudo kubeadm reset -f; sudo rm -rf /etc/cni/net.d /var/lib/kubelet'

# control plane (hapus member etcd dulu dari CP lain)
ssh ops@10.10.20.11 'sudo ETCDCTL_API=3 etcdctl member list -w table'
# lalu member remove <id>, baru reset node tersebut
```

Ansible **tidak** menyediakan role reset (sengaja — terlalu berbahaya untuk dijalankan
tanpa konfirmasi). Prosedur lengkap: `INSTALL.md` §19.

---

## 11. Publikasi ke Ansible Galaxy

Direktori ini sekaligus berformat **collection**, jadi bisa dipublikasikan dan dipakai
ulang di proyek lain.

### 11.1 Konsep: role vs collection

| | Role | Collection |
|---|---|---|
| Unit distribusi | satu role | banyak role + plugin + module |
| Namespace | bebas | `namespace.name` wajib |
| Dependency | `requirements.yml` gaya lama | `galaxy.yml` + resolusi otomatis |
| Status | legacy | **standar sekarang** |

Kita pakai **collection** karena berisi 10 role yang saling bergantung.

### 11.2 Yang ada di `galaxy.yml`

```yaml
namespace: rizkirahadiaan            # ← HARUS sama dengan namespace akun Galaxy kamu
name: kubeadm_bootstrap
version: 0.1.0                 # ← naikkan setiap publish (immutable)
dependencies:
  kubernetes.core: ">=5.0.0"
  ansible.posix: ">=1.5.0"
  community.general: ">=9.0.0"
build_ignore:                  # jangan ikutkan yang site-specific / rahasia
  - inventory
  - secrets.env*
  - artifacts
```

> ⚠️ `inventory/` **wajib** di-`build_ignore`. Isinya IP asli dan struktur cluster-mu.
> Yang dibagikan adalah **role**, bukan konfigurasi environment-mu.

### 11.3 Prasyarat publish

1. Akun di <https://galaxy.ansible.com> (login GitHub).
2. Namespace = username (atau buat namespace organisasi).
3. API token: **Preferences → API Key**.
4. `namespace` di `galaxy.yml` disamakan dengan langkah 2.

```bash
export ANSIBLE_GALAXY_API_KEY='xxxxxxxxxxxxxxxx'
# jangan simpan di shell history: pakai `read -rs` atau password manager
```

### 11.4 Build

```bash
cd platform/bootstrap/ansible

ansible-galaxy collection build --force
```

Output:

```
Created collection for rizkirahadiaan.kubeadm_bootstrap at
/path/platform/bootstrap/ansible/rizkirahadiaan-kubeadm_bootstrap-0.1.0.tar.gz
```

Isi tarball bisa diperiksa:

```bash
tar tzf rizkirahadiaan-kubeadm_bootstrap-0.1.0.tar.gz | head -30
```

Pastikan **tidak ada** `inventory/`, `secrets.env`, atau `artifacts/`.

### 11.5 Uji instalasi lokal (sebelum publish)

Ini langkah yang sering dilewatkan. Build bisa "sukses" tapi tetap tidak bisa dipakai.

```bash
mkdir -p /tmp/galaxy-test && cd /tmp/galaxy-test

ansible-galaxy collection install \
  /path/platform/bootstrap/ansible/rizkirahadiaan-kubeadm_bootstrap-0.1.0.tar.gz \
  -p ./collections

# buat playbook uji minimal
cat > test.yml <<'EOF'
- hosts: localhost
  gather_facts: false
  tasks:
    - ansible.builtin.debug:
        msg: "{{ lookup('ansible.builtin.fileglob', './collections/ansible_collections/rizkirahadiaan/kubeadm_bootstrap/roles/*') }}"
EOF

ANSIBLE_COLLECTIONS_PATH=./collections ansible-playbook test.yml
```

Yang harus terlihat: 10 direktori role.

Cek juga dokumentasi role terbaca:

```bash
ansible-doc -t role -l -p ./collections 2>/dev/null | head
```

### 11.6 Publish

```bash
cd platform/bootstrap/ansible

ansible-galaxy collection publish \
  ./rizkirahadiaan-kubeadm_bootstrap-0.1.0.tar.gz \
  --api-key "$ANSIBLE_GALAXY_API_KEY"
```

Sukses:

```
Collection has been successfully published to Ansible Galaxy.
```

Cek di: `https://galaxy.ansible.com/ui/repo/published/rizkirahadiaan/kubeadm_bootstrap/`

### 11.7 Pakai di proyek lain

```bash
ansible-galaxy collection install rizkirahadiaan.kubeadm_bootstrap
```

`requirements.yml` proyek lain:

```yaml
collections:
  - name: rizkirahadiaan.kubeadm_bootstrap
    version: ">=0.1.0"
```

Playbook:

```yaml
- hosts: k8s_cluster
  become: true
  roles:
    - rizkirahadiaan.kubeadm_bootstrap.common
    - rizkirahadiaan.kubeadm_bootstrap.containerd
```

### 11.8 Aturan versi

| Perubahan | Naikkan |
|---|---|
| perbaikan bug, tanpa ubah behavior | `0.1.0` → `0.1.1` |
| role/task/variabel baru (backward compatible) | `0.1.0` → `0.2.0` |
| perubahan yang memutus kompatibilitas | `0.1.0` → `1.0.0` |

Galaxy **menolak** versi yang sudah ada. Setiap publish: ubah `version` di `galaxy.yml`,
perbarui `CHANGELOG.rst`, commit, lalu build ulang.

### 11.9 Alternatif distribusi

| Cara | Perintah | Kapan dipakai |
|---|---|---|
| Lokal/Git | `ansible-galaxy collection install git+https://…` | internal, tanpa publish publik |
| Private Automation Hub | `publish --server https://hub.internal/api/galaxy/` | enterprise |
| Tarball manual | kirim `.tar.gz` | offline / air-gapped |
| Role saja (legacy) | `ansible-galaxy role import` | hanya kalau butuh satu role |

---

## 12. Integrasi CI

Contoh job GitLab untuk lint + build + publish saat tag `ansible-v*`:

```yaml
ansible-lint-build:
  stage: validate
  image: python:3.12
  before_script:
    - pip install "ansible-core>=2.16" ansible-lint
    - cd platform/bootstrap/ansible
    - ansible-galaxy collection install -r requirements.yml
  script:
    - ansible-playbook site.yml --syntax-check
    - ansible-lint
    - ansible-galaxy collection build --force
  artifacts:
    paths:
      - platform/bootstrap/ansible/*.tar.gz

publish-galaxy:
  stage: release
  image: python:3.12
  needs: [ansible-lint-build]
  rules:
    - if: $CI_COMMIT_TAG =~ /^ansible-v/
  before_script:
    - pip install "ansible-core>=2.16"
  script:
    - cd platform/bootstrap/ansible
    - ansible-galaxy collection publish ./*.tar.gz --api-key "$ANSIBLE_GALAXY_API_KEY"
```

`ANSIBLE_GALAXY_API_KEY` disimpan sebagai **masked + protected** CI variable,
hanya tersedia di tag.

> Jangan jalankan `ansible-playbook site.yml` (tanpa `--syntax-check`) di CI —
> pipeline tidak punya akses ke node cluster, dan seharusnya tidak.

---

## Lampiran A — perintah ad-hoc

```bash
# semua node
ansible -i inventory/hosts.yml k8s_cluster -b -m shell -a 'uptime; df -h / /var/lib/etcd 2>/dev/null'

# hanya worker
ansible -i inventory/hosts.yml k8s_workers -b -m shell -a 'systemctl is-active containerd'

# cek versi paket konsisten
ansible -i inventory/hosts.yml k8s_cluster -m command -a 'kubeadm version -o short'

# restart kubelet satu node
ansible -i inventory/hosts.yml k8s-w-01 -b -m service -a 'name=kubelet state=restarted'

# lihat variabel efektif
./run.sh site.yml --list-hosts
ansible-inventory -i inventory/hosts.yml --graph
ansible-inventory -i inventory/hosts.yml --host k8s-cp-01

# dry-run (hanya untuk baseline — kubeadm/helm tidak mendukung check mode)
ansible-playbook playbooks/10-baseline.yml --check --diff
```
