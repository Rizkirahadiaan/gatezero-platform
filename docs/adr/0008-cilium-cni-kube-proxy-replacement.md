# ADR-0008: Cilium sebagai CNI sekaligus pengganti kube-proxy/LB/ingress

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** Stack default kubeadm memasang kube-proxy + butuh LoadBalancer + Ingress.
  Setiap komponen tambahan adalah CVE dan hal yang harus dijelaskan.

## Keputusan

kubeadm dijalankan dengan `--skip-phases=addon/kube-proxy`, lalu **Cilium** dipasang dengan:

| Fitur | Pengganti |
|---|---|
| `kubeProxyReplacement=true` | kube-proxy |
| `l2announcements` + LB IPAM | MetalLB |
| `gatewayAPI.enabled=true` | Traefik / ingress-nginx |
| `hubble` | observability flow (tambahan) |
| NetworkPolicy (L3/L4/L7) | — |

## Konsekuensi

### Positif
- Empat komponen jadi satu: lebih sedikit CVE, upgrade, dan dashboard.
- eBPF datapath: latency lebih rendah dan tanpa kentang iptables pada cluster besar.
- Hubble memberi visibilitas flow jaringan yang sangat kuat untuk demo keamanan
  ("siapa bicara ke siapa, diblokir di mana").
- NetworkPolicy default-deny benar-benar bisa dibuktikan dengan Hubble.

### Negatif
- Cilium bergantung pada kernel modern; butuh verifikasi di Ubuntu 24.04 + kernel AHV.
- Troubleshooting butuh pemahaman eBPF (`cilium status`, `hubble observe`), bukan `iptables -L`.
- L2 announcements butuh pemahaman ARP di VLAN Nutanix; kalau VLAN membatasi ARP, perlu mode BGP.

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| Calico | Matang, tapi tidak menggantikan LB/ingress; lebih banyak komponen terpisah |
| Flannel | Terlalu minimal, tanpa NetworkPolicy yang layak |
| kube-proxy + MetalLB + Traefik | Berfungsi, tapi 4 komponen vs 1 — lebih banyak permukaan serang |

## Catatan implementasi

- MTU: VXLAN menambah overhead ~50 byte. Jika Nutanix memakai jumbo frame (9000), set MTU pod
  ke 8950 dan dokumentasikan. MTU mismatch menghasilkan gejala "TLS handshake menggantung"
  yang sulit dilacak.
- `k8sServiceHost`/`k8sServicePort` harus menunjuk VIP kube-vip.
