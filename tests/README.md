# Tests

| Folder | Isi | Dijalankan |
|---|---|---|
| `unit/` | unit test per package (Go: `_test.go` akan tinggal di `apps/`, folder ini untuk test helper/fixture) | setiap MR |
| `integration/` | test terhadap Postgres + API nyata (testcontainers / compose) | setiap MR (stage `test`, butuh service container) |
| `k6/` | load test + SLO gate | nightly & sebelum rilis prod |

## Prinsip

1. **Test cepat di MR, lambat di nightly.** k6 tidak boleh memblokir MR.
2. **k6 punya threshold = SLO**, bukan sekadar "bisa jalan":
   ```js
   export const options = {
     thresholds: {
       http_req_duration: ['p(95)<200'],
       http_req_failed:   ['rate<0.01'],
     },
   };
   ```
   Kalau threshold gagal, pipeline gagal. Ini yang membuat SLO punya gigi.
3. **Integration test memakai Postgres sungguhan**, bukan mock — karena bug yang paling sering
   lolos ke produksi ada di SQL.
4. **Test harus deterministik.** `-count=1`, tanpa `time.Sleep` panjang, tanpa dependensi jaringan
   luar di unit test.

## Struktur k6

```
k6/
├── smoke.js        # 1 VU, 30s — cek deploy hidup
├── load.js         # 50 VU, 5m — baseline performa
├── stress.js       # naik bertahap sampai p95 rusak — cari batas
└── lib/{config.js,checks.js}
```

## Gate

| Test | Gate |
|---|---|
| unit | coverage ≥ 70% pada package baru |
| integration | 0 failure |
| k6 smoke | p95 < 500 ms (post-deploy) |
| k6 load | p95 < 200 ms, error < 1% (nightly) |

> **Status:** test belum ada. Item `A4`-`A6` di [ROADMAP](../ROADMAP.md).
