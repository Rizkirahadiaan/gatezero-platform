# Runbook — Restore etcd

| | |
|---|---|
| **Kapan dipakai** | etcd korup, quorum hilang, satu member mati permanen, atau rollback data |
| **Dampak bila salah** | kehilangan seluruh state cluster (bukan hanya aplikasi) |
| **RTO target** | < 30 menit untuk skenario A, < 60 menit untuk skenario B |
| **Terakhir diuji** | ⬜ belum — catat tanggal & durasi setelah drill pertama |

---

## 0. Tiga skenario yang berbeda (jangan dicampur)

| Skenario | Kondisi | Cara | Downtime |
|---|---|---|---|
| **A** | 1 member rusak, **quorum sehat** (2/3 hidup) | `member remove` + `member add` — **tanpa** restore snapshot | hampir nol |
| **B** | Quorum hilang / semua member mati | restore snapshot di **semua** member | penuh (~cluster mati) |
| **C** | Data logis rusak (secret terhapus) | restore ke cluster uji, ambil objek, apply selektif | nol untuk cluster utama |

> Kesalahan paling umum: memakai restore snapshot untuk kasus A. Itu memaksa
> seluruh cluster turun padahal cukup mengganti satu member.

---

## 1. Prasyarat (cek dulu, jangan skip)

```bash
# 1. snapshot tersedia dan valid
ls -lh /var/backups/etcd/
sudo etcdutl snapshot status /var/backups/etcd/etcd-<stamp>.db -w table

# 2. versi etcd sama dengan cluster (restore lintas versi bermasalah)
kubectl -n kube-system get pod etcd-k8s-cp-01 \
  -o jsonpath='{.spec.containers[0].image}'

# 3. status member saat ini
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.10.20.11:2379,https://10.10.20.12:2379,https://10.10.20.13:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

Prasyarat lain:

- [ ] Akses console Prism (kalau SSH mati)
- [ ] `admin.conf` dari salah satu CP
- [ ] Catat jam mulai — RTO harus terukur, bukan ditebak

---

## 2. Skenario A — satu member rusak, quorum sehat

Contoh: `k8s-cp-03` disk-nya mati, `k8s-cp-01` & `k8s-cp-02` sehat.

### 2.1 Identifikasi member

```bash
sudo ETCDCTL_API=3 etcdctl ... member list -w table
# cari baris k8s-cp-03, catat ID dan peer URL
```

### 2.2 Hapus member dari cluster (dari CP sehat)

```bash
sudo ETCDCTL_API=3 etcdctl ... member remove <MEMBER_ID>

# verifikasi: harus tinggal 2 member
sudo ETCDCTL_API=3 etcdctl ... member list -w table
```

### 2.3 Daftarkan ulang sebagai member baru

```bash
sudo ETCDCTL_API=3 etcdctl ... member add k8s-cp-03 \
  --peer-urls=https://10.10.20.13:2380
```

### 2.4 Bersihkan data lama di node rusak

```bash
# di k8s-cp-03
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak   # stop etcd
sudo rm -rf /var/lib/etcd/*                                       # WAJIB kosong
```

### 2.5 Pastikan manifest memakai state `existing`

kubeadm menulis `--initial-cluster-state=new` untuk bootstrap awal. Member yang
join ulang harus `existing` dan `--initial-cluster` memuat **semua** member.

```bash
grep -nE 'initial-cluster|initial-cluster-state' /root/etcd.yaml.bak
```

Kalau masih `new` atau daftar member tidak lengkap, perbaiki:

```bash
sudo sed -i \
  -e 's#--initial-cluster-state=new#--initial-cluster-state=existing#' \
  -e 's#--initial-cluster=[^"]*#--initial-cluster=k8s-cp-01=https://10.10.20.11:2380,k8s-cp-02=https://10.10.20.12:2380,k8s-cp-03=https://10.10.20.13:2380#' \
  /root/etcd.yaml.bak
```

### 2.6 Jalankan kembali etcd

```bash
sudo mv /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
sudo systemctl restart kubelet

# tunggu ~30-60 detik, lalu verifikasi dari CP lain
sudo ETCDCTL_API=3 etcdctl ... endpoint health -w table
```

---

## 3. Skenario B — quorum hilang, restore penuh

> Langkah ini harus dijalankan **di ketiga control plane**, hampir bersamaan.

### 3.1 Hentikan etcd di semua CP

```bash
# di SETIAP CP (01, 02, 03)
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
sleep 20
sudo crictl ps | grep etcd || echo "etcd berhenti"
```

### 3.2 Pilih snapshot

```bash
SNAP=$(ls -t /var/backups/etcd/etcd-*.db | head -1)
sudo etcdutl snapshot status "$SNAP" -w table
```

### 3.3 Restore di setiap member

**Penting:** gunakan token yang sama dengan kubeadm default (`etcd-cluster`) supaya
manifest tidak perlu diubah selain `--data-dir`.

```bash
# di k8s-cp-01
sudo etcdutl snapshot restore "$SNAP" \
  --name k8s-cp-01 \
  --initial-cluster "k8s-cp-01=https://10.10.20.11:2380,k8s-cp-02=https://10.10.20.12:2380,k8s-cp-03=https://10.10.20.13:2380" \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls https://10.10.20.11:2380 \
  --data-dir /var/lib/etcd-restore
```

Ulangi di `k8s-cp-02` dan `k8s-cp-03` dengan `--name` dan IP masing-masing.

### 3.4 Tukar data dir

```bash
# di setiap CP
sudo mv /var/lib/etcd /var/lib/etcd.broken-$(date +%s)   # simpan, jangan hapus dulu
sudo mv /var/lib/etcd-restore /var/lib/etcd
sudo chown -R root:root /var/lib/etcd && sudo chmod 700 /var/lib/etcd
```

### 3.5 Jalankan kembali (satu per satu)

```bash
# CP-01 dulu
sudo mv /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
sudo systemctl restart kubelet
# tunggu sampai apiserver lokal melayani
sudo crictl ps | grep etcd

# baru CP-02, lalu CP-03
```

### 3.6 Verifikasi

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.10.20.11:2379,https://10.10.20.12:2379,https://10.10.20.13:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health -w table
```

Harus **3/3 healthy** sebelum lanjut.

### 3.7 Pulihkan cluster

```bash
kubectl get nodes
kubectl -n kube-system get pods
```

Node mungkin `NotReady` sementara; kubelet akan menyambung ulang. Tunggu 2–5 menit.
**Jangan** drain/reset node sebelum kubelet benar-benar gagal.

---

## 4. Skenario C — ambil objek tertentu tanpa mengganggu cluster

Untuk kasus "secret terhapus kemarin", bukan korupsi etcd.

```bash
# 1. restore ke data dir terpisah di VM uji
sudo etcdutl snapshot restore snap.db --data-dir /tmp/etcd-test \
  --name restore --initial-cluster restore=http://127.0.0.1:2380 \
  --initial-advertise-peer-urls http://127.0.0.1:2380

# 2. jalankan etcd sementara (tanpa TLS, hanya localhost)
sudo etcd --data-dir /tmp/etcd-test \
  --listen-client-urls http://127.0.0.1:12379 \
  --advertise-client-urls http://127.0.0.1:12379 &

# 3. baca objek (nilai base64)
ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:12379 \
  get /registry/secrets/apps-prod/demo-api-db

# 4. decode, lalu apply ke cluster hidup sebagai manifest baru
# 5. matikan etcd sementara, hapus /tmp/etcd-test
```

> Ini teknik bedah, bukan prosedur rutin. Untuk kasus rumit, restore ke cluster uji
> penuh lalu `kubectl get -o yaml` lebih aman daripada membaca etcd mentah.

---

## 5. Verifikasi akhir

```bash
kubectl get --raw /healthz
kubectl get nodes -o wide
sudo kubeadm certs check-expiration | head -5
kubectl -n kube-system get pods | grep -v Running
```

Semua harus bersih. Kalau ada pod `CrashLoopBackOff`, **jangan** langsung restart
semua — cek log satu per satu dulu; biasanya butuh 1–2 menit untuk settle.

---

## 6. Rollback

| Situasi | Tindakan |
|---|---|
| Restore berhasil tapi data salah | hentikan semua etcd, kembalikan `/var/lib/etcd.broken-*` → `/var/lib/etcd`, start ulang |
| Cluster tetap tidak sehat | restore snapshot **lebih lama** (sebelum insiden) |
| Tidak ada snapshot valid | 🚨 kehilangan state cluster — bangun ulang, aplikasi di-redeploy dari Git (ini alasan GitOps penting) |

Simpan `/var/lib/etcd.broken-*` minimal 24 jam sebelum dihapus.

---

## 7. Catat hasil drill

Isi setelah setiap latihan (bukan hanya insiden nyata):

| Tanggal | Skenario | Snapshot dipakai | Mulai | Selesai | RTO | Catatan |
|---|---|---|---|---|---|---|
| | | | | | | |

Target: RTO skenario A < 30 menit, B < 60 menit. Kalau lebih, perbaiki
prosedurnya — bukan targetnya.
