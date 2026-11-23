# Runbook — Upgrade Node

| | |
|---|---|
| **Kapan dipakai** | patch OS, patch kubelet, upgrade minor Kubernetes |
| **Dampak** | node keluar dari layanan sementara; **tidak boleh** dua node sekaligus |
| **Window** | di luar jam sibuk; satu node per langkah |
| **Terakhir diuji** | ⬜ belum |

---

## 0. Aturan yang tidak boleh dilanggar

| Aturan | Alasan |
|---|---|
| **Satu node per waktu** | dua node mati bersamaan bisa menghilangkan quorum |
| **Control plane dulu, worker belakangan** | apiserver harus versi ≥ kubelet |
| **Tidak boleh lompat minor** (1.34 → 1.35, bukan 1.33 → 1.35) | kubeadm menolak, dan skew tidak didukung |
| **Snapshot etcd sebelum mulai** | tidak ada downgrade; rollback = restore |
| **`apt-mark hold` dilepas hanya saat upgrade** | kalau tidak, paket ikut naik tanpa kendali |
| **Cek PDB sebelum drain** | drain bisa menggantung selamanya |

### Version skew yang diizinkan

| Komponen | Boleh lebih rendah dari apiserver |
|---|---|
| kubelet | 3 minor |
| kube-proxy | 3 minor (tidak dipakai — Cilium) |
| kubectl | 1 minor |

---

## 1. Pra-penerbangan (15 menit sebelum window)

```bash
# 1. catat versi sekarang
kubectl version -o json | jq -r '.serverVersion.gitVersion'
kubectl get nodes -o wide

# 2. semua node sehat?
kubectl get nodes | grep -v ' Ready' && echo "ADA NODE TIDAK READY — STOP"

# 3. tidak ada pod kube-system bermasalah
kubectl -n kube-system get pods | grep -vE 'Running|Completed'

# 4. snapshot etcd (wajib)
sudo /usr/local/bin/etcd-backup.sh
ls -lh /var/backups/etcd/ | tail -2

# 5. PDB tidak akan memblokir drain
kubectl get pdb -A

# 6. cek paket tersedia
apt-cache madison kubeadm | head -5
```

Checklist:

- [ ] Snapshot etcd dibuat dan diverifikasi (`etcdutl snapshot status`)
- [ ] Versi target tersedia di repo `pkgs.k8s.io`
- [ ] Tidak ada alert aktif
- [ ] Maintenance window diumumkan
- [ ] Akses console Prism siap

---

## 2. Rencana upgrade

```bash
sudo kubeadm upgrade plan
```

Output harus mencantumkan versi target. Kalau muncul `[ERROR]`, hentikan dan perbaiki
dulu — jangan dipaksa dengan `--force`.

---

## 3. Upgrade control plane pertama (`k8s-cp-01`)

### 3.1 Naikkan kubeadm

```bash
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.34.5-1.1    # sesuaikan versi
sudo apt-mark hold kubeadm
kubeadm version -o short
```

### 3.2 Apply

```bash
sudo kubeadm upgrade apply v1.34.5
```

Tunggu hingga muncul `SUCCESS! Your cluster was upgraded to "v1.34.5"`.

### 3.3 Drain & upgrade kubelet

```bash
kubectl drain k8s-cp-01 --ignore-daemonsets --delete-emptydir-data --timeout=300s

sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.5-1.1 kubectl=1.34.5-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

kubectl uncordon k8s-cp-01
kubectl get nodes
```

### 3.4 Verifikasi sebelum lanjut

```bash
kubectl get nodes -o wide          # k8s-cp-01 Ready, versi baru
kubectl -n kube-system get pods    # semua Running
sudo ETCDCTL_API=3 etcdctl ... endpoint health -w table   # 3/3
```

**Jangan lanjut ke CP berikutnya kalau ini belum bersih.**

---

## 4. Upgrade control plane kedua & ketiga

Sama, tapi perintah intinya `kubeadm upgrade node` (bukan `apply`):

```bash
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.34.5-1.1
sudo apt-mark hold kubeadm

sudo kubeadm upgrade node

kubectl drain k8s-cp-02 --ignore-daemonsets --delete-emptydir-data
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.5-1.1 kubectl=1.34.5-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon k8s-cp-02
```

---

## 5. Upgrade worker

Satu per satu, atau maksimal satu per batch dengan jeda verifikasi.

```bash
kubectl drain k8s-w-01 --ignore-daemonsets --delete-emptydir-data --timeout=300s

# di node
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update && sudo apt-get install -y kubeadm=1.34.5-1.1 kubelet=1.34.5-1.1 kubectl=1.34.5-1.1
sudo apt-mark hold kubeadm kubelet kubectl
sudo kubeadm upgrade node
sudo systemctl daemon-reload && sudo systemctl restart kubelet

kubectl uncordon k8s-w-01
kubectl get pods -A -o wide | grep k8s-w-01    # pastikan workload kembali
```

> `kubeadm upgrade node` di worker tidak mengubah apiserver; ia hanya memperbarui
> konfigurasi kubelet dan image komponen lokal.

---

## 6. Setelah selesai

```bash
kubectl get nodes -o wide                       # semua Ready, versi seragam
kubectl -n kube-system get pods | grep -v Running
sudo kubeadm certs check-expiration
cilium status
kubectl top nodes
```

Checklist penutup:

- [ ] Semua node versi sama
- [ ] Tidak ada pod `Pending`/`CrashLoopBackOff`
- [ ] etcd 3/3 healthy
- [ ] `cilium status` OK
- [ ] `kubectl top nodes` bekerja
- [ ] Snapshot etcd pasca-upgrade dibuat
- [ ] Catat durasi & masalah di tabel bawah

---

## 7. Rollback

**Kubernetes tidak mendukung downgrade.** Pilihan yang realistis:

| Situasi | Tindakan |
|---|---|
| Satu node gagal start | perbaiki node itu, jangan turunkan versi cluster |
| Control plane rusak parah | restore etcd dari snapshot (§`etcd-restore.md` skenario B) + rebuild node |
| Workload rusak karena API deprecated | perbaiki manifest (itu tujuan upgrade) |
| Perlu kembali total | restore snapshot pre-upgrade + rebuild node dengan paket versi lama |

Simpan paket versi lama di cache sebelum upgrade, supaya rebuild lebih cepat:

```bash
sudo apt-get install --download-only -y kubeadm=1.34.3-1.1 kubelet=1.34.3-1.1
ls /var/cache/apt/archives/kube*
```

---

## 8. Masalah yang sering muncul

| Gejala | Sebab | Perbaikan |
|---|---|---|
| `drain` menggantung | PDB memblokir | `kubectl get pdb -A`, sementara `--disable-eviction` (hati-hati) |
| `kubeadm upgrade apply` gagal di preflight | komponen tidak sehat | perbaiki pod dulu |
| kubelet `CrashLoop` setelah upgrade | `config.yaml` tidak kompatibel | `journalctl -u kubelet`, cek field yang dihapus |
| node `NotReady` lama | CNI belum siap / disk penuh | `cilium status`, `df -h` |
| pod tidak kembali ke node | taint `node.kubernetes.io/unschedulable` | pastikan `uncordon` berhasil |
| versi tidak seragam | ada node terlewat | `kubectl get nodes` lalu ulangi node itu |

---

## 9. Catat hasil

| Tanggal | Dari | Ke | Node | Durasi | Masalah | Tindak lanjut |
|---|---|---|---|---|---|---|
| | | | | | | |
