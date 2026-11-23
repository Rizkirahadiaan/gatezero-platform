# ADR-0001: kubeadm (HA, stacked etcd) sebagai distro cluster produksi

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Homelab/portofolio di Nutanix AHV, kebutuhan menunjukkan kompetensi operasional
  cluster yang benar-benar dipakai di enterprise.

## Konteks

Pilihan distro Kubernetes memengaruhi hampir semua keputusan lain: relevansi CIS benchmark,
cara upgrade, cara backup etcd, dan seberapa banyak yang "disembunyikan" oleh tooling.

## Keputusan

Menggunakan **kubeadm v1beta4**, 3 control plane dengan **stacked etcd**, `kube-vip` untuk VIP
API server, dan Cilium sebagai CNI. Versi dipin ke N-1 dari rilis terbaru dan di-hold via
`apt-mark hold kubelet kubeadm kubectl`.

## Konsekuensi

### Positif
- CIS Kubernetes Benchmark berlaku penuh (kube-bench section 1–5 relevan).
- Upgrade path eksplisit: `kubeadm upgrade plan` → drain → upgrade → uncordon, dengan version
  skew policy yang jelas.
- Semua komponen (etcd, apiserver, controller) terlihat dan bisa di-tuning.
- Skill yang paling banyak dicari di lowongan platform engineer.

### Negatif
- Lebih banyak VM (3 CP + vDisk etcd terpisah) dan biaya operasional lebih tinggi.
- Tidak ada addon otomatis: CNI, storage, metrics, ingress harus dipasang sendiri.
- Upgrade manual, butuh runbook dan maintenance window.

## Alternatif yang ditolak

| Alternatif | Alasan ditolak |
|---|---|
| k3s | Sangat baik untuk homelab, tapi menyembunyikan etcd/apiserver dan beberapa kontrol CIS tidak berlaku — kurang menunjukkan kedalaman operasional |
| Talos Linux | Menarik (immutable, API-driven) tapi kurva belajar tinggi dan sebagian besar perusahaan belum memakainya; portofolio jadi kurang "matchable" |
| Managed (EKS/GKE) | Tidak tersedia di Nutanix; dan justru menghilangkan bagian yang ingin didemokan |
| Nutanix NKP | Relevan untuk lingkungan ini, tapi mengikat portofolio ke satu vendor dan menyembunyikan control plane |
