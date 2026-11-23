# Standard Hardening — Global VM

Baseline untuk **semua** VM Ubuntu 24.04 LTS di platform ini: jumpbox, GitLab, SonarQube,
Nexus, object storage, control plane, dan worker.

> Dokumen pendamping:
> - node Kubernetes → tambahan di [`HARDENING-K8S.md`](HARDENING-K8S.md)
> - cara mengukur → [`CIS-BENCHMARK.md`](CIS-BENCHMARK.md)
> - pengecualian resmi → [`docs/adr/0010`](../../docs/adr/0010-cis-hardening-exceptions.md)

---

## Daftar Isi

1. [Ruang lingkup](#1-ruang-lingkup)
2. [Lapis 0 — provisioning](#2-lapis-0--provisioning)
3. [Lapis 1 — identitas & akses](#3-lapis-1--identitas--akses)
4. [Lapis 2 — patch & paket](#4-lapis-2--patch--paket)
5. [Lapis 3 — kernel (sysctl)](#5-lapis-3--kernel-sysctl)
6. [Lapis 4 — filesystem](#6-lapis-4--filesystem)
7. [Lapis 5 — minimalisasi layanan & module](#7-lapis-5--minimalisasi-layanan--module)
8. [Lapis 6 — logging & audit](#8-lapis-6--logging--audit)
9. [Lapis 7 — integritas file](#9-lapis-7--integritas-file)
10. [Lapis 8 — jaringan (nftables)](#10-lapis-8--jaringan-nftables)
11. [Lapis 9 — waktu](#11-lapis-9--waktu)
12. [Verifikasi](#12-verifikasi)
13. [Rollback](#13-rollback)
14. [Yang tidak boleh dilakukan](#14-yang-tidak-boleh-dilakukan)
15. [Roadmap](#15-roadmap)

---

## 1. Ruang lingkup

| VM | Baseline global | Overlay k8s |
|---|---|---|
| `jumpbox` | ✅ | — |
| `gitlab-prod` | ✅ | — |
| `svc-sonar-01` | ✅ | — |
| `svc-nexus-01` | ✅ | — |
| `svc-s3-01` | ✅ | — |
| `k8s-cp-01..03` | ✅ | ✅ |
| `k8s-w-01..03` | ✅ | ✅ |

**OS:** Ubuntu 24.04 LTS server (tanpa desktop), minimal install.

---

## 2. Lapis 0 — provisioning

Hardening dimulai sebelum `apt` dijalankan. VM yang dibuat dari template "asal jadi"
akan membawa masalah yang tidak bisa ditambal belakangan.

### 2.1 `cloud-init` baseline

```yaml
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.gatezero.lab
timezone: Asia/Jakarta
prefer_fqdn_over_hostname: true

users:
  - name: ops
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

# Password login dimatikan sejak detik pertama
ssh_pwauth: false
disable_root: true

package_update: true
package_upgrade: true
packages:
  - chrony
  - ca-certificates
  - curl
  - jq
  - unattended-upgrades
  - auditd
  - nftables

runcmd:
  - [systemctl, enable, --now, chrony]
  - [systemctl, enable, --now, nftables]
  - [timedatectl, set-ntp, "true"]
```

### 2.2 Golden image — tiga jebakan

| Jebakan | Akibat | Perbaikan |
|---|---|---|
| `machine-id` duplikat | kubelet/journald/DHCP kacau | regenerate saat first boot |
| SSH host key duplikat | fingerprint sama di semua node → deteksi MITM lumpuh | regenerate saat first boot |
| `/etc/hostname` terbawa | hostname salah, tapi `hostnamectl` terlihat benar | set dari cloud-init |

```bash
# Jalankan SEKALI saat provisioning, sebelum hardening lain
sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
sudo systemd-machine-id-setup

sudo rm -f /etc/ssh/ssh_host_*
sudo ssh-keygen -A
sudo systemctl restart ssh

# bersihkan jejak template
sudo cloud-init clean --logs
sudo truncate -s 0 /etc/machine-id   # cloud-init akan mengisi ulang
```

### 2.3 Sisi Nutanix

| Item | Setelan | Alasan |
|---|---|---|
| Boot | UEFI + GPT (bila tersedia) | dukungan Secure Boot & partisi >2 TB |
| CPU passthrough | OFF | mematikan live migration |
| Memory overcommit | OFF untuk VM stateful | etcd/Prometheus benci memory stall |
| NGT | OFF untuk node k8s | kurangi attack surface |
| Console/VNC | dibatasi ke admin | akses console = bypass SSH hardening |
| Prism RBAC | role minimal per tim | jangan semua orang jadi cluster-admin |

> Enkripsi data-at-rest diserahkan ke Nutanix (encryption-at-rest pada storage container),
> bukan LUKS di guest. LUKS menambah masalah operasional (passphrase saat boot) tanpa
> manfaat berarti ketika hypervisor sudah menyediakan enkripsi.

---

## 3. Lapis 1 — identitas & akses

### 3.1 SSH

`/etc/ssh/sshd_config.d/99-hardening.conf`:

```sshconfig
# --- autentikasi ---
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
UsePAM yes

# --- pembatasan ---
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
AllowTcpForwarding no

# --- informasi ---
LogLevel VERBOSE
Banner /etc/issue.net
PrintLastLog yes
```

Verifikasi (jangan tutup sesi lama sebelum ini lulus):

```bash
sudo sshd -t                      # cek sintaks
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|allowtcpforwarding)'
```

Harapan:

```
permitrootlogin no
passwordauthentication no
maxauthtries 3
allowtcpforwarding no
```

> ⚠️ `AllowTcpForwarding no` memutus `ssh -L` dan `ssh -R`. Kalau kamu biasa
> memakai `ssh -L 6443:...` untuk akses apiserver, pakai `kubectl proxy` atau
> Tailscale/Cloudflare Tunnel, atau set `AllowTcpForwarding local`.

### 3.2 Pembatasan sumber

Batasi SSH hanya dari jumpbox di level jaringan, bukan hanya di sshd:

```bash
# di nftables (lihat Lapis 8)
tcp dport 22 ip saddr { 10.10.20.5 } accept
```

`Match Address` di sshd sebagai lapisan kedua:

```sshconfig
Match Address 10.10.20.0/24
    AllowUsers ops
```

### 3.3 Sudo

```bash
sudo visudo -f /etc/sudoers.d/90-ops
```

```
# NOPASSWD karena login sudah wajib publickey; bukan pengganti autentikasi
ops ALL=(ALL:ALL) NOPASSWD:ALL
Defaults timestamp_timeout=5
Defaults logfile=/var/log/sudo.log
Defaults log_input, log_output
```

`log_input`/`log_output` merekam sesi sudo — berguna untuk forensik, tapi
**menyimpan data sensitif**. Aktifkan hanya di jumpbox dan VM produksi, dan pastikan
`/var/log/sudo.log` dirotasi + dilindungi.

### 3.4 Umask & shell

```bash
# /etc/profile.d/99-umask.sh
umask 027
```

```bash
# /etc/login.defs
UMASK           027
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   7
```

> Karena tidak ada password (SSH key + SSO), kebijakan password hanya berlaku untuk
> akun lokal darurat. Tetap disetel agar tidak jadi temuan CIS.

### 3.5 MFA (opsional, jumpbox saja)

```bash
sudo apt install -y libpam-google-authenticator
google-authenticator -t -d -f -r 3 -R 30 -w 3
```

Lalu di `sshd_config.d/99-hardening.conf`:

```sshconfig
AuthenticationMethods publickey,keyboard-interactive
KbdInteractiveAuthentication yes
```

Tambahkan `pam_google_authenticator.so` di `/etc/pam.d/sshd`.

**Jangan** pasang MFA di semua VM — akan memutus otomasi (Ansible, CI). Cukup di pintu masuk.

---

## 4. Lapis 2 — patch & paket

### 4.1 Unattended upgrades (security only)

`/etc/apt/apt.conf.d/51-unattended-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";

Unattended-Upgrade::Origins-Pattern {
  "origin=Ubuntu,archive=*-security";
};

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
```

**Kenapa `Automatic-Reboot false`:** node Kubernetes yang reboot sendiri kapan saja
lebih berbahaya daripada kernel yang belum di-patch. Reboot dijadwalkan manual
(lihat `platform/bootstrap/kubeadm/INSTALL.md` §18).

### 4.2 Batasi paket yang tidak perlu

```bash
# hapus yang tidak pernah dibutuhkan di server
sudo apt purge -y \
  snapd cups avahi-daemon avahi-autoipd \
  rpcbind bluetooth bluez modemmanager \
  whoopsie popularity-contest \
  telnet rsh-client talk ntalk \
  xinetd inetutils-inetd

sudo apt autoremove -y
```

> `snapd` dihapus karena server tidak butuh snap; ini juga membebaskan `squashfs`
> loop mount sehingga bisa di-blacklist (Lapis 5).
> **Konsekuensi:** jangan install tool via snap di server (helm, kubectl → pakai binary/apt).

### 4.3 Kernel & boot

```bash
# batasi jumlah kernel lama
sudo tee /etc/apt/apt.conf.d/01-autoremove-kernels >/dev/null <<'EOF'
APT::Install-Recommends "false";
EOF

# cek kernel terpasang
dpkg -l 'linux-image-*' | awk '/^ii/{print $2}'
```

`/etc/default/grub` — tambahkan mitigasi & parameter keamanan:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=auto,nosmt"
```

> `nosmt` mematikan SMT (Hyper-Threading): keamanan naik, throughput turun 10–30%.
> **Jangan** aktifkan di worker tanpa mengukur dulu (`infra/benchmark`).
> Untuk VM di Nutanix, SMT dikelola hypervisor — parameter ini biasanya tidak relevan.

```bash
sudo update-grub
```

### 4.4 Verifikasi patch

```bash
sudo unattended-upgrade --dry-run -d 2>&1 | tail -20
sudo apt list --upgradable
```

---

## 5. Lapis 3 — kernel (sysctl)

`/etc/sysctl.d/99-hardening.conf`:

```ini
# --- informasi kernel ---
kernel.kptr_restrict      = 2
kernel.dmesg_restrict     = 1
kernel.yama.ptrace_scope  = 1
kernel.randomize_va_space = 2
kernel.sysrq              = 0
kernel.core_pattern       = |/bin/false
kernel.unprivileged_bpf_disabled = 1
kernel.bpf_jit_harden     = 2
kernel.perf_event_paranoid = 3

# --- filesystem race & symlink ---
fs.protected_hardlinks = 1
fs.protected_symlinks  = 1
fs.protected_fifos     = 2
fs.protected_regular   = 2
fs.suid_dumpable       = 0

# --- jaringan ---
net.ipv4.conf.all.accept_redirects        = 0
net.ipv4.conf.default.accept_redirects    = 0
net.ipv4.conf.all.secure_redirects        = 0
net.ipv4.conf.all.send_redirects          = 0
net.ipv4.conf.all.accept_source_route     = 0
net.ipv4.conf.all.log_martians            = 1
net.ipv4.icmp_echo_ignore_broadcasts      = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                   = 1
net.ipv4.conf.all.rp_filter               = 1
net.ipv6.conf.all.accept_ra               = 0
net.ipv6.conf.all.accept_redirects        = 0
```

```bash
sudo sysctl --system
```

### Konsekuensi yang harus disadari

| Setting | Efek samping |
|---|---|
| `kernel.kptr_restrict=2` | `perf`, `bpftrace`, `bcc` tidak bisa membaca simbol kernel. Turunkan ke `1` kalau butuh profiling |
| `kernel.yama.ptrace_scope=1` | `gdb` tidak bisa attach ke proses milik user lain; `ptrace_scope=2` memutus `kubectl debug` |
| `kernel.core_pattern=\|/bin/false` | core dump hilang — debug crash jadi sulit |
| `kernel.dmesg_restrict=1` | `dmesg` butuh root |
| `net.ipv6.conf.all.accept_ra=0` | SLAAC mati; **wajib** IP statis |
| `net.ipv4.conf.all.rp_filter=1` | di node Cilium, uji dulu — strict rp_filter bisa memblokir trafik VXLAN |
| `kernel.perf_event_paranoid=3` | eBPF/perf butuh CAP_PERFMON; Tetragon tetap aman (pakai BTF) |

> Di node Kubernetes, sysctl ini **harus** selaras dengan `protectKernelDefaults: true`
> pada kubelet. Lihat [`HARDENING-K8S.md` §3](HARDENING-K8S.md#3-kubelet).

---

## 6. Lapis 4 — filesystem

### 6.1 Mount options

`/etc/fstab`:

```fstab
tmpfs   /tmp       tmpfs  defaults,nodev,nosuid,noexec,size=2G   0 0
tmpfs   /var/tmp   tmpfs  defaults,nodev,nosuid,noexec,size=1G   0 0
tmpfs   /dev/shm   tmpfs  defaults,nodev,nosuid,noexec,size=1G   0 0

# partisi terpisah (lihat spesifikasi VM)
/dev/vg0/lv_log  /var/log  xfs  defaults,nodev,nosuid,noatime     0 0
/dev/vg0/lv_home /home     xfs  defaults,nodev,nosuid,noatime     0 0
```

⚠️ **`noexec` di `/tmp` bukan untuk semua VM.** Memblokir build tool (BuildKit, buildah,
pip compile) dan installer. Lihat pengecualian di
[`HARDENING-K8S.md` §9](HARDENING-K8S.md#9-tabel-pengecualian-cis).

⚠️ `noexec` di `/dev/shm` bisa memutus aplikasi yang men-JIT ke shared memory
(sebagian runtime Java/.NET). Uji per peran VM.

### 6.2 Permission file sensitif

```bash
sudo chmod 600 /etc/shadow /etc/gshadow
sudo chmod 644 /etc/passwd /etc/group
sudo chown root:root /etc/shadow /etc/gshadow /etc/passwd /etc/group
sudo chmod 700 /root
sudo chmod 750 /home/* 2>/dev/null

# cari world-writable yang mencurigakan
sudo find / -xdev -type f -perm -0002 ! -path '/proc/*' ! -path '/sys/*' 2>/dev/null
sudo find / -xdev -type d -perm -0002 ! -path '/proc/*' ! -path '/sys/*' 2>/dev/null
```

### 6.3 Batasi cron & at

```bash
sudo chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly
sudo chmod 600 /etc/crontab
sudo chmod 600 /etc/at.allow 2>/dev/null

# hanya root yang boleh pakai cron/at
echo 'root' | sudo tee /etc/cron.allow >/dev/null
echo 'root' | sudo tee /etc/at.allow >/dev/null
sudo rm -f /etc/cron.deny /etc/at.deny
```

---

## 7. Lapis 5 — minimalisasi layanan & module

### 7.1 Layanan yang harus mati

```bash
for svc in cups avahi-daemon rpcbind bluetooth ModemManager whoopsie; do
  sudo systemctl disable --now "$svc" 2>/dev/null || true
done

# inventaris layanan yang listen
sudo ss -tulpn
```

Yang **boleh** listen (sesuaikan per peran):

| VM | Port wajib |
|---|---|
| jumpbox | 22 |
| gitlab | 22, 80, 443, 22 (git ssh) |
| sonar | 22, 9000 (internal) |
| nexus | 22, 8081, 8082–8084 |
| node k8s | lihat `INSTALL.md` §3 port matrix |

### 7.2 Blacklist module

`/etc/modprobe.d/99-blacklist.conf`:

```
# filesystem yang tidak dipakai
install cramfs /bin/true
install freevxfs /bin/true
install hfs /bin/true
install hfsplus /bin/true
install jffs2 /bin/true
install udf /bin/true
install squashfs /bin/true      # hanya setelah snapd dihapus

# protokol jaringan tidak dipakai
install dccp /bin/true
install rds /bin/true
install tipc /bin/true
install sctp /bin/true          # hati-hati: aplikasi berbasis SCTP akan gagal

# media lepas
install usb-storage /bin/true
```

```bash
sudo update-initramfs -u
```

**Jangan** blacklist: `overlay`, `br_netfilter`, `nf_conntrack`, `vxlan`, `geneve`,
`iscsi_tcp` (dibutuhkan CSI), `nvme`, `virtio_*`.

> `squashfs` hanya boleh di-blacklist **setelah** `snapd` dihapus dan tidak ada
> paket snap terpasang. Kalau ragu, lewati baris ini.

---

## 8. Lapis 6 — logging & audit

### 8.1 Batasi journald

`/etc/systemd/journald.conf.d/99-cap.conf`:

```ini
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=200M
RuntimeMaxUse=200M
MaxRetentionSec=30day
Compress=yes
Storage=persistent
ForwardToSyslog=yes
```

```bash
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

> Tanpa batas ini, `/var/log/journal` bisa tumbuh sampai memenuhi `/var/log` dan
> memicu masalah yang sulit dilacak (journald sendiri gagal menulis).

### 8.2 auditd

`/etc/audit/rules.d/99-hardening.rules`:

```
-D
-b 8192
--backlog_wait_time 0
-f 1

# identitas
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group  -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k privilege
-w /etc/sudoers.d/ -p wa -k privilege

# autentikasi
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /var/log/auth.log -p wa -k authlog

# paket & service
-w /etc/apt/ -p wa -k package
-w /etc/systemd/ -p wa -k systemd

# eksekusi oleh root dari sesi user
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_exec

# modul kernel
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
```

```bash
sudo augenrules --load
sudo auditctl -l | head
sudo systemctl enable --now auditd
```

Cek bahwa auditd **tidak** ikut panic saat disk penuh: `-f 1` artinya "log lalu lanjut",
bukan `-f 2` (panic).

Rotasi `/etc/audit/auditd.conf`:

```ini
max_log_file = 50
num_logs = 10
max_log_file_action = ROTATE
space_left_action = email
admin_space_left_action = single
```

### 8.3 Forward log ke pusat

Saat Loki sudah ada, kirim `auth.log`, `syslog`, `audit.log`, dan
`/var/log/kubernetes/audit.log` (node k8s) lewat Grafana Alloy. Sampai itu siap,
minimal:

```bash
# rsyslog ke collector
sudo tee /etc/rsyslog.d/50-remote.conf >/dev/null <<'EOF'
*.* @@log-collector.gatezero.lab:6514
EOF
```

> Log lokal bisa dihapus penyerang setelah masuk. Log terpusat tidak.

---

## 9. Lapis 7 — integritas file

```bash
sudo apt install -y aide aide-common

# baseline pertama (butuh beberapa menit)
sudo aideinit
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

`/etc/cron.daily/aide-check`:

```bash
#!/bin/sh
set -eu
/usr/bin/aide --check --config /etc/aide/aide.conf > /var/log/aide/check-$(date +%F).log 2>&1 || true
# kirim ringkasan ke log pusat
grep -E 'added|removed|changed' /var/log/aide/check-$(date +%F).log | head -50 \
  | logger -t aide -p auth.warning
```

```bash
sudo chmod 700 /etc/cron.daily/aide-check
```

**Penting:** simpan salinan `aide.db` di luar VM (S3/offline). Kalau penyerang bisa
mengubah database AIDE, hasil check menjadi tidak berarti.

Kurangi noise dengan mengecualikan path yang memang berubah:

```
# /etc/aide/aide.conf.d/99-gatezero.conf
!/var/log
!/var/lib/containerd
!/var/lib/kubelet
!/var/lib/etcd
!/var/lib/prometheus
!/var/cache
!/tmp
```

---

## 10. Lapis 8 — jaringan (nftables)

`/etc/nftables.conf`:

```nftables
#!/usr/sbin/nft -f
flush ruleset

define ADMIN = { 10.10.20.5, 10.10.20.6 }

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iif lo accept
    ct state established,related accept
    ct state invalid drop

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    # SSH hanya dari jumpbox
    tcp dport 22 ip saddr $ADMIN accept

    # --- tambahkan port per peran VM ---
    # tcp dport { 80, 443 } accept
    # tcp dport { 8081, 8082, 8083, 8084 } ip saddr 10.10.20.0/24 accept

    counter drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
```

```bash
sudo nft -c -f /etc/nftables.conf      # cek sintaks
sudo systemctl enable --now nftables
sudo nft list ruleset
```

### ⚠️ Node Kubernetes: jangan pakai `policy drop` buta

Node k8s butuh port dari [port matrix](../../platform/bootstrap/kubeadm/INSTALL.md#3-prasyarat-infrastruktur):
6443, 2379–2380, 10250, 8472/UDP, 4240, dst. Dan **jangan** memasang `ufw` bersamaan
dengan Cilium — keduanya mengelola iptables/eBPF dan akan berebut.

| VM | Firewall |
|---|---|
| non-k8s | nftables `policy drop` + allowlist |
| node k8s | nftables khusus management plane + **NetworkPolicy Cilium** untuk trafik pod |

---

## 11. Lapis 9 — waktu

```bash
sudo systemctl enable --now chrony
chronyc tracking | grep -E 'Leap|System time|Last offset'
```

Target: `Leap status : Normal`, offset < 100 ms.

> Clock drift merusak TLS, sertifikat, JWT, dan etcd. Satu VM dengan waktu salah bisa
> membuat debugging berjam-jam karena log tidak sinkron dengan VM lain.

---

## 12. Verifikasi

```bash
# --- SSH ---
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|allowtcpforwarding)'

# --- sysctl ---
sysctl kernel.kptr_restrict kernel.dmesg_restrict fs.protected_hardlinks \
       net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter

# --- module ---
lsmod | grep -E 'dccp|sctp|rds|tipc' || echo "OK: module berbahaya tidak loaded"

# --- mount ---
findmnt -no TARGET,OPTIONS /tmp /var/tmp /dev/shm

# --- layanan ---
sudo ss -tulpn | grep -E ':(21|23|25|111|631|5353)\b' || echo "OK: tidak ada port berbahaya"

# --- audit ---
sudo auditctl -s
sudo auditctl -l | wc -l          # harus > 10

# --- integritas ---
sudo ls -l /var/lib/aide/aide.db

# --- waktu ---
chronyc tracking | grep 'Leap status'

# --- firewall ---
sudo nft list ruleset | head -20
```

Lalu ukur dengan CIS benchmark: [`CIS-BENCHMARK.md`](CIS-BENCHMARK.md).

---

## 13. Rollback

Hardening bisa memutus akses. Siapkan jalur mundur **sebelum** menerapkan:

| Risiko | Pencegahan | Rollback |
|---|---|---|
| SSH terkunci | jangan tutup sesi lama; uji `sshd -T` | akses console via Prism |
| nftables memblokir | `nft -c -f` dulu, terapkan via systemd | `nft flush ruleset` dari console |
| sysctl merusak app | uji per peran VM | hapus file di `/etc/sysctl.d/`, `sysctl --system` |
| module blacklist | uji dulu | hapus baris, `update-initramfs -u`, reboot |
| journald hilang log | set cap, bukan delete | `systemctl restart systemd-journald` |
| AIDE noise | exclude path yang berubah | edit `aide.conf.d` |

**Aturan:** selalu punya satu sesi SSH yang tetap terbuka sampai verifikasi lulus.

---

## 14. Yang tidak boleh dilakukan

| ❌ | Kenapa |
|---|---|
| `usg fix cis_level2_server` di node yang sudah jalan | mematikan layanan & sysctl yang dibutuhkan cluster |
| Menutup password auth sebelum SSH key teruji | terkunci di luar, butuh console |
| `noexec` di `/tmp` pada worker runner | build CI gagal dengan error aneh |
| `kernel.modules_disabled=1` | CNI tidak bisa load module saat runtime |
| Auto-reboot patch otomatis | node mati kapan saja, di luar maintenance window |
| `chmod -R 700 /` "biar aman" | merusak ribuan permission yang sah |
| Menghapus `snapd` setelah ada paket snap terpasang | paket jadi yatim |
| Menyalin config hardening antar distro | path & nama paket berbeda (`apt` vs `dnf`) |
| Mengejar skor CIS 100% | 15–20% kontrol memang harus dikecualikan |

---

## 15. Roadmap

| Item | Status | Catatan |
|---|---|---|
| Role Ansible `infra/vm/ansible` | ⬜ | konversi dokumen ini jadi kode |
| SSH CA (step-ca) | ⬜ | ganti static `authorized_keys` dengan sertifikat short-lived |
| Wazuh / osquery agent | ⬜ | deteksi perubahan & FIM realtime |
| Tailscale/Cloudflare Tunnel | ⬜ | hapus kebutuhan SSH inbound |
| Central log (Alloy → Loki) | ⬜ | setelah fase observability |
| Dashboard hardening index | ⬜ | lihat `CIS-BENCHMARK.md` §7 |

---

## Lampiran — urutan eksekusi ringkas

```bash
# 1. provisioning (cloud-init) + regenerate machine-id & host key
# 2. paket dasar + patch
# 3. identitas & akses   -> Lapis 1
# 4. sysctl              -> Lapis 3
# 5. filesystem          -> Lapis 4
# 6. minimalisasi        -> Lapis 5
# 7. logging & audit     -> Lapis 6
# 8. integritas          -> Lapis 7
# 9. firewall            -> Lapis 8
# 10. verifikasi         -> Lapis 12
# 11. benchmark          -> CIS-BENCHMARK.md
```

Rollout: **satu VM jenis non-kritis dulu** (jumpbox), ukur dampaknya, lalu VM layanan,
terakhir node Kubernetes satu per satu.
