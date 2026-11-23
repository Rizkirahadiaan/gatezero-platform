# Ansible — VM Hardening

Versi **eksekusi** dari [`../HARDENING.md`](../HARDENING.md) dan
[`../HARDENING-K8S.md`](../HARDENING-K8S.md).

> Dokumen = penjelasan **kenapa**. Role = eksekusi **apa**.
> Kalau keduanya berbeda, dokumen yang benar — lalu perbaiki role-nya.

---

## 1. Peta role

| Role | Lapis di HARDENING.md | Mengubah apa |
|---|---|---|
| `baseline` | 0, 2, 6 | paket dasar, chrony, umask, journald cap, patch policy |
| `ssh_hardening` | 1 | sshd drop-in, banner, validasi sebelum restart |
| `kernel_hardening` | 3 | sysctl + blacklist module |
| `filesystem_hardening` | 4 | tmpfs mount, permission file sensitif, cron/at |
| `service_minimize` | 5 | nonaktifkan layanan, hapus paket (opt-in) |
| `auditd_hardening` | 6 | aturan audit + batas log |
| `nftables_firewall` | 8 | ruleset host dengan allowlist eksplisit |
| `aide_integrity` | 7 | baseline AIDE + cron harian |
| `k8s_sysctl` | HARDENING-K8S §2 | inotify, maxkeys, somaxconn |
| `k8s_verify` | HARDENING-K8S §11 | **read-only** assertion |
| `cis_audit` | CIS-BENCHMARK §4 | Lynis (+USG opsional) + metrik |

---

## 2. Prasyarat

**Ansible tidak berjalan di PowerShell Windows.** Pakai jumpbox Ubuntu atau WSL2.

```bash
python3 -m pip install --user "ansible-core>=2.16"
ansible-galaxy collection install -r requirements.yml

# verifikasi
ansible -i inventory/hosts.yml vms -m ping
```

---

## 3. Menjalankan

```bash
cd infra/vm/ansible

# 1. Semua VM — baseline (SSH, sysctl, filesystem, auditd, firewall, AIDE)
ansible-playbook baseline.yml

# 2. Node Kubernetes saja — overlay
ansible-playbook k8s-node.yml

# 3. Audit (read-only)
ansible-playbook audit.yml

# atau semuanya
ansible-playbook site.yml
```

### Rollout yang disarankan

Jangan jalankan ke semua VM sekaligus pada percobaan pertama.

```bash
# 1. jumpbox dulu (paling murah kalau terkunci)
ansible-playbook baseline.yml --limit jumpbox

# 2. satu VM layanan
ansible-playbook baseline.yml --limit svc-sonar-01

# 3. satu control plane
ansible-playbook baseline.yml --limit k8s-cp-02

# 4. baru sisanya, satu per satu
ansible-playbook site.yml --limit 'vms:!k8s-cp-01'
```

> Control plane pertama (`k8s-cp-01`) sebaiknya paling akhir: dia memegang
> `admin.conf` yang dipakai untuk verifikasi.

---

## 4. Pengaman yang dipasang di role

Role ini **tidak** boleh menjadi penyebab cluster mati. Karena itu:

| Risiko | Pengamanan |
|---|---|
| SSH terkunci setelah password auth dimatikan | role gagal kalau `authorized_keys` tidak ada |
| sshd config rusak | `sshd -t` divalidasi **sebelum** handler restart dijalankan |
| firewall memblokir semua | menolak `admin_cidrs` kosong atau `0.0.0.0/0`; `nft -c` validasi; `ct state established` melindungi sesi berjalan; ruleset lama dibackup |
| port k8s hilang dari allowlist | assert `6443/tcp` dan `8472/udp` untuk grup `k8s_nodes` |
| `ufw` konflik Cilium | role gagal kalau `ufw` aktif |
| node k8s mati karena sysctl | `k8s_sysctl` hanya menambah; tiga sysctl yang divalidasi kubelet diverifikasi ada di nilai benar |
| `/tmp noexec` memutus build | default `true`, dapat dimatikan per host; runner k8s tidak terpengaruh (build di pod) |
| AIDE makan 15 menit | `async` + `poll`, `creates` guard, hanya sekali |

**Rollback cepat** kalau terkunci:

```bash
# dari console Prism
nft flush ruleset
rm -f /etc/ssh/sshd_config.d/99-hardening.conf && systemctl restart ssh
rm -f /etc/sysctl.d/99-hardening.conf && sysctl --system
rm -f /etc/modprobe.d/99-blacklist.conf && update-initramfs -u
```

---

## 5. Yang **tidak** dilakukan role ini (dan alasannya)

| Hal | Kenapa |
|---|---|
| Menulis ulang `/var/lib/kubelet/config.yaml` | kubeadm yang memiliki file itu. Perubahan manual hilang saat upgrade. `k8s_verify` hanya **memeriksa**; perbaikan dilakukan di `platform/bootstrap/ansible` lalu `kubeadm upgrade node phase kubelet-config` |
| Mengubah argumen apiserver/etcd | sama: sumbernya `kubeadm-config.yaml`. Role memverifikasi, tidak menambal |
| `usg fix` | terlalu merusak untuk dijalankan otomatis. Role hanya `usg audit` |
| Menghapus paket secara default | `service_minimize_remove: []`. Penghapusan harus keputusan per host |
| Mengubah partisi/disk | di luar cakupan hardening; lihat spesifikasi VM |
| Mengelola `authorized_keys` | identitas pengguna bukan milik role hardening |

Prinsipnya: **role ini menambah lapisan, bukan mengambil alih kepemilikan
konfigurasi yang sudah punya pemilik lain.**

---

## 6. Per-variabel override

Semua variabel ada di `inventory/group_vars/`. Override per host tanpa mengubah role:

```yaml
# inventory/host_vars/k8s-w-02.yml
kernel_kptr_restrict: 1        # node ini menjalankan perf/bcc
filesystem_tmp_noexec: false   # hanya bila ada build tool di HOST
firewall_allowed_tcp: [6443, 10250, 9100, 3000]
```

Gunakan `host_vars/` atau tambahkan variabel langsung di `inventory/hosts.yml`.

---

## 7. Troubleshooting

| Gejala | Sebab | Perbaikan |
|---|---|---|
| `SSH terkunci` | password auth mati tanpa key | console Prism, kembalikan drop-in |
| `usg: command not found` | paket `usg` tidak ada di mirror | lewati `cis_usg_enabled` atau cari nama paket |
| AIDE timeout | disk besar | naikkan `aide_init_timeout`, atau `aide_enabled: false` sementara |
| `auditd` gagal restart | unit dimask | `systemctl unmask auditd` |
| `nft: syntax error` | variabel CIDR kosong | isi `firewall_admin_cidrs` |
| node `NotReady` setelah hardening | module di-blacklist | keluarkan `vxlan`/`geneve` dari daftar |
| pod `ContainerCreating` | inotify kurang | jalankan `k8s-node.yml` |
| `k8s_verify` gagal di apiserver | bootstrap belum diperbarui | perbaiki `platform/bootstrap/ansible`, jalankan ulang |

Dry-run (terbatas — `nft`, `aideinit`, `usg` tidak mendukung check mode):

```bash
ansible-playbook baseline.yml --check --diff --limit jumpbox
```

---

## 8. Struktur

```
infra/vm/ansible/
├── ansible.cfg
├── requirements.yml
├── site.yml            # baseline + k8s overlay
├── baseline.yml        # semua VM
├── k8s-node.yml        # node k8s saja
├── audit.yml           # CIS audit (read-only)
├── inventory/
│   ├── hosts.yml
│   └── group_vars/{all,k8s_nodes}/main.yml
└── roles/              # 11 role, lihat tabel di §1
```
