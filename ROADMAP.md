# Roadmap & Checklist Penyelesaian

Dokumen ini menjawab satu pertanyaan: **"sudah selesai atau belum?"**

Aturan mainnya sederhana:

- `[ ]` belum, `[x]` selesai.
- **Jangan centang tanpa acceptance criteria terpenuhi.** Centang yang tidak jujur membuat
  dokumen ini tidak berguna.
- Setiap item punya ID (`R1`, `K3`, `C6`) supaya bisa dirujuk di commit:
  `feat: selesaikan C6 (cosign keyless)`.

Terakhir diperbarui: **2026-11-23**

---

## 1. Status jujur saat ini

Repo ini sekarang adalah **blueprint yang lengkap**, bukan platform yang berjalan.

| Lapisan | Status | Bukti |
|---|---|---|
| Dokumentasi & keputusan | 🟢 ~90% | 12 ADR, threat model, INSTALL.md 21 bagian, 3 dokumen hardening/CIS |
| Otomasi Ansible | 🟡 kode ada, **belum dieksekusi** | 21 role, 13 playbook, RUNBOOK |
| Kode aplikasi | 🔴 0% | `apps/*` hanya README |
| Pipeline CI nyata | 🔴 0% | `ci/templates` kosong |
| Manifest GitOps | 🔴 0% | `platform/gitops/argocd/apps` kosong |
| Policy keamanan | 🔴 0% | `security/kyverno/policies` hanya README |
| Cluster / VM | 🔴 0% | belum ada |

Penanda `Status: **stub**` masih ada di **9 file**. LICENSE belum ada (padahal README dan
`galaxy.yml` menyebut MIT).

---

## 2. Definisi "selesai" (Definition of Done)

| Level | Nama | Kriteria yang harus benar-benar terpenuhi |
|---|---|---|
| **DoD-1** | Repo selesai | 0 penanda stub · 0 referensi mati · LICENSE ada · `ansible-playbook --syntax-check` hijau · semua link internal valid |
| **DoD-2** | Platform jalan | `git push` → aplikasi jalan di namespace prod tanpa intervensi manual · 5 security drill bisa diulang · HA terbukti dengan mematikan 1 control plane · restore etcd pernah diuji |
| **DoD-3** | Portofolio siap | orang asing paham dalam 5 menit tanpa penjelasan · video 5 menit · live demo on-request |

Target minimum yang layak disebut selesai: **DoD-2**.

---

## 3. Aset yang sudah ada (jangan dikerjakan ulang)

- 12 ADR di `docs/adr/` + threat model STRIDE
- `platform/bootstrap/kubeadm/INSTALL.md` — runbook 21 bagian + layout partisi
- 10 role Ansible bootstrap + `site.yml` + RUNBOOK + metadata Galaxy
- 11 role Ansible hardening + 3 playbook + README
- `infra/vm/` — HARDENING, HARDENING-K8S, CIS-BENCHMARK
- `infra/benchmark/` — skrip fio/sysbench/iperf3/etcd
- `.sops.yaml` dua level (bootstrap root key, gitops per-env)
- `docs/architecture.drawio` (valid), `docs/nexus.md`
- Struktur repo + `.gitattributes` (LF) + pre-commit (gitleaks, sops, kubeconform)

---

## 4. Fase 0 — Repo hygiene · `P0` · ~0,5 hari

Bisa dikerjakan tanpa VM. Menaikkan kredibilitas repo secara instan.

- [ ] **R1** `LICENSE` (MIT) di root — *acceptance:* file ada dan disebut di README
- [ ] **R2** `docs/network-matrix.md` — *acceptance:* tabel port lengkap, dirujuk dari INSTALL.md
- [ ] **R3** `docs/runbooks/etcd-restore.md` — *acceptance:* Gejala → Langkah → Verifikasi → Rollback
- [ ] **R4** `docs/runbooks/node-upgrade.md` — *acceptance:* termasuk version skew & urutan drain
- [ ] **R5** `docs/runbooks/secret-rotation.md` — *acceptance:* prosedur `sops updatekeys` + `rotate`
- [ ] **R6** `platform/gitops/overlays/staging/` — *acceptance:* konsisten dengan `.sops.yaml`
- [ ] **R7** Bersihkan 9 penanda `Status: **stub**` — *acceptance:* `grep -r "Status: \*\*stub\*\*"` = 0
- [ ] **R8** `namespace` di `galaxy.yml` = akun Galaxy — *acceptance:* `make galaxy-build` sukses
- [ ] **R9** Cek link internal — *acceptance:* 0 tautan mati (mis. `lychee` atau manual)

**Gate fase 0:** DoD-1 tercapai.

---

## 5. Fase 1 — Infrastruktur · `P0` · ~1 hari

- [ ] **I1** 7 VM dibuat di Nutanix sesuai spek (3 CP + 3 worker + jumpbox)
- [ ] **I2** Golden image + cloud-init; `machine-id` & SSH host key unik di semua VM
- [ ] **I3** vDisk etcd terpisah di 3 CP, mount via `LABEL=`
- [ ] **I4** DNS internal: `k8s-api`, `gitlab`, `nexus`, `sonar`, `*.apps` → `kirahadian.local`
- [ ] **I5** Zone Cloudflare `kirahadian.local` + API token tersimpan di SOPS
- [ ] **I6** Baseline hardening jalan di semua VM — *acceptance:* `baseline.yml` 0 failed
- [ ] **I7** Benchmark baseline tersimpan — *acceptance:* `infra/benchmark/results/*-baseline/`
- [ ] **I8** Konektivitas Ansible — *acceptance:* `ansible -m ping vms` semua ok

---

## 6. Fase 2 — Cluster Kubernetes · `P0` · ~1 hari

- [ ] **K1** `ansible-playbook site.yml` selesai tanpa failed
- [ ] **K2** `90-verify.yml` PASS — *acceptance:* 6/6 Ready, etcd 3/3 healthy, encryption at rest aktif
- [ ] **K3** `cilium connectivity test` lulus
- [ ] **K4** **Uji HA**: matikan 1 CP, `kubectl` tetap melayani, hidupkan lagi, node Ready
- [ ] **K5** etcd backup timer aktif + snapshot terkirim ke S3
- [ ] **K6** **Restore drill** — *acceptance:* RTO nyata tercatat di `etcd-restore.md`
- [ ] **K7** kube-bench #1 dijalankan, skor dicatat
- [ ] **K8** Benchmark #2 + tabel delta hardening
- [ ] **K9** `k8s-node.yml` (overlay) PASS — *acceptance:* `k8s_verify` 0 failed

> ⚠️ 21 role Ansible **belum pernah dieksekusi**. Sisihkan 20–30% waktu untuk memperbaiki
> asumsi yang salah. Uji dengan `--limit` per host, jangan langsung `site.yml`.

---

## 7. Fase 3 — Servis pendukung · `P0` · ~1,5 hari

- [ ] **S1** GitLab `external_url` → `https://gitlab.kirahadian.local` + reconfigure
- [ ] **S2** Runner terdaftar dengan token `glrt-` — *acceptance:* job hello-world hijau
- [ ] **S3** Nexus: `oci-hosted` + `docker-proxy` + `k8s-proxy` + npm/maven/pypi proxy
- [ ] **S4** Nexus cleanup policy + task `compact blob store` terjadwal
- [ ] **S5** Nexus port/registry routing — *acceptance:* `docker push` & `pull` lewat Nexus
- [ ] **S6** SonarQube + quality gate + token — *acceptance:* scan project contoh sukses
- [ ] **S7** Object storage (Nutanix Objects atau MinIO) — *acceptance:* `aws s3 ls` ok
- [ ] **S8** Snapshot/PD terjadwal untuk GitLab & Nexus (bukan untuk etcd)

---

## 8. Fase 4 — Aplikasi demo · `P0` · ~2–3 hari

Tanpa ini, pipeline & GitOps tidak ada yang bisa didemokan.

- [ ] **A1** `demo-api` (Go + Postgres): `/healthz`, `/readyz`, `/metrics`, CRUD
- [ ] **A2** `demo-worker`: idempoten, graceful shutdown 30s, metrik queue depth
- [ ] **A3** Dockerfile multi-stage distroless — *acceptance:* image < 30 MB
- [ ] **A4** Unit test + coverage ≥ 70%
- [ ] **A5** Integration test dengan Postgres nyata
- [ ] **A6** `k6` smoke + load dengan threshold SLO (p95 < 200 ms, error < 1%)
- [ ] **A7** Chart/kustomize: Deployment, Service, PDB, NetworkPolicy, ServiceMonitor,
      securityContext (non-root, read-only rootfs, drop ALL)

---

## 9. Fase 5 — CI pipeline · `P0` · ~2–3 hari

- [ ] **C1** BuildKit rootless di cluster — *acceptance:* `buildctl` berhasil dari job
- [ ] **C2** `ci/templates/` 7 file (validate, secret-scan, test, quality, build, scan-sign, release)
- [ ] **C3** gitleaks + `sops filestatus` — *acceptance:* commit secret → pipeline mati
- [ ] **C4** Semgrep SAST — *acceptance:* HIGH memblokir
- [ ] **C5** Trivy fs (vuln + secret + config)
- [ ] **C6** Build → Nexus + SBOM Syft (CycloneDX)
- [ ] **C7** Trivy image fail-closed (HIGH/CRITICAL)
- [ ] **C8** Cosign keyless (GitLab OIDC) — *acceptance:* `cosign verify` sukses, Rekor punya entri
- [ ] **C9** `bump-gitops.sh` — *acceptance:* tag baru ter-commit ke repo GitOps otomatis
- [ ] **C10** Protected branch + push rules + merge train
- [ ] **C11** Artefak (SBOM, report) retensi 90 hari

---

## 10. Fase 6 — SOPS end-to-end · `P0` · ~1 hari

- [ ] **P1** 4 age key: root (offline), ci, cluster, team
- [ ] **P2** Placeholder `PLACEHOLDER_REPLACE_ME` diganti di kedua `.sops.yaml`
- [ ] **P3** Secret nyata dienkripsi (DB, Nexus pull, registry) — *acceptance:* `git log -p` hanya ciphertext
- [ ] **P4** ArgoCD CMP `ksops` + Secret `sops-age` — *acceptance:* ArgoCD render secret
- [ ] **P5** Rotasi diuji (`updatekeys` + `rotate`) — *acceptance:* R5 runbook terbukti
- [ ] **P6** CI dekripsi via `sops exec-env` (key dari OpenBao/CI variable protected)
- [ ] **P7** (opsional) OpenBao sebagai backend key CI

---

## 11. Fase 7 — GitOps · `P0` · ~2 hari

**Titik DoD-2 tercapai di akhir fase ini.**

- [ ] **G1** ArgoCD terpasang (Helm) + SSO GitLab OIDC
- [ ] **G2** RBAC: tidak ada `cluster-admin` untuk manusia, `admin.conf` tidak dibagikan
- [ ] **G3** app-of-apps root Application — *acceptance:* sync `Healthy`
- [ ] **G4** AppProject (batas source & destination)
- [ ] **G5** Overlay dev/staging/prod dengan tag berbeda
- [ ] **G6** ApplicationSet per environment
- [ ] **G7** Argo Rollouts canary 10→50→100 + AnalysisTemplate
- [ ] **G8** Notifikasi Slack/Telegram (sync sukses & gagal)
- [ ] **G9** Prod = manual sync; dev = auto
- [ ] **G10** Uji drift: `kubectl edit` → `selfHeal` mengembalikan
- [ ] **G11** Uji rollback: rilis buruk → canary auto-rollback

---

## 12. Fase 8 — Enforcement keamanan · `P1` · ~3 hari

- [ ] **E1** Kyverno + 6 policy — *acceptance:* `kyverno test` hijau
- [ ] **E2** `verifyImages` Cosign — *acceptance:* image tanpa signature ditolak
- [ ] **E3** Tetragon atau Falco — *acceptance:* alert muncul saat `kubectl exec`
- [ ] **E4** Trivy Operator — *acceptance:* CRD report muncul
- [ ] **E5** Kubescape — *acceptance:* NSA 0 critical
- [ ] **E6** OWASP ZAP baseline vs staging
- [ ] **E7** Renovate — *acceptance:* MR dependency otomatis
- [ ] **E8** **5 drill reproducible**, masing-masing < 5 menit:
      secret bocor · CVE dependency · image tanpa signature · `kubectl delete pod` ·
      error rate → canary rollback
- [ ] **E9** PSA `restricted` terverifikasi di namespace app, `baseline` di kube-system
- [ ] **E10** Threat model diperbarui sesuai implementasi nyata

---

## 13. Fase 9 — Observability & SRE · `P1` · ~2 hari

- [ ] **O1** kube-prometheus-stack — *acceptance:* semua target up
- [ ] **O2** Grafana Alloy + Loki — *acceptance:* log pod & audit log masuk
- [ ] **O3** Tempo + OTel Collector — *acceptance:* 1 trace end-to-end
- [ ] **O4** Sloth SLO + multi-window burn-rate alert
- [ ] **O5** 4 dashboard: golden signals · SLO/error budget · security posture · DORA
- [ ] **O6** Alertmanager → Slack/Telegram — *acceptance:* alert benar-benar terkirim
- [ ] **O7** Audit log apiserver → Loki + query contoh
- [ ] **O8** DORA metrics (lead time, deploy freq, CFR, MTTR)

---

## 14. Fase 10 — Compliance otomasi · `P2` · ~1,5 hari

Prasyarat: Fase 9 (Prometheus + Pushgateway).

- [ ] **M1** USG audit baseline semua VM (tanpa `usg fix`)
- [ ] **M2** `usg/tailoring.xml` sesuai ADR-0010
- [ ] **M3** CronJob kube-bench untuk 6 node (pinned `nodeName`)
- [ ] **M4** Metrik `compliance_score` + `compliance_unexpected_failures` ke Pushgateway
- [ ] **M5** Dashboard tren + alert penurunan > 5 poin / 7 hari
- [ ] **M6** Delta hardening terdokumentasi (sebelum vs sesudah)

---

## 15. Fase 11 — Portofolio · `P2` · ~2 hari

- [ ] **F1** README: badge + 6 GIF (satu per drill)
- [ ] **F2** Video 5 menit tanpa perlu penjelasan
- [ ] **F3** Docs site (Astro Starlight / GitHub Pages) publik
- [ ] **F4** Diagram arsitektur final
- [ ] **F5** ADR baru untuk keputusan yang muncul saat implementasi
- [ ] **F6** Bagian "What I'd do differently" — jujur dan spesifik
- [ ] **F7** Repo topics + pinned di profil
- [ ] **F8** Live demo on-request (Tailscale Funnel / Cloudflare Tunnel, auto-expire)
- [ ] **F9** Skrip demo interview (urutan drill + timing)

---

## 16. Critical path

Jalur terpendek menuju demo inti (`git push` → app jalan):

```
Fase 0 (0,5d) → Fase 1 (1d) → Fase 2 (1d) → Fase 3 (1d)
              → Fase 4 (2d) → Fase 5 (2,5d) → Fase 6 (1d) → Fase 7 (2d)
                                              ≈ 11 hari kerja
```

Fase 8–11 adalah kedalaman, bukan syarat demo.

---

## 17. Yang boleh dipotong bila waktu mepet

| Dipotong | Konsekuensi |
|---|---|
| A2 `demo-worker` | kehilangan demo KEDA/PDB |
| O3 Tempo | tracing hilang, observability tetap jalan |
| E6 ZAP | kehilangan cerita DAST |
| Fase 10 | tetap ada laporan manual |
| F3 docs site | cukup README + video |

**Jangan dipotong:** K4 (uji HA) · K6 (restore drill) · C8 (cosign) · E2 (verifyImages) ·
G7/G11 (canary + rollback). Kelima hal ini yang membuat orang percaya.

---

## 18. Estimasi

| Skenario | Hari kerja | @15 jam/minggu |
|---|---|---|
| MVP (Fase 0–7 + E1–E2) | ~11 hari | ~6 minggu |
| Lengkap (Fase 0–11) | ~19–21 hari | ~10–12 minggu |

---

## 19. Risiko utama

| Risiko | Mitigasi |
|---|---|
| 21 role Ansible belum pernah dijalankan | uji `--limit jumpbox` → satu VM → satu node |
| BuildKit rootless paling sering makan waktu | siapkan fallback Buildah |
| `.local` + DNS-01 Cloudflare | uji TLS wildcard sebelum Fase 4 |
| SonarQube Community Build tanpa PR analysis | sudah diketahui (ADR-0012), jangan kaget |
| `usg fix` merusak node hidup | audit + tailoring saja |
| Repo di dalam OneDrive | pindahkan ke `C:\dev\` sebelum kerja intensif |

---

## 20. Log

| Tanggal | Perubahan |
|---|---|
| 2026-11-23 | Dokumen dibuat. Fase 0 masih terbuka (9 stub, LICENSE belum ada). |
