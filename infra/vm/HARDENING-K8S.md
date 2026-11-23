# Hardening Node Kubernetes

**Overlay** di atas [`HARDENING.md`](HARDENING.md). Dokumen ini **hanya** berisi hal yang
berbeda atau bertambah karena node menjalankan kubelet, apiserver, etcd, dan Cilium.

> Terapkan `HARDENING.md` lebih dulu, **lalu** dokumen ini. Kalau dibalik, kubelet akan
> gagal start dan pesan errornya menyesatkan.

---

## Daftar Isi

1. [Ruang lingkup](#1-ruang-lingkup)
2. [Konflik baseline vs kubelet (baca dulu)](#2-konflik-baseline-vs-kubelet-baca-dulu)
3. [Kubelet](#3-kubelet)
4. [kube-apiserver](#4-kube-apiserver)
5. [etcd](#5-etcd)
6. [containerd](#6-containerd)
7. [Cilium & NetworkPolicy](#7-cilium--networkpolicy)
8. [Pod: PSA, Kyverno, seccomp](#8-pod-psa-kyverno-seccomp)
9. [Tabel pengecualian CIS](#9-tabel-pengecualian-cis)
10. [RBAC & ServiceAccount](#10-rbac--serviceaccount)
11. [Verifikasi](#11-verifikasi)
12. [Mode kegagalan khas](#12-mode-kegagalan-khas)

---

## 1. Ruang lingkup

| Node | Dokumen ini | Catatan |
|---|---|---|
| `k8s-cp-01..03` | semua bagian | termasuk etcd |
| `k8s-w-01..03` | semua kecuali etcd & apiserver | plus pengecualian runner (build) |

Sumber kebenaran konfigurasi: `platform/bootstrap/ansible/inventory/group_vars/all/main.yml`.

---

## 2. Konflik baseline vs kubelet (baca dulu)

`kubeadm-config.yaml` memakai `protectKernelDefaults: true`. Artinya **kubelet memverifikasi
sysctl tertentu saat start** dan menolak jalan kalau nilainya tidak sesuai harapannya.

Sysctl yang diperiksa antara lain:

| Sysctl | Nilai wajib | Kalau berbeda |
|---|---|---|
| `net.ipv4.ip_forward` | `1` | kubelet gagal: *"invalid sysctl"* |
| `net.bridge.bridge-nf-call-iptables` | `1` | kubelet gagal |
| `kernel.keys.maxkeys` | >= 200 | kubelet gagal |

Karena itu, sysctl di `HARDENING.md` Lapis 3 **aman** (tidak menyentuh ketiganya), tapi:

- **Jangan** set `net.ipv4.ip_forward=0` "supaya tidak jadi router".
- **Jangan** set `net.bridge.bridge-nf-call-iptables=0` "supaya lebih cepat".
- Kalau kubelet menolak start setelah hardening, cek dulu:

```bash
sudo journalctl -u kubelet -n 50 --no-pager | grep -i -E 'sysctl|invalid'
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables kernel.keys.maxkeys
```

Tambahan sysctl khusus node (di luar baseline):

```ini
# /etc/sysctl.d/91-k8s-node.conf
kernel.keys.maxkeys = 20000
fs.inotify.max_user_watches   = 1048576
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
vm.swappiness = 0
```

> `fs.inotify.*` bukan "nice to have". Default 8192 membuat pod nyangkut
> `ContainerCreating` tanpa error yang jelas saat Prometheus/ArgoCD/CSI membuka watch.

---

## 3. Kubelet

Konfigurasi lewat `KubeletConfiguration` di `kubeadm-config.yaml` (sudah ada di repo).
Yang **wajib** ada:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
protectKernelDefaults: true
rotateCertificates: true
serverTLSBootstrap: true
readOnlyPort: 0                     # matikan port 10255 tanpa auth
seccompDefault: true                # semua pod tanpa profil -> RuntimeDefault
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
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
```

| Setting | Kenapa |
|---|---|
| `readOnlyPort: 0` | temuan kube-bench klasik; port 10255 membocorkan info pod tanpa auth |
| `seccompDefault: true` | profil seccomp `RuntimeDefault` otomatis, tanpa perlu ubah setiap Deployment |
| `serverTLSBootstrap: true` | sertifikat kubelet dari CA cluster, bukan self-signed |
| `systemReserved`/`kubeReserved` | mencegah pod menghabiskan memori sampai kubelet OOM-kill |
| `evictionHard.imagefs` | hanya efektif kalau `/var/lib/containerd` di **disk terpisah** |
| `imageGC*` | mencegah image menumpuk sampai disk penuh |

### KubeletConfiguration hanya ditulis sekali

`kubeadm init` menulis `/var/lib/kubelet/config.yaml`. Setelah itu, mengubah
`kubeadm-config.yaml` **tidak** otomatis mengubah node yang sudah jalan.

```bash
# cara yang benar untuk mengubah kubelet config
sudo kubeadm upgrade node phase kubelet-config
sudo systemctl restart kubelet
```

### Rotasi sertifikat kubelet

`rotateCertificates: true` membuat kubelet mengajukan CSR baru otomatis. Ada dua pilihan:

| Pendekatan | Aman? | Catatan |
|---|---|---|
| Approve manual | paling aman | butuh orang; cocok untuk 6 node |
| Auto-approve `selfnodeclient` | perlu kehati-hatian | kubelet bisa meminta sertifikat baru kapan saja; dokumentasikan |

Kalau memilih auto-approve, batasi ke grup `system:nodes` saja (lihat
`INSTALL.md` §15.3).

---

## 4. kube-apiserver

Tambahan `extraArgs` di `ClusterConfiguration`:

```yaml
apiServer:
  extraArgs:
    - name: anonymous-auth
      value: "false"
    - name: tls-min-version
      value: "VersionTLS12"
    - name: enable-admission-plugins
      value: NodeRestriction,PodSecurity
    # sudah ada di konfigurasi repo:
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: encryption-provider-config
      value: /etc/kubernetes/enc/encryption-config.yaml
```

| Flag | Efek | Risiko |
|---|---|---|
| `anonymous-auth=false` | request tanpa identitas ditolak 401 | probe HTTP yang mengandalkan anonymous akan gagal. kube-vip memakai TCP, jadi aman |
| `tls-min-version=VersionTLS12` | TLS 1.0/1.1 mati | komponen sangat lama tidak bisa terhubung |
| `NodeRestriction` | kubelet hanya bisa mengubah node miliknya | wajib |
| `PodSecurity` | PSA aktif | wajib |

**Jangan** menambahkan `--allow-privileged=false` di control plane tanpa menguji: beberapa
addon (CNI, CSI, node-exporter) membutuhkannya.

Cek konfigurasi efektif:

```bash
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -E 'anonymous|tls-min|admission'
```

---

## 5. etcd

kubeadm sudah mengaktifkan hal yang benar secara default. Yang perlu **diverifikasi**,
bukan diubah:

```bash
kubectl -n kube-system get pod etcd-k8s-cp-01 \
  -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' \
  | grep -E 'client-cert-auth|peer-client-cert|auto-tls|listen-client'
```

Harapan:

```
--client-cert-auth=true
--peer-client-cert-auth=true
--auto-tls=false
--peer-auto-tls=false
--listen-client-urls=https://127.0.0.1:2379,https://10.10.20.11:2379
--listen-peer-urls=https://10.10.20.11:2380
```

| Item | Aturan |
|---|---|
| Listen address | **jangan** `0.0.0.0`. Hanya `127.0.0.1` + IP node |
| Metrics | `listen-metrics-urls=http://0.0.0.0:2381` boleh, tapi batasi di nftables ke subnet monitoring |
| Data dir | vDisk terpisah, `0700` root, `noatime` |
| Backup | `etcdctl snapshot save` (bukan snapshot VM) |
| `quota-backend-bytes` | 8 GiB, alert di 70% |

Cek permission data dir:

```bash
sudo stat -c '%a %U:%G %n' /var/lib/etcd
# harus: 700 root:root /var/lib/etcd
```

---

## 6. containerd

Sudah diatur role `containerd`. Yang perlu ditambahkan untuk keamanan:

```toml
# /etc/containerd/config.toml — bagian runc options
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
  NoNewPrivileges = true        # opsional — uji dulu
```

`NoNewPrivileges = true` di level runtime **memutus** container yang butuh `setuid`
(beberapa image legacy, beberapa CSI). Uji per workload. Kalau tidak yakin, atur di
level pod (`securityContext.allowPrivilegeEscalation: false`) dan biarkan containerd default.

Bersihkan image berkala (kubelet sudah melakukannya, ini jaring pengaman):

```bash
sudo crictl rmi --prune
```

Batasi akses socket:

```bash
sudo stat -c '%a %U:%G %n' /run/containerd/containerd.sock
# 660 root:root — jangan 666
```

> Siapa pun yang bisa menulis ke socket containerd **adalah** root di node itu.
> Ini alasan runner tidak boleh jalan sebagai pod privileged di node yang sama
> dengan workload produksi.

---

## 7. Cilium & NetworkPolicy

### 7.1 Default-deny per namespace

Cilium tidak memaksa default-deny sampai ada policy yang menyeleksi pod. Tambahkan
di setiap namespace aplikasi:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: apps-prod
spec:
  endpointSelector: {}
  ingress: []
  egress:
    # DNS tetap diizinkan, kalau tidak semua resolve gagal dan sulit didiagnosis
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

Tanpa blok DNS di atas, gejala yang muncul adalah `dial tcp: lookup ... i/o timeout`
pada semua pod, dan orang biasanya menyalahkan CoreDNS.

### 7.2 Verifikasi enforcement

```bash
cilium policy get
hubble observe --namespace apps-prod --verdict DENIED --last 20
```

### 7.3 Yang harus dihindari

| Dilarang | Kenapa |
|---|---|
| `hostNetwork: true` pada workload aplikasi | melewati NetworkPolicy, berbagi network namespace node |
| `hostPID` / `hostIPC` / `privileged` | berbagi namespace node, ekuivalen root |
| `hostPath` ke `/var/run/containerd` atau `/var/lib/kubelet` | jalan pintas escape node |
| Service `LoadBalancer` tanpa perlu | menambah permukaan serangan; pakai Gateway |

---

## 8. Pod: PSA, Kyverno, seccomp

### 8.1 Pod Security Admission

```bash
kubectl label namespace apps-prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite

# kube-system: baseline, jangan restricted (addon butuh)
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

**Jangan** pasang `restricted` di `kube-system`. Cilium, CSI, dan node-exporter akan
gagal dijadwalkan dan cluster kehilangan jaringan.

### 8.2 SecurityContext standar

Setiap Deployment wajib:

```yaml
spec:
  template:
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

`automountServiceAccountToken: false` adalah yang paling sering dilupakan: tanpa itu,
setiap pod membawa token SA yang bisa dipakai memanggil apiserver.

### 8.3 Kyverno (fase 6)

Policy di `security/kyverno/policies/` menegakkan hal yang sama di admission, supaya
tidak bergantung pada disiplin penulis manifest:

| Policy | Menolak |
|---|---|
| `require-signed-images` | image tanpa signature Cosign |
| `disallow-latest-tag` | tag `latest` / tanpa digest |
| `require-security-context` | tanpa `runAsNonRoot`/`readOnlyRootFilesystem`/drop ALL |
| `require-resource-limits` | tanpa request & limit |
| `disallow-privileged` | privileged, hostPath, hostNetwork |
| `restrict-registries` | pull selain dari Nexus |

---

## 9. Tabel pengecualian CIS

Kontrol CIS yang **harus** dikecualikan di node Kubernetes, beserta mitigasinya.
Ini versi operasional dari [`docs/adr/0010`](../../docs/adr/0010-cis-hardening-exceptions.md).

| Kontrol | Kenapa dikecualikan | Mitigasi | Cakupan |
|---|---|---|---|
| `kernel.modules_disabled=1` | CNI/CSI load module saat runtime | module blacklist + `bpf_jit_harden=2` | semua node |
| Batasi unprivileged userns | memblokir rootless BuildKit | `kernel.apparmor_restrict_unprivileged_userns=0` | worker runner saja |
| `/tmp` `noexec` | build tool butuh exec di /tmp | `noexec` di CP; worker runner tanpa `noexec` | per node |
| `ufw` deny-all di host | berebut iptables/eBPF dengan Cilium | nftables hanya management plane + NetworkPolicy | node k8s |
| Audit `execve` global | overhead di node high-fork (runner) | filter `euid=0` + Tetragon | worker runner |
| Auto-reboot patch | node mati kapan saja | security-only upgrade + maintenance window | semua node |
| Password expiry / `pam_pwquality` | tidak ada password | SSH key + rencana SSH CA | semua node |
| `TMOUT` agresif | memutus `kubectl exec` & job panjang | scope user interaktif saja | semua node |
| Disable IPv6 total | single-stack sudah aman | `accept_ra=0` + disable di interface cluster | semua node |
| `kernel.kptr_restrict=2` | memblokir `perf`/`bcc` untuk debugging | turunkan ke `1` di worker observability | opsional |

Cara menerapkan pengecualian di USG/OpenSCAP: lihat [`CIS-BENCHMARK.md`](CIS-BENCHMARK.md) bagian 2-3.

---

## 10. RBAC & ServiceAccount

### 10.1 Prinsip

| Aturan | Alasan |
|---|---|
| Manusia **tidak** memakai `admin.conf` | tidak ada audit per orang, tidak ada revoke |
| Gunakan OIDC (GitLab/Dex) + RoleBinding | identitas per orang, token short-lived |
| `cluster-admin` hanya untuk break-glass | simpan di password manager, catat pemakaiannya |
| Group mapping, bukan user satu-satu | menambah orang = ubah group |
| ServiceAccount per aplikasi | blast radius kecil |
| `automountServiceAccountToken: false` by default | token tidak perlu ada di pod |

### 10.2 Audit akses

```bash
# siapa yang bisa apa
kubectl auth can-i --list --as=ops@gatezero.lab
kubectl auth can-i create pods --namespace apps-prod --as=system:serviceaccount:apps-prod:demo-api

# cari yang terlalu longgar
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + ((.subjects // []) | map(.name) | join(","))'
```

Target: `cluster-admin` minimal 2 (break-glass + ArgoCD), sisanya RoleBinding.

### 10.3 Token

Sejak Kubernetes 1.24, Secret token SA tidak dibuat otomatis. Gunakan bound token
dengan audience & expiry:

```bash
kubectl create token demo-api -n apps-prod --duration=1h
```

Jangan membuat Secret bertipe `kubernetes.io/service-account-token` manual. Itu
menghidupkan kembali token abadi.

---

## 11. Verifikasi

```bash
# --- kubelet ---
sudo grep -E 'readOnlyPort|seccompDefault|protectKernelDefaults|rotateCertificates' /var/lib/kubelet/config.yaml
sudo ss -tlnp | grep 10255 || echo "OK: readOnlyPort mati"

# --- apiserver ---
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' \
  | grep -E 'anonymous-auth|tls-min-version|enable-admission'

# --- encryption at rest ---
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | grep -c encryption-provider-config

# --- PSA ---
kubectl get ns -o json | jq -r '.items[] | select(.metadata.labels."pod-security.kubernetes.io/enforce"!=null) | .metadata.name + " = " + .metadata.labels."pod-security.kubernetes.io/enforce"'

# --- default deny ---
kubectl get ciliumnetworkpolicies -A

# --- etcd ---
sudo stat -c '%a %U:%G %n' /var/lib/etcd
sudo findmnt -no TARGET,OPTIONS /var/lib/etcd

# --- containerd socket ---
sudo stat -c '%a %U:%G %n' /run/containerd/containerd.sock

# --- benchmark ---
# lihat CIS-BENCHMARK.md
```

---

## 12. Mode kegagalan khas

| Gejala | Penyebab | Perbaikan |
|---|---|---|
| kubelet `CrashLoopBackOff`: *invalid sysctl* | baseline menimpa sysctl yang divalidasi kubelet | kembalikan `ip_forward=1`, `bridge-nf-call-iptables=1` |
| node `NotReady`, Cilium tidak jalan | module `vxlan`/`geneve` di-blacklist | keluarkan dari blacklist, `update-initramfs -u`, reboot |
| semua pod `ContainerCreating` | `fs.inotify.*` habis | naikkan, restart kubelet |
| pod `Pending` di kube-system | namespace dilabeli `restricted` | kembalikan ke `baseline` |
| `kubectl exec` timeout, curl normal | MTU Cilium salah | ukur path MTU, set `8950`/`1450` sesuai |
| `metrics-server` 401 | `anonymous-auth=false` + CSR belum approve | approve CSR kubelet |
| `kubectl debug` gagal | `ptrace_scope=2` | turunkan ke `1` |
| build CI gagal aneh | `/tmp` `noexec` atau userns dibatasi | pengecualian per worker runner |
| disk node penuh mendadak | `/var/lib/containerd` masih satu disk dengan `/var` | pindahkan ke vDisk terpisah; alarm `nodefs.available` |
| etcd leader flapping | etcd satu disk dengan image | pindahkan etcd ke vDisk SSD terpisah |

---

## Lampiran — checklist node

```
[ ] HARDENING.md sudah diterapkan dan lulus verifikasi Lapis 12
[ ] sysctl k8s node ditambahkan (inotify, maxkeys)
[ ] kubelet: readOnlyPort=0, seccompDefault=true, reserved resources
[ ] apiserver: anonymous-auth=false, tls-min-version, NodeRestriction, PSA
[ ] etcd: cert-auth, listen bukan 0.0.0.0, data dir 0700, vDisk terpisah
[ ] containerd: SystemdCgroup=true, socket 660
[ ] Cilium: default-deny per namespace + blok DNS
[ ] PSA: restricted di apps-*, baseline di kube-system
[ ] RBAC: tidak ada admin.conf untuk manusia, cluster-admin minimal
[ ] pengecualian CIS tercatat dengan mitigasi
[ ] kube-bench + Kubescape dijalankan, skor dicatat
```
