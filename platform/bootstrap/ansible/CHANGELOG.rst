==========
Changelog
==========

0.1.0 (2026-11-23)
------------------

Added
~~~~~

- ``common``: paket dasar, chrony, swap off, module kernel, sysctl Kubernetes
  (termasuk ``fs.inotify.*``), ulimit, direktori konfigurasi.
- ``etcd_disk``: format + mount vDisk etcd lewat ``LABEL=``, dengan penolakan
  format ulang device berisi data dan penolakan device di disk sistem.
- ``containerd``: repo Docker, generate config default, deteksi skema v2/v3,
  ``SystemdCgroup=true``, pause image, mirror Nexus opsional.
- ``kubernetes``: repo pkgs.k8s.io, pin versi + ``apt-mark hold``, verifikasi
  versi tersedia sebelum install.
- ``kubevip``: static pod kube-vip (ARP, leader election) + RBAC.
- ``kubeadm``: audit policy, encryption-at-rest, init HA, token join,
  RBAC kube-vip, fetch kubeconfig.
- ``kubeadm_join``: join control plane (serial 1) dan worker (serial 2).
- ``cilium``: Helm install, verifikasi kube-proxy benar-benar absen.
- ``addons``: Gateway API CRD, cert-manager, metrics-server, namespace +
  label Pod Security Admission, approve CSR kubelet, hapus ``kubeadm-certs``.
- ``verify``: 10 assertion read-only (node Ready, pod system, quorum etcd,
  sertifikat, encryption at rest, metrics-server, CIDR overlap).

Known limitations
~~~~~~~~~~~~~~~~~

- Belum mengotomasi: pembuatan VM, DNS, Nutanix CSI, ArgoCD, kube-bench.
- Upgrade cluster masih manual — lihat runbook di repositori.
