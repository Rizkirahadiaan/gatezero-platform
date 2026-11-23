# Runbooks

Prosedur operasional. Ditulis supaya orang lain (atau kamu 6 bulan kemudian) bisa mengeksekusi
tanpa menebak.

| Runbook | Status | Kapan dipakai |
|---|---|---|
| [`etcd-restore.md`](etcd-restore.md) | ✅ | etcd korup / quorum hilang / rollback data |
| [`node-upgrade.md`](node-upgrade.md) | ✅ | patch OS, upgrade kubelet, upgrade versi kubernetes |
| [`secret-rotation.md`](secret-rotation.md) | ✅ | rotasi age key, kredensial DB/registry, encryption key etcd |
| `cis-remediate.md` | ⬜ | menindaklanjuti temuan kube-bench / Lynis |
| `incident-response.md` | ⬜ | pod aneh, alert Tetragon, image tak dikenal |
| `argo-rollback.md` | ⬜ | rilis buruk, rollback canary |
| `break-glass.md` | ⬜ | akses darurat ke cluster saat SSO mati |

Runbook yang masih `⬜` dilacak di [`ROADMAP.md`](../../ROADMAP.md) (Fase 0 `R3`-`R5`,
sisanya menyusul saat fase terkait dikerjakan).

## Format wajib

Setiap runbook berisi: **Gejala → Dampak → Prasyarat → Langkah → Verifikasi → Rollback**.
Bagian "Verifikasi" tidak boleh kosong — runbook tanpa cara verifikasi adalah tebakan.
