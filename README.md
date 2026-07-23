# AjipIDM — Progress & Documentation

> Strategy: Inducement-centric SMC untuk MT5 EA. Simple structure (SL/SH) tanpa VH/VL. Entry = idm taken + no body break → fade dengan configurable RR. Multi-position dengan invalidation (body-break sweep → TP to BE).

---

## 1. Konsep Inti

AjipIDM berbeda dari AjipSMC dalam hal:

| Aspek | AjipSMC | AjipIDM |
|-------|---------|---------|
| Structure levels | SL/SH + VH/VL (Weak) | SL/SH saja |
| idm role | Trigger untuk Weak confirmation | Trigger reversal trend |
| idm taken effect | Confirm Weak, cycle berhenti | Trend SELALU berubah |
| Entry | OF/OB/FVG analysis | idm taken + no body break → fade |
| Entry direction | Trend-following (menuju Weak) | Counter-trend (sweep/fakeout) |
| Target | Weak VL/VH | Swing terakhir di struktur baru |
| RR | 1:2 minimum | Configurable via InpRR (1:1, 1:2, 1:0.5, dll) |
| SL | Hybrid structural + ATR | Derived dari TP distance / RR, atau no SL (RR=0) |
| Platform | Python + TradingView | MT5 EA (MQL5) |

### Naming Convention

```
Uptrend:   SLU0 → SHU1 → SLU1 → SHU2 → SLU2 → ...
           SLU = Simple Low Up,  SHU = Simple High Up
           SLU must be HL, SHU must be HH

Downtrend: SHD0 → SLD1 → SHD1 → SLD2 → SHD2 → ...
           SHD = Simple High Down,  SLD = Simple Low Down
           SHD must be LH, SLD must be LL
```

### idm Definition

idm = swing TERAKHIR dari tipe inducement yang memiliki swing berlawanan setelahnya:
- Uptrend: idm = SL terakhir yang punya SH setelahnya (bukan SL dangling di akhir)
- Downtrend: idm = SH terakhir yang punya SL setelahnya (bukan SH dangling di akhir)

Implementasi (`UpdateIdm`): walk backward dari index n-2, skip swing terakhir (dangling).
Swing terakhir di array TIDAK pernah jadi idm — pasti ada swing baru setelahnya.

idm TIDAK bergeser meski wick lebih dalam. Yang penting hanya close vs idm level.

### idm Taken → Trend Change (ALWAYS)

Saat idm taken (candle low/high menembus idm level):
1. Trend SELALU berubah — regardless of body break
2. Build struktur baru dari titik ekstrem sebelumnya
3. Cek close candle untuk entry decision

### Entry Rules

**BUY** (uptrend → idm taken dari bawah):
```
Condition: candle low < SLU_last (idm) AND close > SLU_last
→ No body break = sweep/fakeout
→ BUY @ close price
TP = SHD terakhir di downtrend structure baru
SL = entry - (tpDistance / InpRR)    (RR=0 → no SL)
```

**SELL** (downtrend → idm taken dari atas):
```
Condition: candle high > SHD_last (idm) AND close < SHD_last
→ No body break = sweep/fakeout
→ SELL @ close price
TP = SLU terakhir di uptrend structure baru
SL = entry + (tpDistance / InpRR)    (RR=0 → no SL)
```

**Body break = no entry:**
- Uptrend idm: close < SLU_last → downtrend confirmed, lanjut track
- Downtrend idm: close > SHD_last → uptrend confirmed, lanjut track

### Entry Invalidation (body break setelah entry)

Entry premise: idm sweep (wick takes idm) tapi close reclaim. 

**Sweep level** = high/low bar yang ambil idm (bukan idm price):
- BUY: sweep level = LOW bar yang sweep
- SELL: sweep level = HIGH bar yang sweep

**Sweep update:** jika bar berikutnya sweep lebih dalam, update sweep level.

**Body break = invalidasi:** close menembus sweep level TERBARU → premise gagal:
```
BUY invalid:  close < sweep level → modify TP to break-even (entry price)
SELL invalid: close > sweep level → modify TP to break-even (entry price)
```

TP digeser ke BE, SL tetap. Posisi TIDAK di-close — biarkan broker manage.

**Multi-position:** tiap entry ditrack per-ticket (EntryTracker array: ticket, sweepPrice, dir).
Auto-cleanup: posisi yang sudah TP/SL hit otomatis di-remove dari tracking.

**Body break dievaluasi SEBELUM sweep update** (fix bug: sweep update duluan menyembunyikan body break).
Invalidasi dievaluasi pada CLOSED bar, BEFORE CheckIdmTaken.

---

## 2. EA Architecture

File: `/Users/pijarajip/AIProjects/AjipIDM/AjipIDM.mq5`

### Input Parameters

```
InpTimeframe    = PERIOD_M15     — Working timeframe
InpTargetAmount = 100.0          — Target profit per trade (USD)
InpCandlesInit  = 50             — Lookback candles untuk initial trend
InpDeviation    = 10             — Slippage (points)
InpMagicNumber  = 99001          — Magic number
InpDrawLines    = true           — Draw structure lines on chart
InpMaxLines     = 500            — Max trendline objects
InpRR           = 1.0            — Risk:Reward (1=1:1, 2=1:2, 0.5=1:0.5, 0=NO SL)
InpMinTpPoints  = 0              — Min TP distance in points (0=no filter)
```

### Init

```
1. Ambil 50 candle terakhir (CopyRates)
2. Cari highest high dan lowest low
3. Tentukan trend awal by chronological order:
   - High sebelum low → downtrend (SHD0 = highest high)
   - Low sebelum high → uptrend (SLU0 = lowest low)
4. Build simple structure forward dari origin
5. Tunggu event baru (tidak entry di kondisi existing)
```

### OnTick

```
1. Detect new closed bar (via g_lastBarTime)
2. UpdateStructure: pullback detection + simple structure build
3. CheckEntryInvalidation: untuk semua tracked entries:
   - Body break? (close menembus sweep level) → TP to BE, remove tracking
   - Sweep update? (deeper sweep, jika tidak body break) → update sweep level
   - Auto-cleanup: posisi yang sudah closed → remove tracking
4. CheckIdmTaken: cek idm taken pada closed bar
5. If entry: place MT5 order, AddEntry to tracking
6. Multi-position — tidak ada batasan jumlah posisi
```

### Position Management

- TP/SL: physical MT5 orders (broker manage). InpRR=0 → no SL.
- Lot size: dari target_amount dan TP distance
  ```
  gainPerLot = (tpDistance / tickSize) * tickValue
  lot = InpTargetAmount / gainPerLot
  ```
- Multi-position — tidak ada batasan jumlah posisi terbuka
- Entry invalidation: body-break sweep → TP to BE (tidak close posisi)
- After TP/SL/BE hit → continue tracking untuk next signal

---

## 3. Swing Detection — 2-Stage Algorithm

### Stage 1: Pullback (base_candle tracking)

Reference: `perception-alignment.md` Stage 1.

Menggunakan satu running reference candle (`base_candle`):

| Phase | Reference | Trigger switch | Hasil |
|-------|-----------|---------------|-------|
| UP | base_up (highest-high candle) | Bar low < base_up.low → pullback_down | Record HI = base_up.high. Switch DOWN. |
| UP | base_up | Bar high > base_up.high → continuation up | Bar jadi base_up baru |
| DOWN | base_down (lowest-low candle) | Bar high > base_down.high → pullback_up | Record LO = base_down.low. Switch UP. |
| DOWN | base_down | Bar low < base_down.low → continuation down | Bar jadi base_down baru |

Aturan:
- Comparison STRICT (`>` / `<`), bukan `>=` / `<=`
- Tidak ada minimum swing deviation
- Pakai full candle high/low (termasuk wick)
- HI dan LO tidak pernah di bar yang sama
- Output: alternating HI → LO → HI → LO → ...

Catatan: Outside bar ditangani via pending resolution (lihat Known Limitations).

### Outside Bar Handling (pending resolution)

Outside bar = bar yang break BOTH base.high AND base.low. Implementasi di `DetectPullback`:

1. Simpan outside bar sebagai `g_outsideBar`, set `g_outsidePending = true`
2. Jangan record swing dulu — tunggu bar berikutnya resolve:
   - **PHASE_UP:**
     - Next breaks outside.high → continuation UP, commit outside.low sebagai SL
     - Next breaks outside.low → reversal DOWN, commit outside.high sebagai SH
   - **PHASE_DOWN:**
     - Next breaks outside.low → continuation DOWN, commit outside.high sebagai SH
     - Next breaks outside.high → reversal UP, commit outside.low sebagai SL
3. Outside bar bisa extend jika bar berikutnya lebih extreme sebelum resolve
4. Reset di InitStructure, ReverseToDowntrend, ReverseToUptrend

### Stage 2: Simple Structure (filter dengan trend rules)

Reference: `perception-alignment.md` Stage 2.2.

Dari pullback swings, commit ke simple structure hanya jika memenuhi trend rules:

**Filter approach (bukan merge):**
1. Origin = first pullback swing → always committed
2. Setiap pullback swing berikutnya:
   - Must be opposite type to last committed (alternation)
   - Must satisfy trend rule vs last committed of same type
3. Kalau violate trend rule → SKIP swing tersebut

**Premature update handling:**
Jika pullback swing baru same type dengan last committed dan lebih extreme:
- SH baru lebih tinggi dari SH lama → POP swing lama, commit yang baru
- SL baru lebih rendah dari SL lama → POP swing lama, commit yang baru
- Setelah pop, backtrack lastIdx ke swing terakhir yang tersisa

**Trend rules:**
- Uptrend: SH must be HH, SL must be HL
- Downtrend: SH must be LH, SL must be LL

**Contoh (downtrend):**
```
Pullback: SH(origin) → SL(4132) → SH(4138.92) → SL(4132.92) → SH(4137.17)

Filter:
1. SH(origin) → committed
2. SL(4132) → first SL → committed
3. SH(4138.92) → LH vs origin → committed
4. SL(4132.92) → LL check: 4132.92 < 4132? TIDAK → SKIP
5. SH(4137.17) → same type as last committed (4138.92) → SKIP

Hasil: [SH(origin), SL(4132), SH(4138.92)]
```

---

## 4. Chained Example (Full Cycle)

```
1. UP: SLU0(100) - SHU1(110) - SLU1(105) - SHU2(115) - SLU2(108, idm) - SHU3(120)
2. Price dari SHU3 turun, candle low = 107 (< SLU2=108) → IDM TAKEN
   Trend → DOWN. Build dari SHU3(120) = SHD0
   Retroactive structure: SHD0(120) - SLD1(112) - SHD1(118) - SLD2(107)
3. Candle close = 109 (> SLU2=108) → BUY @ 109
   TP = SHD1 = 118 (last SHD before SLD2)
   tpDistance = 118 - 109 = 9
   SL = 109 - (9 / InpRR)    (RR=1 → SL=100, RR=2 → SL=104.5)

4. Price naik ke 118 (= TP hit). Position closed.
5. At 118, candle high > SHD1 → IDM TAKEN untuk downtrend
   Trend → UP. Build dari SLD2(107) = SLU0
   Candle close < SHD1 → SELL @ close
   TP = SLU terakhir di uptrend structure baru
   SL = entry + (tpDistance / InpRR)
```

---

## 5. Bug Fixes History

### Round 1: Basic structure
1. New-bar detection — avoid reprocessing same bar every tick
2. Typo `highest = highest` di InitStructure
3. CheckIdmTaken logic rewrite — clean doEntry/entryBuy flags

### Round 2: Running var init
4. ReverseToDowntrend/Up: running vars init dari origin bar OHLC
5. Running max/min init: DBL_MAX/-DBL_MAX (prevent first-bar contamination)
6. RebuildStructure: skip origin bar + correct CopyRates start_pos
7. InitStructure: exclude current forming bar + correct g_lastBarTime

### Round 3: SL/SH same bar rule
8. UpdateUptrend/Down: check commit condition FIRST, commit SL from previous bar only
9. Reset tracking vars to sentinel after commit (not bar values)

### Round 4: Pullback detection (major rewrite)
10. Implementasi base_candle tracking dari perception-alignment.md
11. Pisahkan Stage 1 (pullback) dan Stage 2 (simple structure)
12. AddPbSwing/ResetPbSwings untuk pullback swing array terpisah

### Round 5: Trend rules enforcement
13. Filter approach: commit pullback swing hanya jika satisfy trend rules
14. Alternation enforcement: skip same-type swing jika last committed belum opposite
15. Origin protection: first swing always committed

---

## 6. Known Limitations & TODO

### Belum diimplementasi
- [ ] Backtest di Strategy Tester
- [ ] Forward test live

### Potential improvements
- [ ] Minimum swing deviation filter (opsional, user bisa enable/disable)
- [ ] Logging yang lebih detail untuk debugging structure
- [ ] Alert/notification saat idm taken dan entry dibuka

---

## 7. Files

| File | Deskripsi |
|------|-----------|
| `/Users/pijarajip/AIProjects/AjipIDM/AjipIDM.mq5` | EA MQL5 source code |
| `~/.hermes/skills/trading/ajipidm/SKILL.md` | Skill documentation |
| `/Users/pijarajip/Claude/Projects/AjipSMC/docs/perception-alignment.md` | Reference: pullback & simple structure rules |

---

## 8. Session History

### Session 1 (2026-07-22): Concept Finalization
- Brainstorm konsep ajipIDM dari AjipSMC
- Definisi idm, entry rules, RR 1:1
- Decision: MT5 EA (bukan Pine Script)
- Spec final confirmed

### Session 2 (2026-07-23): Implementation
- Code EA MQL5 (~975 lines)
- 15 bug fixes across 5 rounds
- Major rewrite: pullback detection dengan base_candle tracking
- Filter approach untuk trend rules (bukan merge)
- Structure validation: SL/SH tidak di bar yang sama, trend monotonicity

### Session 3 (2026-07-23): Repository init + README sync
- Git init di `/AIProjects/AjipIDM/` (pindah dari `/AIProjects/Campur/`)
- README sync dengan code aktual:
  - idm definition: exclude dangling last swing (walk backward dari n-2)
  - Stage 2: dokumentasi premature update handling (pop + recommit)
  - Outside bar: ditangani implisit (continuation wins atas pullback)
  - Hapus stale TODO: merge post-process (replaced by filter), CHoCH/BOS (by design tidak perlu)
  - Fix semua file path references

### Session 4 (2026-07-23): Entry invalidation + RR + outside bar + multi-position
- Entry invalidation: body-break sweep level → modify TP to break-even (bukan close)
- Sweep level = bar high/low (bukan idm price), update jika sweep lebih dalam
- Body break dievaluasi SEBELUM sweep update (fix bug)
- Outside bar: pending resolution (break both → tunggu next bar resolve)
- InpRR: configurable risk:reward (0=no SL)
- InpMinTpPoints: filter entry dengan TP distance minimum
- InpTargetAmount (replaces InpRiskAmount): lot dari TP distance
- Multi-position: EntryTracker array, hapus batasan 1 posisi
- OpenTrade returns ticket (ulong)
