# Runbook — Rotasi Secret

| | |
|---|---|
| **Kapan dipakai** | anggota tim keluar, dugaan kompromi, rotasi berkala, ganti kredensial layanan |
| **Dampak** | kalau urutannya salah: ArgoCD gagal sync, pod gagal start, CI mati |
| **Frekuensi** | keanggotaan (ad-hoc) · berkala 12 bulan · segera saat dugaan bocor |
| **Terakhir diuji** | ⬜ belum |

---

## 0. Peta secret & tingkat risiko

| Secret | Disimpan di | Dampak bila bocor | Rotasi |
|---|---|---|---|
| age root key | offline (password manager) | **semua** secret bootstrap | 12 bulan / saat insiden |
| age cluster key | Secret `sops-age` di ns `argocd` | semua secret GitOps | 12 bulan |
| age CI key | OpenBao / CI variable protected | dekripsi di pipeline | 6–12 bulan |
| age team key | tiap engineer | secret dev/staging | saat anggota keluar |
| etcd encryption key | `/etc/kubernetes/enc/` + salinan SOPS | seluruh Secret di etcd | 12 bulan |
| kredensial DB | Secret SOPS | data aplikasi | 6 bulan |
| Nexus/registry token | Secret SOPS | push image jahat | 6 bulan |
| GitLab runner token | Secret SOPS | eksekusi job | saat mencurigakan |

---

## 1. Dua operasi berbeda — jangan tertukar

| Operasi | Yang berubah | Kapan dipakai |
|---|---|---|
| `sops updatekeys <file>` | **hanya** pembungkusan data key ke recipient baru. Nilai ciphertext tidak berubah. | anggota tim masuk/keluar |
| `sops rotate -i <file>` | **data key baru**, seluruh nilai dienkripsi ulang. | dugaan kompromi |

> Menggunakan `updatekeys` saat key sudah bocor **tidak** membantu: penyerang masih
> memegang data key lama dan bisa mendekripsi semua versi lama yang ada di git history.

---

## 2. Skenario A — anggota tim keluar

Tujuan: dia tidak bisa lagi mendekripsi secret baru.

```bash
# 1. hapus public key-nya dari creation_rules
$EDITOR platform/gitops/.sops.yaml
#    (hapus age1...milik-dia dari daftar `age:`)

# 2. bungkus ulang data key untuk recipient yang tersisa
cd platform/gitops
sops updatekeys -y overlays/dev/*.enc.yaml
sops updatekeys -y overlays/staging/*.enc.yaml
sops updatekeys -y overlays/prod/*.enc.yaml

# 3. commit
git add .sops.yaml overlays
git commit -m "security(sops): cabut akses <nama> dari secret dev/staging/prod"
```

**Penting:** langkah ini **tidak** mengubah data key. Karena dia pernah memegang data
key lama, dia masih bisa mendekripsi **semua versi lama di git history**.

Kalau itu tidak dapat diterima (dia punya akses produksi), lanjut ke Skenario B.

Verifikasi:

```bash
git log --oneline -3
# jalankan sebagai dirinya (kalau masih punya key) -> harus gagal
sops -d overlays/dev/demo-api-db.enc.yaml   # expect: error "no identity matched"
```

---

## 3. Skenario B — dugaan kompromi (rotasi penuh)

```bash
# 1. generate key baru
age-keygen -o ~/.config/sops/age/team-new.txt
age-keygen -y ~/.config/sops/age/team-new.txt    # public key baru

# 2. ganti recipient di .sops.yaml (key baru + key yang masih dipercaya)
#    key lama TIDAK dimasukkan

# 3. rotasi data key + enkripsi ulang nilai
cd platform/gitops
sops rotate -i overlays/prod/demo-api-db.enc.yaml
sops rotate -i overlays/prod/nexus-pull.enc.yaml
# ... semua file yang terdampak

# 4. commit
git add .sops.yaml overlays
git commit -m "security(sops): rotasi data key prod pasca dugaan kompromi"
```

**Urutan aman untuk cluster (penting):**

```
1. tambahkan key BARU sebagai recipient (key lama masih ada)   -> tidak ada downtime
2. deploy key baru ke ArgoCD (Secret sops-age berisi keduanya)
3. verifikasi ArgoCD bisa decrypt semua file
4. baru hapus key lama dari .sops.yaml + updatekeys + rotate
5. hapus key lama dari Secret sops-age
```

Kalau langkah 4 dilakukan sebelum 2, ArgoCD kehilangan kemampuan dekripsi dan
seluruh aplikasi berhenti sync.

---

## 4. Rotasi key cluster (ArgoCD)

```bash
# lihat isi Secret saat ini
kubectl -n argocd get secret sops-age -o jsonpath='{.data.keys\.txt}' | base64 -d
```

`sops-age` boleh berisi **lebih dari satu** private key (dipisah newline). Saat
transisi, isi dua key: baru + lama. CMP plugin akan mencoba keduanya.

Transisi dua key (aman):

```bash
# tulis file berisi key lama + key baru
cat "$OLD_KEY_FILE" "$NEW_KEY_FILE" > /tmp/age-keys.txt

kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/tmp/age-keys.txt \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd rollout restart deploy/argocd-repo-server
shred -u /tmp/age-keys.txt
```

Verifikasi:

```bash
kubectl -n argocd logs deploy/argocd-repo-server | grep -i -E 'sops|decrypt' | tail
argocd app get <app> --refresh        # harus Synced, bukan ComparisonError
```

---

## 5. Rotasi key CI

1. Generate key baru di OpenBao (atau CI variable protected).
2. Tambahkan sebagai recipient di `.sops.yaml` **bersamaan** dengan key lama.
3. Jalankan pipeline sekali — pastikan decrypt berhasil.
4. Hapus key lama dari `.sops.yaml`, `updatekeys`, lalu hapus dari OpenBao.

> Jangan pernah menyimpan private key CI sebagai CI variable biasa (masked pun bisa
> bocor di artifact/log). Pakai `secrets:vault` (OIDC), bukan `variables`.

---

## 6. Rotasi encryption-at-rest etcd

Ini yang paling berisiko: salah urutan = Secret tidak terbaca.

```bash
# 1. key baru
NEW=$(head -c 32 /dev/urandom | base64)

# 2. taruh key BARU di urutan PERTAMA, key lama tetap ada
sudo tee /etc/kubernetes/enc/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets", "configmaps"]
    providers:
      - aescbc:
          keys:
            - name: key2          # baru -> dipakai untuk ENKRIPSI
              secret: ${NEW}
            - name: key1          # lama -> masih dipakai untuk DEKRIPSI
      - identity: {}
EOF
```

```bash
# 3. restart apiserver SATU PER SATU (static pod)
#    jika --encryption-provider-config-automatic-reload=true, cukup tunggu
sudo crictl ps | grep kube-apiserver
sudo systemctl restart kubelet      # hanya jika reload otomatis tidak aktif
```

```bash
# 4. tulis ulang SEMUA secret agar terenkripsi dengan key2
kubectl get secrets -A -o json | kubectl replace -f -
```

```bash
# 5. verifikasi: harus muncul key2
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/kube-system/kubeadm-config | head -c 120
# harapan: k8s:enc:aescbc:v1:key2
```

```bash
# 6. baru hapus key1, restart apiserver lagi (satu per satu)
# 7. simpan NEW ke SOPS + salinan offline
```

**Rollback:** selama key1 masih ada di daftar provider, semua Secret lama tetap bisa
dibaca. Jangan hapus key1 sampai langkah 5 benar-benar lulus di semua CP.

---

## 7. Rotasi kredensial layanan

### Database

```bash
# 1. ubah password di Postgres
kubectl -n apps-prod exec deploy/postgres -- \
  psql -U postgres -c "ALTER ROLE demo WITH PASSWORD '<baru>';"

# 2. perbarui Secret (SOPS)
sops platform/gitops/overlays/prod/demo-api-db.enc.yaml
git commit -am "security(db): rotasi password demo-api"

# 3. ArgoCD sync -> pod restart dengan credential baru
```

### Nexus / registry

1. Buat token baru di Nexus.
2. Update Secret `nexus-pull` (SOPS).
3. Validasi: `docker pull` dari jumpbox dengan credential baru **sebelum** mencabut yang lama.
4. Cabut token lama di Nexus.

### GitLab runner

```bash
# 1. buat runner baru di UI/API -> dapat token glrt-
# 2. update Secret
sops platform/gitops/overlays/prod/gitlab-runner.enc.yaml
# 3. sync, tunggu runner online
# 4. hapus runner lama di UI
```

---

## 8. Verifikasi akhir

```bash
# semua pipeline hijau
# semua ArgoCD app Synced (bukan ComparisonError)
argocd app list -o wide | grep -v Synced

# tidak ada pod yang gagal karena credential
kubectl get pods -A | grep -E 'CrashLoop|ImagePullBackOff'

# etcd memakai key yang benar
sudo ETCDCTL_API=3 etcdctl ... get /registry/secrets/kube-system/kubeadm-config | head -c 60

# grep tidak menemukan plaintext
gitleaks detect --no-banner --redact
```

---

## 9. Rollback

| Situasi | Tindakan |
|---|---|
| ArgoCD gagal decrypt setelah rotasi | kembalikan key lama ke Secret `sops-age` (selama masih ada), restart repo-server |
| Secret tidak terbaca setelah rotasi etcd | kembalikan `encryption-config.yaml` dengan key1 di urutan pertama, restart apiserver |
| Password DB baru salah | kembalikan password lama **sebelum** mencabutnya — karena itu jangan cabut dulu |
| Pipeline gagal decrypt | kembalikan key CI lama, jalankan ulang, baru perbaiki |

Prinsip umum: **selalu ada jendela di mana key lama dan baru aktif bersamaan.**

---

## 10. Catat hasil

| Tanggal | Secret | Alasan | Downtime | Catatan |
|---|---|---|---|---|
| | | | | |
