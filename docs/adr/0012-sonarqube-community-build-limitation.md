# ADR-0012: Strategi quality gate dengan keterbatasan SonarQube Community Build

- **Status:** Accepted
- **Tanggal:** 2026-11-23
- **Konteks:** SonarQube Community Build (gratis) tidak mendukung branch/PR analysis — itu fitur
  Developer Edition. Tanpa strategi, quality gate hanya berjalan sebagian dan mudah dianggap
  "sudah aman padahal belum".

## Keputusan

1. Quality gate dijalankan **blocking di branch utama** (`main`) untuk setiap merge.
2. **Merge request diblokir oleh gate lain** (Semgrep, Trivy, unit test) yang bisa berjalan
   per-branch — bukan hanya SonarQube.
3. SonarQube tidak dijadikan satu-satunya penentu kualitas.
4. Keterbatasan ini dicatat sebagai known limitation, bukan disembunyikan.

## Kenapa penting

Banyak portofolio DevOps memasang SonarQube dan mengklaim "quality gate enforced", padahal di
Community Build gate hanya menganalisis branch default. Menyebutkan batasan ini secara eksplisit
lebih meyakinkan daripada mengklaim lebih.

## Pembagian tanggung jawab gate

| Gate | Per-branch | Blocking | Menangkap |
|---|---|---|---|
| Semgrep | ya | ya | bug pattern, injection, hardcoded secret |
| Trivy fs | ya | ya | CVE dependency |
| Unit test + coverage | ya | ya | regresi logika |
| gitleaks | ya | ya | secret bocor |
| SonarQube | **tidak** (Community Build) | ya, di `main` | code smell, duplikasi, coverage trend |
| Kyverno/Conftest | ya | ya | manifest tidak aman |

## Konsekuensi

### Positif
- Tidak ada klaim berlebih; arsitektur gate realistis.
- Merge request tetap punya gate nyata lewat Semgrep + Trivy + test.

### Negatif
- Coverage/duplikasi baru terdeteksi setelah merge ke `main`, bukan di MR.
- Developer bisa merge kode dengan duplikasi tinggi lalu pipeline `main` gagal → butuh disiplin
  "fix forward" atau revert.

## Alternatif yang ditolak

| Alternatif | Alasan |
|---|---|
| Beli SonarQube Developer Edition | Biaya tidak sepadan untuk portofolio pribadi |
| Ganti ke SonarCloud | Gratis untuk repo publik, tapi menghilangkan bagian self-hosting |
| Hanya memakai Semgrep | Melewatkan analisis duplikasi/coverage yang jadi nilai SonarQube |

## Catatan upgrade

Bila suatu saat naik ke Developer Edition: aktifkan `sonar.pullrequest.*`, dekorasi MR, dan
gate per-PR. Perubahan itu dicatat sebagai ADR baru.
