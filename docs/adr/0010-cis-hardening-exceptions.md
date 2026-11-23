# ADR-0010: Daftar pengecualian CIS untuk node Kubernetes

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Hardening OS pada node Kubernetes **tidak bisa** menerapkan 100% kontrol CIS.
  Sebagian kontrol justru mematikan cluster.

## Keputusan

Menerapkan CIS Ubuntu 24.04 Level 1 secara selektif, dengan daftar pengecualian eksplisit di bawah.
Prosedur: `usg audit` → review diff → `usg fix` hanya untuk item aman → sisanya didokumentasikan.

## Tabel pengecualian

| Kontrol | Alasan dikecualikan | Mitigasi pengganti |
|---|---|---|
| `kernel.modules_disabled=1` | CNI & storage load module saat runtime | module blacklist + `bpf_jit_harden=2` |
| Pembatasan unprivileged user namespace | memblokir rootless BuildKit di runner | `kernel.apparmor_restrict_unprivileged_userns=0` **hanya di worker**; CP tetap dibatasi |
| `/tmp` `noexec` | memblokir build tool & instalasi dependency | aktif di CP; dikecualikan di worker runner |
| Password expiry / `pam_pwquality` | tidak ada password (SSH key + SSO) | N/A; akses lewat SSH CA short-lived |
| `TMOUT` agresif | memutus sesi `kubectl exec` dan job panjang | scope hanya ke user interaktif |
| `ufw` deny-all di host | berebut dengan iptables/eBPF Cilium | nftables hanya untuk management plane + NetworkPolicy |
| Audit `execve` tanpa filter | overhead pada node high-fork (runner) | filter `euid=0` + Tetragon untuk runtime |
| Auto-reboot patch otomatis | mematikan node kapan saja | security-only upgrade + maintenance window |
| Disable IPv6 total | single-stack sudah aman | `accept_ra=0` + disable di interface cluster |

## Aturan

1. Setiap pengecualian **wajib** punya mitigasi pengganti. "Tidak bisa" bukan alasan.
2. Pengecualian di-review setiap ada upgrade mayor OS/kubernetes.
3. Skor Lynis/kube-bench yang disepakati dicatat sebagai target, bukan "100%".

## Target

| Sumber | Target | Alasan |
|---|---|---|
| Lynis hardening index | ≥ 80 | 100 mustahil tanpa merusak fungsi |
| kube-bench control plane | ≥ 90% | sisa berasal dari pengecualian di atas |
| kube-bench worker | ≥ 85% | runner mengecualikan lebih banyak |
| Kubescape NSA | 0 failed (critical) | severity tinggi tidak boleh ada |

## Konsekuensi

### Positif
- Node tetap aman *dan* berfungsi.
- Reviewer melihat alasan, bukan angka mentah.
- Remediasi menjadi kode (Ansible/Policy), bukan tiket.

### Negatif
- Butuh pemeliharaan saat CIS benchmark versi baru rilis.
- Tidak bisa mengklaim "100% CIS compliant" — klaim yang jujur lebih bernilai.
