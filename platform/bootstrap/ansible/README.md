# Ansible — bootstrap cluster Kubernetes (kubeadm)

Otomasi dari [`../kubeadm/INSTALL.md`](../kubeadm/INSTALL.md). Tujuannya bukan menggantikan
dokumen itu, tapi **membuatnya bisa dijalankan ulang tanpa salah ketik**.

> Dokumen manual = penjelasan *kenapa*.
> Ansible = eksekusi *apa*.
> Kalau keduanya berbeda, dokumen manual yang benar.

---

## 1. Yang diotomasi vs yang tidak

| Diotomasi | Tidak (sengaja) |
|---|---|
| sysctl, module, swap, chrony, ulimit | pembuatan VM di Prism |
| vDisk etcd (format + mount via LABEL) | record DNS (`k8s-api…`) |
| containerd + `SystemdCgroup` + verifikasi | token Cloudflare (harus via SOPS manual) |
| repo & paket k8s (pin + hold) | Nutanix CSI driver (butuh kredensial Prism) |
| kube-vip static pod | ArgoCD bootstrap (`platform/gitops`) |
| `kubeadm init` + join CP/worker | hardening CIS OS (`infra/vm`) |
| Cilium, Gateway API, cert-manager, metrics-server | penentuan MTU (harus diukur) |
| label PSA, approve CSR, `kubeadm-certs` cleanup | kube-bench (dijalankan terpisah) |
| verifikasi 10 poin | |

---

## 2. Prasyarat di controller (laptop/jumpbox)

> ⚠️ **Ansible tidak bisa dijalankan dari PowerShell Windows native.**
> Jalankan dari jumpbox Linux (VM Ubuntu yang sudah ada) atau WSL2.
> Inventory & repo bisa tetap diakses dari Windows.

```bash
# ansible-core >= 2.16
python3 -m pip install --user "ansible-core>=2.16"

# koleksi
ansible-galaxy collection install -r requirements.yml

# tool pendukung
#   sops + age  (wajib: secret dibaca dari SOPS)
#   ssh key ke semua node dengan sudo NOPASSWD
```

Cek konektivitas sebelum apa pun:

```bash
ansible -i inventory/hosts.yml k8s_cluster -m ping
ansible -i inventory/hosts.yml k8s_cluster -m command -a 'lsblk -o NAME,SIZE,MOUNTPOINT' -b
```

---

## 3. Secret (jangan pernah plaintext)

Dua nilai rahasia dibutuhkan **sebelum** cluster ada:

| Variable | Dibuat dengan | Dipakai untuk |
|---|---|---|
| `K8S_CERT_KEY` | `kubeadm certs certificate-key` (64 hex) | upload certs, join CP |
| `K8S_ENCRYPTION_KEY` | `head -c 32 /dev/urandom \| base64` | encryption-at-rest etcd |

```bash
cp secrets.env.example secrets.env
# isi dua nilai di atas
sops -e secrets.env > secrets.env.enc
rm -f secrets.env
```

**Kenapa env var, bukan Ansible Vault?**
`K8S_CERT_KEY` juga dibutuhkan oleh `kubeadm init` di mesin yang belum punya Ansible.
Satu mekanisme (SOPS) untuk semua jalur lebih sedikit daripada dua.

> `K8S_ENCRYPTION_KEY` **wajib** disimpan juga di tempat offline.
> Kalau hilang, semua Secret di etcd tidak bisa dibaca dan tidak ada recovery.

---

## 4. Menjalankan

> Panduan langkah demi langkah lengkap (termasuk output yang diharapkan per tahap,
> troubleshooting, dan cara publish ke Ansible Galaxy):
> **➡️ [`RUNBOOK.md`](RUNBOOK.md)**

### Sekali jalan (production path)

```bash
./run.sh site.yml
```

### Bertahap (disarankan saat pertama kali)

```bash
./run.sh playbooks/00-preflight.yml
./run.sh playbooks/10-baseline.yml
./run.sh playbooks/20-etcd-disk.yml
./run.sh playbooks/30-containerd.yml
./run.sh playbooks/40-kubernetes.yml
./run.sh playbooks/50-kube-vip.yml
./run.sh playbooks/60-init.yml
./run.sh playbooks/70-join.yml
./run.sh playbooks/80-addons.yml
./run.sh playbooks/90-verify.yml
```

Penting: `70-join.yml` butuh `set_fact` dari `60-init.yml`, jadi **harus satu run** kalau
dijalankan bertahap — atau pakai `site.yml`. Kalau ingin memisah, simpan token ke SOPS
dan tambahkan `--extra-vars` (lihat bagian 7).

### Yang aman diulang

Semua play idempoten. Yang **tidak** idempoten dan perlu diketahui:

| Task | Perilaku saat run kedua |
|---|---|
| `kubeadm init` | dilewati (dijaga keberadaan `admin.conf`) |
| `kubeadm join` | dilewati (dijaga keberadaan `kubelet.conf`) |
| `kubeadm token create` | membuat token baru tiap run (TTL 1 jam, aman) |
| format vDisk etcd | dilewati; **gagal** kalau label berbeda (by design) |

---

## 5. Peta role

| Role | Hosts | Tanggung jawab | Handler |
|---|---|---|---|
| `common` | semua | paket, chrony, swap, module, sysctl, ulimit | restart chrony, reload sysctl |
| `etcd_disk` | control plane | format + mount vDisk via `LABEL=` | — |
| `containerd` | semua | repo Docker, config default, SystemdCgroup, pause image | restart containerd |
| `kubernetes` | semua | repo k8s, pin versi, `apt-mark hold` | — |
| `kubevip` | control plane | static pod kube-vip | — |
| `kubeadm` | CP primer | audit policy, encryption config, init, RBAC, token | — |
| `kubeadm_join` | CP sekunder + worker | join + kubeconfig | — |
| `cilium` | CP primer | Helm Cilium, cek kube-proxy absen | — |
| `addons` | CP primer | Gateway API, cert-manager, metrics-server, PSA, CSR, cleanup | — |
| `verify` | CP primer | 10 assertion read-only | — |

---

## 6. Pengamanan yang ada di dalam role

Bukan hanya "copy perintah dari runbook":

| Pengamanan | Di mana | Kenapa |
|---|---|---|
| Tolak format disk yang sudah berisi data | `etcd_disk` | mencegah kehilangan data karena salah `etcd_device` |
| Tolak `etcd_device` di disk yang sama dengan `/` | `etcd_disk` | mencegah OS terhapus |
| Mount pakai `LABEL=`, bukan `/dev/sdX` | `etcd_disk` | urutan device Nutanix bisa berubah saat reboot |
| Deteksi config containerd v2 vs v3 | `containerd` | key `sandbox_image` pindah ke `sandbox` di containerd 2.x |
| Verifikasi `SystemdCgroup = true` benar-benar ada | `containerd` | kesalahan paling umum, gagal senyap |
| Tolak kalau versi paket tidak ada di repo | `kubernetes` | pesan jelas, bukan error apt yang samar |
| `--certificate-key` lewat file config, bukan CLI | `kubeadm` | tidak muncul di `ps` / log |
| `no_log` untuk token & key | `kubeadm`, `kubeadm_join` | tidak bocor ke log CI |
| Assert 3/3 etcd healthy | `verify` | jangan serahkan cluster setengah jadi |
| Cek CIDR tidak overlap | `verify` | sumber bug jaringan paling sulit dilacak |

---

## 7. Kalau ingin memisahkan init dan join

`set_fact` hilang antar run. Untuk run terpisah, simpan ke SOPS:

```bash
# setelah 60-init.yml
TOKEN=$(ssh root@10.10.20.11 kubeadm token create --ttl 24h)
HASH=$(ssh root@10.10.20.11 "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -hex | sed 's/^.* //'")

cat > /tmp/join.yaml <<EOF
kubeadm_join_token: "${TOKEN}"
kubeadm_ca_hash: "sha256:${HASH}"
EOF
sops -e /tmp/join.yaml > join-data.enc.yaml && rm -f /tmp/join.yaml
```

Lalu jalankan join dengan `-e @<(sops -d join-data.enc.yaml)`.

---

## 8. Verifikasi mandiri

```bash
ansible-playbook site.yml --syntax-check
ansible-lint            # opsional, butuh ansible-lint
```

`--check` (dry-run) **tidak** bisa diandalkan untuk seluruh playbook ini: `kubeadm`
dan `helm` tidak mendukung check mode, dan `etcd_disk` butuh filesystem nyata.
Gunakan `--check` hanya untuk `10-baseline.yml`.

---

## 9. Troubleshooting

| Gejala | Sebab | Perbaikan |
|---|---|---|
| `K8S_CERT_KEY ... belum terisi` | dipanggil `ansible-playbook` langsung | pakai `./run.sh` |
| `Data join tidak ditemukan` | `70-join.yml` dijalankan terpisah | jalankan `site.yml`, atau simpan token (bagian 7) |
| `Versi X tidak tersedia di repo` | `k8s_pkg_version` salah | `apt-cache madison kubeadm` di node, sesuaikan |
| `Tolak device yang sudah berisi filesystem` | `etcd_device` menunjuk disk data | periksa `lsblk`, jangan paksa |
| containerd restart terus | config.toml tidak valid | `journalctl -u containerd -n 50` |
| Cilium helm timeout | VIP belum hidup / MTU salah | cek `crictl ps \| grep kube-vip` |
| `metrics-server` gagal | CSR kubelet belum approve | role `addons` sudah mencoba; cek `kubectl get csr` |

---

## 10. Struktur

```
ansible/
├── ansible.cfg
├── requirements.yml
├── site.yml
├── run.sh                  # wrapper sops exec-env
├── secrets.env.example
├── inventory/
│   ├── hosts.yml
│   └── group_vars/all/main.yml     <- SATU sumber kebenaran
├── playbooks/00..90
└── roles/{common,etcd_disk,containerd,kubernetes,kubevip,kubeadm,kubeadm_join,cilium,addons,verify}
```
