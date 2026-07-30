# AjipIDM — Progress & Documentation

> Strategy: Inducement-centric SMC untuk MT5 EA. Simple structure (SL/SH) tanpa VH/VL. Entry = idm taken + no body break → fade, digating equilibrium HTF. Fixed lot, tanpa SL/TP — exit via one-time partial close (points) + daily target/max loss close-all.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, naming convention, idm definition, entry rules, HTF equilibrium gate, partial close, daily close-all, contoh full cycle |
| [docs/architecture.md](docs/architecture.md) | Input parameters, info panel, Init/OnTick flow, position management |
| [docs/swing-detection.md](docs/swing-detection.md) | 2-stage swing detection algorithm (pullback + simple structure) |
| [docs/bugfixes.md](docs/bugfixes.md) | Riwayat bug fix (10 round) |
| [docs/sessions.md](docs/sessions.md) | Session history (dev log per sesi) |

---

## Known Limitations & TODO

### Belum diimplementasi
- [ ] Backtest di Strategy Tester
- [ ] Forward test live

### Potential improvements
- [ ] Minimum swing deviation filter (opsional, user bisa enable/disable)
- [ ] Logging yang lebih detail untuk debugging structure
- [ ] Alert/notification saat idm taken dan entry dibuka

---

## Files

| File | Deskripsi |
|------|-----------|
| `AjipIDM.mq5` | EA MQL5 main file — inputs, OnInit, OnTick |
| `AjipIDM_Globals.mqh` | Global state, structs, enum, helper functions |
| `AjipIDM_Pullback.mqh` | Stage 1: base_candle pullback detection + outside bar |
| `AjipIDM_Structure.mqh` | Stage 2: simple structure build (filter + premature update) |
| `AjipIDM_Reversal.mqh` | ReverseToDowntrend/Up + RebuildStructure (live replay) |
| `AjipIDM_Entry.mqh` | CheckIdmTaken + entry logic + partial close + daily close-all |
| `AjipIDM_Trade.mqh` | OpenTrade (fixed lot), CloseAllPositions, swing helpers, MFE/MAE CSV export |
| `AjipIDM_Core.mqh` | InitStructure, OnTick dispatch |
| `AjipIDM_HtfContext.mqh` | HTF trend filter — trimmed structure/idm engine (context-only, no trading) + chart drawing |
| `AjipIDM_Panel.mqh` | On-chart info panel — trend, HTF trend, today/week/month realized P/L, live open MFE/MAE |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture (inputs, Init/OnTick, position management) |
| `docs/swing-detection.md` | 2-stage swing detection algorithm |
| `docs/bugfixes.md` | Bug fixes history |
| `docs/sessions.md` | Session history |
| `~/.hermes/skills/trading/ajipidm/SKILL.md` | Skill documentation |
| `docs/perception-alignment.md` (project lain: AjipSMC) | Reference: pullback & simple structure rules |
