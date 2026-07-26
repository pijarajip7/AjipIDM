# AjipIDM — EA Architecture

Files: `AjipIDM.mq5` (main) + 9 `.mqh` includes (see Files table in [README.md](../README.md)).

## Input Parameters

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
InpDailyMaxProfit = 0.0          — Daily max profit in account currency (0=disabled)
InpDailyMaxLoss   = 0.0          — Daily max loss in account currency (0=disabled)
InpInvalidationMode     = INVALIDATION_DO_NOTHING — Aksi TP saat body-break invalidasi (DO_NOTHING / FIXED_TP)
InpInvalidationTpPoints = 300     — Fixed TP points dari entry (dipakai jika mode=FIXED_TP; 0=break-even)
InpUseHtfFilter = false          — Enable HTF trend filter on entries
InpHtfTimeframe = PERIOD_H1      — Higher timeframe untuk trend filter
InpUseEquilibriumFilter = false  — Skip entry jika close melewati equilibrium (midpoint sweep→TP)
InpShowPanel    = true           — Show info panel (trend + P/L) on chart
InpPanelCorner  = CORNER_LEFT_UPPER — Panel corner
InpPanelX       = 10             — Panel X offset (px)
InpPanelY       = 20             — Panel Y offset (px)
```

## Info Panel (opsional)

Dashboard on-chart, refresh SEKALI PER CLOSED LTF BAR (bukan timer — supaya behavior identik live dan di Strategy Tester, konsisten dengan cadence seluruh EA yang bar-driven):

```
AjipIDM
Trend:     UP / DOWN / NONE     (warna: hijau/merah/abu-abu)
HTF Trend: UP / DOWN / NONE / OFF (OFF jika InpUseHtfFilter=false)
Today P/L: <realized, deals hari ini>
Week P/L:  <realized, sejak Senin 00:00>
Month P/L: <realized, sejak tanggal 1 00:00>
Open MFE:  <sum floating best-case, semua posisi open>
Open MAE:  <sum floating worst-case, semua posisi open>
```

P/L dihitung dari realized deals (symbol + magic number sama), sama persis definisinya dengan `GetDailyPnL` yang dipakai daily-limit — BUKAN floating/unrealized PnL posisi terbuka. Object chart pakai prefix `g_panelPrefix` ("AjipIDMPanel_"), terpisah dari `g_objPrefix` ("AjipIDM_") supaya tidak ke-wipe oleh `ObjectsDeleteAll` di `DrawSwings()`.

Open MFE/MAE beda dari baris P/L di atas: ini floating (bukan realized), disum dari `g_entries[].mfe`/`.mae` — lihat [MFE/MAE Tracking](#mfemae-tracking) di bawah.

## MFE/MAE Tracking

Setiap posisi open ditrack Max Favorable/Adverse Excursion-nya dalam $ (account currency), berbasis `PositionGetDouble(POSITION_PROFIT)` — bukan hitung manual dari price/point, supaya otomatis benar untuk lot size & symbol currency apa pun.

```
UpdateMfeMae() dipanggil TIAP TICK (bukan per-bar) — supaya excursion intra-bar
kecatat, bukan cuma extreme di closed bar:
  untuk tiap tracked entry:
    profit = PositionGetDouble(POSITION_PROFIT)
    mfe = max(mfe, profit)
    mae = min(mae, profit)
```

Saat posisi terdeteksi closed (TP/SL/BE hit — dicek di `CheckEntryInvalidation`), `WriteTradeCsv()` dipanggil SEBELUM entry dihapus dari tracking:
- Query exit info dari `HistorySelectByPosition(ticket)`: exit price/time, close reason (TP/SL/STOPOUT/OTHER dari `DEAL_REASON`), realized P/L.
- Append 1 baris ke `MQL5/Files/AjipIDM_Trades_<symbol>_<magic>.csv` (dibuat otomatis kalau belum ada, header ditulis sekali).
- Kolom: `Ticket,Dir,EntryTime,EntryPrice,ExitTime,ExitPrice,CloseReason,RealizedPnL,MFE,MAE`.

Catatan:
- Body-break invalidation (`InpInvalidationMode`) TIDAK menutup posisi — jadi tidak memicu CSV write. Row CSV hanya ditulis saat posisi BENAR-BENAR closed di broker (TP/SL/BE).
- Di Strategy Tester, file CSV ada di folder sandbox agent tester (`Tester/Agent-xxx/MQL5/Files/`), bukan folder terminal utama — kalau run optimization paralel, tiap agent punya file sendiri (tidak digabung otomatis).
- `entryPrice`/`entryTime` diambil dari `POSITION_PRICE_OPEN`/`POSITION_TIME` saat `AddEntry` dipanggil (persis setelah `OpenTrade` sukses), bukan dari `bar.close` — jadi merefleksikan actual fill price broker.

## Init

```
1. Ambil 50 candle terakhir (CopyRates)
2. Cari highest high dan lowest low
3. Tentukan trend awal by chronological order:
   - High sebelum low → downtrend (SHD0 = highest high)
   - Low sebelum high → uptrend (SLU0 = lowest low)
4. Build simple structure forward dari origin
5. Tunggu event baru (tidak entry di kondisi existing)
```

## OnTick

```
0. (jika InpUseHtfFilter) Detect new closed HTF bar (via g_htfLastBarTime, gate TERPISAH dari LTF,
   jalan tiap tick SEBELUM early-return LTF): UpdateHtfStructure + HtfCheckIdmTaken (structure-only, no entry)
1. Detect new closed LTF bar (via g_lastBarTime)
2. UpdateStructure: pullback detection + simple structure build
3. CheckEntryInvalidation: untuk semua tracked entries:
   - Body break? (close menembus sweep level) → apply InpInvalidationMode (do nothing / TP fixed points), remove tracking
   - Sweep update? (deeper sweep, jika tidak body break) → update sweep level
   - Auto-cleanup: posisi yang sudah closed → remove tracking
4. CheckIdmTaken: cek idm taken pada closed bar
   - Filter gate sebelum entry: HTF trend filter (jika enabled) → daily limit → TP calc → Min TP points → equilibrium filter (jika enabled) → OpenTrade
5. If entry: place MT5 order, AddEntry to tracking
6. Multi-position — tidak ada batasan jumlah posisi
```

## Position Management

- TP/SL: physical MT5 orders (broker manage). InpRR=0 → no SL.
- Lot size: dari target_amount dan TP distance
  ```
  gainPerLot = (tpDistance / tickSize) * tickValue
  lot = InpTargetAmount / gainPerLot
  ```
- Multi-position — tidak ada batasan jumlah posisi terbuka
- Entry invalidation: body-break sweep → InpInvalidationMode (DO_NOTHING atau TP fixed points; tidak close posisi)
- Daily limit: InpDailyMaxProfit/InpDailyMaxLoss (0=disabled). Query MT5 history deals hari ini (filter symbol + magic). Skip new entries saat limit tercapai. Existing positions tetap di-manage broker (TP/SL/BE).
- After TP/SL/BE hit → continue tracking untuk next signal
