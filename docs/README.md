# Dokumentasi

| Folder / file | Isi |
|---|---|
| [`../ROADMAP.md`](../ROADMAP.md) | checklist penyelesaian + acceptance criteria |
| `adr/` | Architecture Decision Record — kenapa, bukan apa |
| `runbooks/` | langkah operasional saat insiden / perubahan |
| `nexus.md` | Nexus OSS sebagai artifact hub |
| `architecture.drawio` | diagram arsitektur (buka di draw.io / VS Code extension) |

## Kenapa ADR

Portofolio tools menunjukkan *apa yang dipakai*. ADR menunjukkan *cara berpikir*: pilihan apa yang
ditolak, trade-off apa yang diterima, dan risiko apa yang disadari. Reviewer senior membaca ADR
lebih lama daripada membaca README.

Format tiap ADR: Status, Konteks, Keputusan, Konsekuensi, Alternatif yang ditolak.

## Menambah ADR

```bash
# nomor berikutnya, jangan pernah hapus/ganti nomor lama
docs/adr/00NN-judul-singkat.md
```

Lalu tambahkan baris di tabel `adr/README.md`.
