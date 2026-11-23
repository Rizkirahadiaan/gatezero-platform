# CIS Benchmark — Cara Mengukur Hardening

Dokumen ini menjawab satu pertanyaan: **"seberapa keras VM kita, dan apakah membaik?"**

Bukan sekadar "jalankan tool lalu lihat angka". Tujuannya adalah skor yang bisa
dipertanggungjawabkan, tren yang terlihat, dan remediasi yang menjadi kode.

> Prasyarat: [`HARDENING.md`](HARDENING.md) dan (untuk node) [`HARDENING-K8S.md`](HARDENING-K8S.md)
> sudah diterapkan.

---

## Daftar Isi

1. [Kenapa satu tool tidak cukup](#1-kenapa-satu-tool-tidak-cukup)
2. [Lapis 1 — USG (Ubuntu Security Guide)](#2-lapis-1--usg-ubuntu-security-guide)
3. [Lapis 2 — OpenSCAP + SSG](#3-lapis-2--openscap--ssg)
4. [Lapis 3 — Lynis](#4-lapis-3--lynis)
5. [Lapis 4 — kube-bench](#5-lapis-4--kube-bench)
6. [Lapis 5 — Kubescape](#6-lapis-5--kubescape)
7. [Skor, tren, dashboard](#7-skor-tren-dashboard)
8. [Menafsirkan hasil & alur remediasi](#8-menafsirkan-hasil--alur-remediasi)
9. [Jadwal](#9-jadwal)
10. [Anti-pattern](#10-anti-pattern)
11. [Integrasi CI](#11-integrasi-ci)
12. [Target & kapan berhenti](#12-target--kapan-berhenti)

---

## 1. Kenapa satu tool tidak cukup

| Tool | Mengukur apa | Buta terhadap |
|---|---|---|
| **USG** (Ubuntu) | CIS Ubuntu 24.04, lengkap dengan remediasi | Kubernetes, workload |
| **OpenSCAP + SSG** | XCCDF/OVAL, audit formal, bisa ditailor | Kubernetes |
| **Lynis** | postur OS secara luas, skor 0–100, saran | Kubernetes; lebih "advisor" daripada "compliance" |
| **kube-bench** | CIS Kubernetes (control plane & node) | OS, workload manifest |
| **Kubescape** | posture cluster + framework NSA/MITRE/CIS | konfigurasi OS |
| **Trivy** | CVE paket & image | konfigurasi, policy |

Contoh nyata: node bisa **skor Lynis 92** tapi apiserver masih `anonymous-auth=true`.
Atau **kube-bench 95%** tapi OS masih pakai password SSH. Karena itu semua lapis dipakai.

```
OS      : USG (utama) + OpenSCAP (formal) + Lynis (skor)
Cluster : kube-bench (CIS) + Kubescape (framework)
Workload: Kyverno + kube-linter
CVE     : Trivy
```

---

## 2. Lapis 1 — USG (Ubuntu Security Guide)

Paling relevan untuk CIS Ubuntu 24.04 dan satu-satunya yang menyediakan **remediasi resmi**
dari Canonical.

### 2.1 Install

```bash
sudo apt update
sudo apt install -y usg
usg --help
```

> Kalau paket `usg` tidak ditemukan di mirror-mu, cek `apt search ubuntu-security-guide`.
> Nama paket dan CLI bisa berbeda antar rilis — selalu cek `usg --help` di versimu.

### 2.2 Audit (JANGAN fix dulu)

```bash
sudo usg audit cis_level1_server
```

Laporan HTML/XML di `/var/lib/usg/`:

```bash
ls -lt /var/lib/usg/ | head
```

Profil yang tersedia:

| Profil | Level | Catatan |
|---|---|---|
| `cis_level1_server` | L1 | baseline server — **mulai dari sini** |
| `cis_level2_server` | L2 | defense in depth; lebih agresif |
| `cis_level1_workstation` | L1 | tidak dipakai (server) |
| `stig` | — | DISA STIG, lebih ketat dari CIS L2 |

### 2.3 Membaca hasil

Laporan USG memberi skor kepatuhan dan daftar rule PASS/FAIL. Yang penting bukan
angkanya, tapi **klasifikasi setiap FAIL**:

| Kategori | Tindakan |
|---|---|
| Bisa diperbaiki tanpa risiko | perbaiki (Ansible task) |
| Perbaikan berisiko ke cluster | **pengecualian** + mitigasi |
| Tidak relevan (mis. tidak ada WiFi di VM) | pengecualian + alasan "N/A" |
| Sudah diperbaiki tapi rule tetap FAIL | kemungkinan rule membaca file yang salah → verifikasi manual |

### 2.4 Tailoring — cara yang benar untuk node Kubernetes

Jangan `usg fix` lalu menambal kerusakan. Buat tailoring yang **mengeluarkan** kontrol
yang memang tidak boleh diterapkan.

```bash
sudo usg generate-tailoring cis_level1_server /root/tailoring.xml
```

Edit `/root/tailoring.xml`, set `selected="false"` untuk rule yang masuk daftar
pengecualian ([`HARDENING-K8S.md` §9](HARDENING-K8S.md#9-tabel-pengecualian-cis)),
misalnya:

```xml
<!-- tidak boleh: CNI butuh load module -->
<select idref="xccdf_org.ssgproject.content_rule_kernel_module_disabled_selected" selected="false"/>
```

Lalu audit dengan tailoring:

```bash
sudo usg audit --tailoring-file /root/tailoring.xml cis_level1_server
```

### 2.5 Remediasi — hanya di VM uji dulu

```bash
# SIMULASI di VM uji, bukan node produksi
sudo usg fix cis_level1_server

# atau dengan tailoring
sudo usg fix --tailoring-file /root/tailoring.xml cis_level1_server

sudo reboot   # beberapa kontrol baru berlaku setelah reboot
```

Setelah itu **audit ulang** dan bandingkan:

```bash
sudo usg diff cis_level1_server
```

> ⚠️ `usg fix` mengubah layanan, sysctl, PAM, dan mount. Pada node Kubernetes ini
> hampir pasti memutus kubelet atau Cilium. Urutan yang benar: audit → tailoring →
> fix di VM uji → verifikasi cluster tetap sehat → baru node satu per satu.

### 2.6 Simpan hasil ke repo

```bash
mkdir -p benchmarks/cis/$(date +%F)
sudo cp /var/lib/usg/*.html /var/lib/usg/*.xml benchmarks/cis/$(date +%F)/ 2>/dev/null || true
git add benchmarks/cis && git commit -m "bench(cis): audit $(date +%F)"
```

---

## 3. Lapis 2 — OpenSCAP + SSG

Dipakai ketika butuh **format audit formal** (XCCDF/OVAL) yang bisa diserahkan ke
auditor, atau ketika ingin tailoring yang lebih detail daripada USG.

### 3.1 Install

```bash
sudo apt install -y openscap-scanner

# konten SSG untuk Ubuntu
sudo apt install -y ssg-debderived || sudo apt install -y ssg-base

ls /usr/share/xml/scap/ssg/content/ | grep -i ubuntu
```

### 3.2 Temukan profile ID yang tepat

**Jangan menebak** nama profile — beda versi SSG, beda ID.

```bash
DS=/usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml
oscap info "$DS" | sed -n '/Profiles:/,/^$/p'
```

Ambil ID yang mengandung `cis_level1_server` (bisa `..._cis_level1_server` atau `..._cis`).

### 3.3 Scan

```bash
DS=/usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml
PROFILE=xccdf_org.ssgproject.content_profile_cis_level1_server   # sesuaikan hasil 3.2
OUT=benchmarks/cis/$(date +%F)/openscap-$(hostname)
mkdir -p "$(dirname "$OUT")"

sudo oscap xccdf eval \
  --profile "$PROFILE" \
  --results   "${OUT}-results.xml" \
  --report    "${OUT}-report.html" \
  "$DS"
```

Exit code `0` = semua lulus, `2` = ada rule gagal. **Jangan** hentikan pipeline karena
exit 2 — itu normal; yang dinilai adalah skor.

### 3.4 Skor dari hasil XML

```bash
sudo oscap xccdf eval \
  --profile "$PROFILE" \
  --results /tmp/r.xml \
  --report /tmp/r.html \
  --fetch-remote-resources=false \
  "$DS" >/dev/null 2>&1 || true

# hitung persentase pass
python3 - <<'PY'
import xml.etree.ElementTree as ET
ns = {'x':'http://checklists.nist.gov/xccdf/1.2'}
t = ET.parse('/tmp/r.xml')
rules = t.getroot().findall('.//x:rule-result', ns)
p = sum(1 for r in rules if r.findtext('x:result', '', ns) == 'pass')
f = sum(1 for r in rules if r.findtext('x:result', '', ns) == 'fail')
s = p + f + sum(1 for r in rules if r.findtext('x:result', '', ns) in ('notapplicable','notchecked'))
print(f"pass={p} fail={f} total={s} score={100*p/max(p+f,1):.1f}%")
PY
```

> `max(p+f,1)` sengaja: `notapplicable` tidak boleh menaikkan skor. Menghitung N/A
> sebagai lulus adalah cara paling umum membuat skor terlihat bagus padahal tidak.

### 3.5 Tailoring

```bash
oscap xccdf generate fix --profile "$PROFILE" --fix-type ansible "$DS" \
  > /root/remediation-ubuntu.yml
```

Atau buat tailoring file sendiri lalu tambahkan `--tailoring-file`.

---

## 4. Lapis 3 — Lynis

Fungsinya berbeda dari USG: Lynis memberi **skor 0–100** dan saran yang bisa dibaca
manusia. Cocok untuk tren antar waktu.

```bash
sudo apt install -y lynis

sudo lynis audit system --quick
```

Ambil skor:

```bash
grep '^hardening_index' /var/log/lynis-report.dat
# hardening_index=82
```

Detail temuan:

```bash
# saran yang belum diterapkan
grep '^suggestion\[\]' /var/log/lynis-report.dat | head -30

# peringatan
grep '^warning\[\]' /var/log/lynis-report.dat
```

Automated check mingguan:

`/etc/cron.weekly/lynis-check`:

```bash
#!/bin/sh
set -eu
/usr/sbin/lynis audit system --quick --quiet >/dev/null 2>&1 || true
SCORE=$(grep '^hardening_index' /var/log/lynis-report.dat | cut -d= -f2)
echo "lynis_score{host=\"$(hostname)\"} $SCORE" > /var/lib/node_exporter/textfile/lynis.prom
logger -t lynis "hardening_index=$SCORE"
```

> Lynis bukan alat kepatuhan formal. Jangan mengklaim "CIS compliant" berdasarkan
> skor Lynis — pakai USG/OpenSCAP untuk klaim itu.

---

## 5. Lapis 4 — kube-bench

CIS Kubernetes Benchmark. Untuk cluster ini, ini **bukti utama** kepatuhan k8s.

### 5.1 Job (control plane)

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
  namespace: kube-system
spec:
  backoffLimit: 0
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
          command: ["kube-bench", "run", "--targets", "master", "--json"]
          volumeMounts:
            - { name: var-lib-etcd,   mountPath: /var/lib/etcd,   readOnly: true }
            - { name: etc-kubernetes, mountPath: /etc/kubernetes, readOnly: true }
            - { name: etc-systemd,    mountPath: /etc/systemd,    readOnly: true }
            - { name: lib-systemd,    mountPath: /lib/systemd,    readOnly: true }
      restartPolicy: Never
      volumes:
        - { name: var-lib-etcd,   hostPath: { path: /var/lib/etcd } }
        - { name: etc-kubernetes, hostPath: { path: /etc/kubernetes } }
        - { name: etc-systemd,    hostPath: { path: /etc/systemd } }
        - { name: lib-systemd,    hostPath: { path: /lib/systemd } }
```

Worker: salin manifest, ganti `--targets node`, dan hapus `nodeSelector` control-plane.

```bash
kubectl apply -f kube-bench-master.yaml
kubectl -n kube-system wait --for=condition=complete job/kube-bench-master --timeout=300s

kubectl -n kube-system logs job/kube-bench-master > benchmarks/cis/$(date +%F)/kube-bench-master.json
```

### 5.2 Skor

kube-bench JSON berisi `totals`:

```bash
kubectl -n kube-system logs job/kube-bench-master \
  | jq -r '.Totals | "pass=\(.total_pass) fail=\(.total_fail) warn=\(.total_warn) score=\(100*.total_pass/(.total_pass+.total_fail))"'
```

### 5.3 Catatan penting

| Hal | Kenapa |
|---|---|
| Versi image harus mendukung versi k8s | `kube-bench` lama tidak mengenali 1.34; cek `kubectl logs ... \| head` |
| Beberapa check `WARN` karena Cilium | tanpa kube-proxy, beberapa CIS check kube-proxy jadi N/A — **bukan** FAIL |
| `--benchmark` bisa dipaksa | hanya jika kube-bench tidak mendeteksi versi otomatis |
| Jangan hapus Job | logs hilang saat Job dihapus; ambil dulu |

Jalankan juga versi **operator** kalau ingin kontinu (bukan sekadar mingguan).

---

## 6. Lapis 5 — Kubescape

Melengkapi kube-bench: framework NSA/CISA dan MITRE ATT&CK, plus pemeriksaan workload.

```bash
curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash

kubescape list frameworks          # nama framework bergantung versi
kubescape scan framework nsa
kubescape scan framework mitre --format json --output mitre.json
```

Contoh output ringkas:

```
┌────────────────────┬──────────────────────┬──────────┐
│ Framework          │ Failed controls      │ Severity │
├────────────────────┼──────────────────────┼──────────┤
│ NSA                │ 12                   │ High     │
└────────────────────┴──────────────────────┴──────────┘
```

Gate di CI (kalau versimu mendukung):

```bash
kubescape scan framework nsa --compliance-threshold 85
```

> Nama framework CIS di Kubescape berubah antar versi (mis. `cis-v1.10.0` vs `cis`).
> Selalu `kubescape list frameworks` dulu, jangan hardcode.

---

## 7. Skor, tren, dashboard

Angka tunggal tidak berguna. Yang berguna: **tren per host per sumber**.

### 7.1 Kirim ke Prometheus

Pakai Pushgateway (tidak butuh agent di setiap VM):

```bash
HOST=$(hostname)
LYNIS=$(grep '^hardening_index' /var/log/lynis-report.dat | cut -d= -f2)

cat <<EOF | curl --data-binary @- http://pushgw.kirahadian.local:9091/metrics/job/cis_audit/instance/${HOST}
# TYPE compliance_score gauge
compliance_score{source="lynis",host="${HOST}"} ${LYNIS}
compliance_score{source="usg",host="${HOST}"} ${USG_SCORE}
compliance_score{source="kube-bench",host="${HOST}"} ${KB_SCORE}
# TYPE compliance_failed_controls gauge
compliance_failed_controls{source="kubescape",framework="nsa"} ${NSA_FAILED}
EOF
```

> Pushgateway **tidak** menghapus metrik lama. Tambahkan `delete` di awal siklus atau
> gunakan `honor_labels` + timestamp. Tanpa itu, host yang dihapus tetap muncul selamanya.

### 7.2 Alternatif tanpa Pushgateway

Textfile collector `node_exporter`:

```bash
sudo mkdir -p /var/lib/node_exporter/textfile
# tulis file .prom
echo 'compliance_score{source="lynis"} 82' | sudo tee /var/lib/node_exporter/textfile/cis.prom
```

`node_exporter` dijalankan dengan `--collector.textfile.directory=/var/lib/node_exporter/textfile`.

### 7.3 Dashboard "Security Posture Trend"

Empat panel minimum:

| Panel | Query |
|---|---|
| Skor per host | `compliance_score{source="lynis"}` |
| Skor cluster | `compliance_score{source="kube-bench"}` |
| Kontrol gagal per framework | `compliance_failed_controls` |
| Delta 30 hari | `compliance_score - compliance_score offset 30d` |

Tambah garis target (80/90) dan alert kalau turun > 5 poin dalam 7 hari — penurunan
mendadak biasanya berarti ada yang mengubah konfigurasi, bukan "hardening memburuk".

### 7.4 Riwayat di git

Selain Prometheus, commit hasil mentah:

```
benchmarks/cis/2026-11-23/
├── lynis-k8s-w-01.dat
├── usg-k8s-w-01.html
├── kube-bench-master.json
└── kubescape-nsa.json
```

Git history = audit trail yang tidak bisa dihapus diam-diam.

---

## 8. Menafsirkan hasil & alur remediasi

### 8.1 Tiga klasifikasi wajib

Setiap temuan **harus** masuk salah satu:

| Klasifikasi | Arti | Artefak |
|---|---|---|
| **FIX** | memang salah, bisa diperbaiki | commit ke role Ansible / policy Kyverno |
| **EXCEPTION** | tidak boleh diterapkan di konteks kita | baris di `docs/adr/0010` + mitigasi |
| **N/A** | tidak relevan (tidak ada WiFi, tidak ada Bluetooth) | catatan di tailoring |

Temuan tanpa klasifikasi = utang teknis yang tak terlihat.

### 8.2 Siklus

```
scan -> klasifikasi -> (fix|exception) -> scan ulang -> catat skor -> commit
```

Contoh nyata:

| Temuan | Klasifikasi | Tindakan |
|---|---|---|
| SSH `PermitRootLogin yes` | FIX | task Ansible di role `common` |
| `kernel.modules_disabled=1` FAIL | EXCEPTION | ADR-0010 + module blacklist |
| `/tmp` belum `nodeexec` di worker runner | EXCEPTION | pengecualian per-node |
| kubelet `readOnlyPort` terbuka | FIX | `KubeletConfiguration` |
| Bluetooth service | FIX | hapus paket |
| `kube-proxy` check WARN | N/A | tanpa kube-proxy (Cilium) |
| CVE paket `openssl` | FIX | `apt upgrade` terjadwal |

### 8.3 Remediasi sebagai kode

Jangan menambal server. Tambal **sumber**:

| Temuan | Diperbaiki di |
|---|---|
| sysctl / SSH / paket | `infra/vm/ansible` role |
| kubelet / apiserver | `platform/bootstrap/ansible/roles/kubeadm` |
| workload manifest | `security/kyverno/policies` |
| image CVE | Renovate + rebuild pipeline |

Setelah commit, jalankan ulang Ansible ke node — bukan edit manual.

---

## 9. Jadwal

| Frekuensi | Apa | Output |
|---|---|---|
| Setiap build | Trivy fs/image, kube-linter | gate CI |
| Harian | Lynis (cepat) | `compliance_score` |
| Mingguan | USG audit + Kubescape | HTML + JSON, commit ke repo |
| Mingguan | kube-bench (Job) | JSON |
| Bulanan | USG/OpenSCAP penuh + review exception list | laporan |
| Kuartalan | review ADR-0010, uji restore, uji HA | catatan runbook |
| Setiap upgrade k8s/OS | benchmark ulang | bandingkan dengan baseline |

---

## 10. Anti-pattern

| ❌ | Akibat |
|---|---|
| `usg fix` di node produksi yang sudah jalan | cluster mati, sulit di-rollback |
| Mengejar skor 100% | mengecualikan kontrol penting demi angka, atau merusak fungsi |
| Menghitung `notapplicable` sebagai pass | skor palsu |
| Menyembunyikan FAIL tanpa tanggal kedaluwarsa | utang abadi |
| Mengandalkan satu tool | buta terhadap lapisan lain |
| Menjalankan benchmark hanya sekali | tidak ada tren, tidak ada bukti perbaikan |
| Menyimpan hasil hanya di VM | hilang saat rebuild |
| Menyamakan Lynis score dengan CIS compliance | klaim yang tidak bisa dipertanggungjawabkan |

---

## 11. Integrasi CI

Job terjadwal (bukan per-MR — butuh akses host):

```yaml
cis-audit:
  stage: security
  image: ubuntu:24.04
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  before_script:
    - apt-get update && apt-get install -y openssh-client jq curl
    - eval $(ssh-agent -s) && echo "$SSH_PRIVATE_KEY" | ssh-add -
    - mkdir -p ~/.ssh && ssh-keyscan -H 10.10.20.21 >> ~/.ssh/known_hosts
  script:
    - |
      for HOST in 10.10.20.11 10.10.20.21; do
        ssh ops@$HOST 'sudo lynis audit system --quick --quiet >/dev/null 2>&1 || true;
                       grep "^hardening_index" /var/log/lynis-report.dat'
      done
    - ./ci/scripts/push-cis-metrics.sh
  artifacts:
    paths:
      - benchmarks/cis/
    expire_in: 1 year
```

Yang **tidak** boleh: menjalankan `usg fix` dari CI. Audit boleh otomatis, remediasi tidak.

---

## 12. Target & kapan berhenti

Target dari [`docs/adr/0010`](../../docs/adr/0010-cis-hardening-exceptions.md):

| Sumber | Target | Kenapa bukan 100% |
|---|---|---|
| Lynis hardening index | **≥ 80** | 100 mustahil tanpa mematikan fungsi |
| USG CIS L1 (dengan tailoring) | **≥ 90%** | sisa = N/A + pengecualian sah |
| kube-bench control plane | **≥ 90%** | beberapa check kube-proxy N/A (Cilium) |
| kube-bench worker | **≥ 85%** | runner butuh lebih banyak pengecualian |
| Kubescape NSA | **0 critical failed** | severity tinggi tidak boleh ada |

**Berhenti mengejar skor ketika:**

1. Semua FAIL sudah diklasifikasi (FIX / EXCEPTION / N/A).
2. Setiap pengecualian punya mitigasi dan tanggal review.
3. Tren tidak menurun.
4. Perubahan konfigurasi dilakukan lewat kode, bukan manual.

Kalau keempat hal itu terpenuhi, skor 82% dengan 14 pengecualian terdokumentasi lebih
bernilai daripada 99% yang dicapai dengan mematikan layanan penting.

---

## Lampiran — urutan eksekusi

```bash
# 1. OS (semua VM)
sudo usg audit cis_level1_server
sudo lynis audit system --quick

# 2. tailoring untuk node k8s (dari VM uji)
sudo usg generate-tailoring cis_level1_server /root/tailoring.xml
sudo usg audit --tailoring-file /root/tailoring.xml cis_level1_server

# 3. cluster
kubectl apply -f kube-bench-master.yaml
kubectl -n kube-system logs job/kube-bench-master > kube-bench.json
kubescape scan framework nsa

# 4. catat
grep '^hardening_index' /var/log/lynis-report.dat
cp /var/lib/usg/*.html benchmarks/cis/$(date +%F)/
git add benchmarks/cis && git commit -m "bench(cis): $(date +%F)"
```
