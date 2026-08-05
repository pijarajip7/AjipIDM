# AjipIDM — Progress & Documentation

> Strategy: Inducement-centric SMC untuk MT5 EA. Simple structure (SL/SH) tanpa VH/VL. Entry dipicu sentuhan zone idm + no body break → fade, digating equilibrium HTF + trading session + news blackout. Reversal struktur dipisah total dari entry. Fixed lot, tanpa SL/TP di entry — exit via one-time partial close (lalu SL ke breakeven) + batch target/max loss (tutup batch saja) + daily target/max loss (tutup semua, blokir entry sisa hari) + final target/max loss (berhenti permanen) + profit-lock di luar sesi. Aggregate SL sebagai jaring pengaman broker-side.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, naming convention, idm definition, entry rules, HTF equilibrium gate, partial close, batch/daily close-all, trading session, contoh full cycle |
| [docs/architecture.md](docs/architecture.md) | Input parameters, info panel, Init/OnTick flow, position management |
| [docs/swing-detection.md](docs/swing-detection.md) | 2-stage swing detection algorithm (pullback + simple structure) |
| [docs/bugfixes.md](docs/bugfixes.md) | Riwayat bug fix (15 round) |
| [docs/sessions.md](docs/sessions.md) | Session history (dev log per sesi) |

---

## Known Limitations & TODO

### Belum diimplementasi
- [ ] Forward test live
- [ ] Compile & backtest untuk `InpAllowHedging=false` (input baru, belum diuji)

### Potential improvements
- [ ] Minimum swing deviation filter (opsional, user bisa enable/disable)
- [ ] Alert/notification saat idm taken dan entry dibuka
- [ ] Minimum hold time (banyak prop firm CFD mensyaratkan; jalur per-tick saat
      ini bisa menghasilkan trade berdurasi detik)

### Catatan kompatibilitas prop firm
EA ini punya tiga karakteristik yang sering masuk daftar terlarang: **hedging**
(sudah bisa dimatikan lewat `InpAllowHedging`), **entry per-tick** yang bisa
terbaca sebagai tick scalping/HFT (`InpUseAggressiveEntry`), dan **posisi dibuka
tanpa SL** (aggregate SL menyusul belakangan, bukan saat entry). Verifikasi
rulebook firm sebelum menjalankan.

---

## Files

| File | Deskripsi |
|------|-----------|
| `AjipIDM.mq5` | EA MQL5 main file — inputs, OnInit, OnTick |
| `AjipIDM_Globals.mqh` | Global state, structs, enum, helper functions |
| `AjipIDM_Pullback.mqh` | Stage 1: base_candle pullback detection + outside bar |
| `AjipIDM_Structure.mqh` | Stage 2: simple structure build (filter + premature update) |
| `AjipIDM_Reversal.mqh` | ReverseToDowntrend/Up + RebuildStructure (live replay) |
| `AjipIDM_Entry.mqh` | Reversal (CheckIdmTaken/CheckAggressiveIdmTouch) + entry terpisah (CheckIdmZoneEntry/CheckAggressiveZoneEntry) + partial close + aggregate SL + lot cap/hedge gate + restart recovery |
| `AjipIDM_Trade.mqh` | OpenTrade (fixed lot), CloseAllAndFlushBatch, final/batch/daily/session close-all, session filter, batch cooldown, swing helpers, batch CSV report, handoff/heartbeat |
| `AjipIDM_News.mqh` | News blackout — gate entry di sekitar rilis kalender high-impact |
| `AjipIDM_Core.mqh` | InitStructure, UpdateStructure |
| `AjipIDM_HtfContext.mqh` | HTF trend filter — trimmed structure/idm engine (context-only, no trading) + chart drawing |
| `AjipIDM_Panel.mqh` | On-chart info panel — trend, HTF trend, today/week/month realized P/L, live open MFE/MAE |
| `orchestrator/` | Python: rotasi multi-akun (orchestrator.py), dashboard monitoring (dashboard.py), launcher (run.py) |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture (inputs, Init/OnTick, position management) |
| `docs/swing-detection.md` | 2-stage swing detection algorithm |
| `docs/bugfixes.md` | Bug fixes history |
| `docs/sessions.md` | Session history |
| `~/.hermes/skills/trading/ajipidm/SKILL.md` | Skill documentation |
| `docs/perception-alignment.md` (project lain: AjipSMC) | Reference: pullback & simple structure rules |
