# kubeadm

Konfigurasi & material untuk membangun cluster HA dengan kubeadm.

## 📖 Dokumen utama

**➡️ [`INSTALL.md`](INSTALL.md)** — runbook lengkap 21 bagian.

## File yang akan ada di sini

| File | Isi |
|---|---|
| `kubeadm-config.yaml` | `InitConfiguration` + `ClusterConfiguration` + `KubeletConfiguration` |
| `kube-vip.yaml` | manifest static pod (di-generate, bukan ditulis tangan) |
| `audit-policy.yaml` | kebijakan audit apiserver |
| `encryption-policy.yaml` | template `EncryptionConfiguration` |
| `cert-key.enc.yaml` | certificate key join CP (SOPS) |
| `bootstrap-token.enc.yaml` | discovery kubeconfig worker (SOPS) |
| `encryption-config.enc.yaml` | salinan key encryption-at-rest (SOPS) |

> 🔒 File `*.enc.yaml` **wajib** dibuat dengan `sops -e`, bukan ditulis plaintext lalu
> dienkripsi belakangan. Pre-commit hook `gitleaks` akan memblokir kalau lupa.

## Hal yang tidak boleh dilakukan

| ❌ | Kenapa |
|---|---|
| Menjalankan `kubeadm init` sebelum 3 CP siap | etcd member setengah jadi, sulit dibersihkan |
| Join CP dengan `--certificate-key` dari shell history | key bocor = siapa pun bisa jadi CP |
| Lupa hapus Secret `kubeadm-certs` | temuan kube-bench + kredensial CA tersimpan |
| Mengandalkan snapshot VM untuk etcd | tidak crash-consistent (ADR-0009) |
| Upgrade 2 minor sekaligus | version skew tidak didukung |

## Versi

| Komponen | Versi | Cara pin |
|---|---|---|
| Kubernetes | `1.34.x` (N-1) | `apt-mark hold` |
| Cilium | `1.16+` | helm values |
| containerd | `2.x` | repo Docker |
| kube-vip | `0.8.x` | tag image |

> Catat versi final yang dipakai di [`../../README.md`](../../README.md) setelah instalasi.
