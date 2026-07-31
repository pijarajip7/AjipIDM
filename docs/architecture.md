# AjipIDM — EA Architecture

Files: `AjipIDM.mq5` (main) + 9 `.mqh` includes (see Files table in [README.md](../README.md)).

## Input Parameters

```
InpTimeframe    = PERIOD_M15     — Working timeframe
InpFixedLot     = 0.10           — Fixed lot size per entry (tidak ada SL/TP di varian ini)
InpCandlesInit  = 50             — Lookback candles untuk initial trend
InpDeviation    = 10             — Slippage (points)
InpMagicNumber  = 99001          — Magic number
InpDrawLines    = true           — Draw structure lines on chart
InpMaxLines     = 500            — Max trendline objects
InpMinTpPoints  = 0              — Min HTF reference distance in points (setup-quality filter, 0=no filter)
InpDailyMaxProfit = 0.0          — Daily target — close ALL positions + stop entry baru SISA HARI ITU (0=disabled)
InpDailyMaxLoss   = 0.0          — Daily max loss — close ALL positions + stop entry baru SISA HARI ITU (0=disabled)
InpBatchMaxProfit = 0.0          — Batch target — close batch SAAT INI saja, entry baru tetap boleh langsung setelahnya (0=disabled)
InpBatchMaxLoss   = 0.0          — Batch max loss — close batch SAAT INI saja, entry baru tetap boleh langsung setelahnya (0=disabled)
InpSessionStart = "00:00"        — Session start (server time HH:MM) — entry baru hanya di dalam sesi
InpSessionEnd   = "00:00"        — Session end (server time HH:MM) — start==end = tidak ada restriction (default)
InpPartialClosePoints  = 1000    — Points profit untuk trigger one-time partial close (0=disabled)
InpPartialClosePercent = 50.0    — % volume posisi yang ditutup di threshold partial close
InpHtfTimeframe = PERIOD_H1      — Higher timeframe — SELALU aktif, sumber equilibrium filter (lihat concept.md)
InpUseAggressiveEntry = false    — Enter di idm level intrabar (sebelum bar close), reverse LTF lebih awal
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
HTF Trend: UP / DOWN / NONE     (HTF context selalu aktif — bukan lagi toggle)
Today P/L: <realized, deals hari ini>
Week P/L:  <realized, sejak Senin 00:00>
Month P/L: <realized, sejak tanggal 1 00:00>
Daily:     active / disabled / TARGET HIT / MAX LOSS HIT
Batch:     active / disabled / TARGET HIT / MAX LOSS HIT
Session:   OPEN / CLOSED / all day
Open MFE:  <sum floating best-case, semua posisi open>
Open MAE:  <sum floating worst-case, semua posisi open>
```

P/L (Today/Week/Month) dihitung dari realized deals (symbol + magic number sama) — BUKAN floating/unrealized PnL posisi terbuka. Baris `Daily` dan `Batch` beda: keduanya lewat `ClassifyLimitStatus(total, maxProfit, maxLoss)` — generik, dipakai dua kali dengan total & threshold BEDA:
- `Daily` = `ClassifyLimitStatus(todayPnl + GetFloatingPnL(), InpDailyMaxProfit, InpDailyMaxLoss)` — TOTAL YANG SAMA dipakai `CheckDailyCloseAll`. Begitu `TARGET HIT`/`MAX LOSS HIT`, entry baru diblokir SISA HARI itu (`DailyLimitReached()`).
- `Batch` = `ClassifyLimitStatus(g_batchRealizedPnl + GetFloatingPnL(), InpBatchMaxProfit, InpBatchMaxLoss)` — TOTAL YANG SAMA dipakai `CheckBatchCloseAll`. Begitu `TARGET HIT`/`MAX LOSS HIT`, cuma batch SAAT INI yang ditutup — entry baru tetap boleh langsung setelahnya (tidak ngeblok apa pun).
Keduanya bisa `disabled` independen (kalau pasangan maxProfit/maxLoss masing-masing 0). Baris `Session` dari `InSession()` — `all day` kalau `InpSessionStart`==`InpSessionEnd` (filter nonaktif), sebaliknya `OPEN`/`CLOSED` sesuai jam server saat ini vs `InpSessionStart`/`InpSessionEnd`. Object chart pakai prefix `g_panelPrefix` ("AjipIDMPanel_"), terpisah dari `g_objPrefix` ("AjipIDM_") supaya tidak ke-wipe oleh `ObjectsDeleteAll` di `DrawSwings()`.

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

MFE/MAE per posisi TIDAK ditulis ke CSV satu-satu lagi — sekarang diakumulasi ke batch report, lihat [Batch CSV Report](#batch-csv-report-per-setup) di bawah.

## Batch CSV Report (Per-Setup)

Report per-posisi individual sudah DIGANTI TOTAL oleh report per-"setup" (batch): satu baris CSV merangkum SEMUA posisi yang closed sejak flush terakhir, ditulis SEKALI saat batch itu selesai — bukan satu baris per posisi. Batas satu batch = satu event `CloseAllAndFlushBatch` yang BERHASIL (bukan hari kalender) — lihat [Daily vs Batch Limit](#daily-vs-batch-limit) di bawah buat kenapa >1 batch bisa terjadi di hari yang sama.

**Akumulasi** (`AccumulateBatchStats`, `AjipIDM_Trade.mqh`) — dipanggil untuk SETIAP posisi yang terdeteksi full closed, dari dua tempat: `CheckEntryCleanup` (straggler, mis. breakeven stop mid-batch) dan `CloseAllAndFlushBatch` (posisi yang baru saja ditutup close-all):
```
realizedPnl = sum(DEAL_PROFIT+DEAL_SWAP+DEAL_COMMISSION) dari semua deal
              DEAL_ENTRY_OUT/OUT_BY posisi itu (termasuk partial close)

g_batchCount++      g_batchRealizedPnl += realizedPnl
g_batchMfeSum += e.mfe     g_batchMaeSum += e.mae
realizedPnl > 0 → g_batchWins++ | < 0 → g_batchLosses++ | == 0 → g_batchBreakEven++
```
Tidak ada apa pun yang ditulis ke disk di titik ini — cuma akumulasi in-memory.

**First/Last entry time**: `AddEntry` (`AjipIDM_Entry.mqh`) set `g_batchFirstEntryTime` sekali (entry PERTAMA sejak batch terakhir di-flush, ditandai `g_batchActive`), dan selalu update `g_batchLastEntryTime` ke entry TERBARU.

**Flush** — `CloseAllAndFlushBatch(reason)` (`AjipIDM_Trade.mqh`), dipanggil dari `CheckBatchCloseAll`/`CheckDailyCloseAll`/`CheckSessionCloseAll`, melakukan close+accumulate+write+reset SECARA ATOMIK dalam satu pemanggilan (bukan nunggu `CheckEntryCleanup` di bar berikutnya):
```
1. Tutup semua posisi (symbol+magic ini) via trade.PositionClose
2. Untuk tiap tracked entry: kalau BENAR sudah closed di broker → AccumulateBatchStats
   + RemoveEntry. Kalau gagal close (masih open) → biarkan tetap tracked (straggler).
3. Kalau masih ada straggler (g_entries belum kosong) → STOP, jangan flush dulu
   (nunggu trigger berikutnya buat retry).
4. Kalau g_entries kosong: g_batchCount > 0 → tulis 1 baris CSV; lalu ResetBatchAccumulator().
```
Desain atomik ini PENTING khusus buat `CheckBatchCloseAll` — beda dari daily/session, batch limit TIDAK ngeblok entry baru, jadi kalau flush-nya ditunda ke bar berikutnya (desain lama), entry baru bisa nyelip masuk ke tracking SEBELUM batch lama sempat di-flush, merusak batas antar-batch. Dengan desain atomik ini, begitu `CloseAllAndFlushBatch` selesai, `g_entries[]` dan accumulator sudah pasti bersih (atau masih menunggu straggler, tidak pernah campur dengan entry baru).

Append 1 baris ke `MQL5/Files/AjipIDM_Batches_<symbol>_<magic>.csv` (dibuat otomatis kalau belum ada, header ditulis sekali). Kolom: `CloseTime,CloseReason,PositionCount,Wins,Losses,BreakEven,TotalRealizedPnL,SumMFE,SumMAE,FirstEntryTime,LastEntryTime`. `CloseReason` salah satu dari `DAILY_TARGET`/`DAILY_MAX_LOSS`/`BATCH_TARGET`/`BATCH_MAX_LOSS`/`SESSION_END`.

Catatan:
- **PENTING**: kalau `InpDailyMaxProfit`/`InpDailyMaxLoss`/`InpBatchMaxProfit`/`InpBatchMaxLoss` SEMUA 0 DAN session filter nonaktif (`InpSessionStart`==`InpSessionEnd`), tidak ada apa pun yang pernah memicu `CloseAllAndFlushBatch` → CSV batch TIDAK PERNAH ditulis, walaupun posisi terus buka/tutup (breakeven stop, dll). Aktifkan minimal salah satu supaya history ke-log.
- Partial close (`InpPartialClosePoints`) TIDAK menutup posisi sepenuhnya — ticket tetap ada, jadi tidak memicu akumulasi. Posisi baru dihitung sekali batch (win/loss/BE) saat BENAR-BENAR closed (volume habis).
- Di Strategy Tester, file CSV ada di folder sandbox agent tester (`Tester/Agent-xxx/MQL5/Files/`), bukan folder terminal utama — kalau run optimization paralel, tiap agent punya file sendiri (tidak digabung otomatis).
- Detail per-ticket (entry price, exit price/time individual) sudah tidak ada lagi di CSV — kalau butuh itu, cek log `Print`/`PrintFormat` EA (tab Experts) atau `HistoryDealsTotal` manual di Strategy Tester.

## Daily vs Batch Limit

Dua limit independen, pakai `ClassifyLimitStatus` yang sama tapi total & efek beda:

| | Daily (`InpDailyMaxProfit`/`Loss`) | Batch (`InpBatchMaxProfit`/`Loss`) |
|---|---|---|
| Total dicek | `GetDailyPnL()` (realized SEMUA batch hari ini) + `GetFloatingPnL()` | `g_batchRealizedPnl` (realized batch INI SAJA) + `GetFloatingPnL()` |
| Efek saat hit | `CloseAllAndFlushBatch("DAILY_TARGET"/"DAILY_MAX_LOSS")` **+** `DailyLimitReached()` ngeblok entry baru SISA HARI itu | `CloseAllAndFlushBatch("BATCH_TARGET"/"BATCH_MAX_LOSS")` **saja** — entry baru tetap boleh langsung, batch baru mulai lagi |
| Cek di OnTick | `CheckDailyCloseAll` | `CheckBatchCloseAll` (jalan LEBIH DULU tiap tick, lebih granular) |

Karena batch limit TIDAK ngeblok entry, dalam SATU hari kalender bisa ada LEBIH DARI SATU baris CSV — tiap kali `InpBatchMaxProfit`/`InpBatchMaxLoss` kena, batch itu di-flush dan batch baru langsung bisa mulai, selama `DailyLimitReached()` belum ikut ke-trigger (realized harian kumulatif belum nyentuh `InpDailyMaxProfit`/`InpDailyMaxLoss`). Begitu daily limit itu SENDIRI kena, entry baru berhenti sisa hari itu — jadi daily limit tetap jadi "circuit breaker" tertinggi, batch limit cuma membagi hari itu jadi beberapa ronde.

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
0. UpdateMfeMae (tiap tick) → CheckPartialClose (tiap tick, one-time per
   posisi, + breakeven SL) → CheckBatchCloseAll (tiap tick, g_batchRealizedPnl
   +floating vs InpBatchMaxProfit/Loss — flush batch INI saja, entry baru
   tetap boleh) → CheckDailyCloseAll (tiap tick, GetDailyPnL+floating vs
   InpDailyMaxProfit/Loss — flush + blokir entry sisa hari) →
   CheckSessionCloseAll (tiap tick, di luar sesi + PnL > 0 → flush)
0.5 HTF context (SELALU aktif, gate TERPISAH dari LTF via g_htfLastBarTime,
   jalan tiap tick SEBELUM early-return LTF): detect new closed HTF bar →
   UpdateHtfStructure → HtfCheckIdmTaken (idm taken? reverse structure HTF)
0.7 (jika InpUseAggressiveEntry) CheckAggressiveIdmTouch — per-tick, sebelum
   early-return LTF: idm LTF tersentuh intrabar → reverse LTF early (pakai
   last closed bar sbg boundary) → HtfEntryAllowed → OpenTrade langsung
1. Detect new closed LTF bar (via g_lastBarTime)
2. UpdateStructure: pullback detection + simple structure build
3. CheckEntryCleanup: untuk semua tracked entries — posisi yang BENAR-BENAR
   closed di LUAR close-all (partial close tidak menghapus ticket; mis.
   breakeven stop) → fold ke batch accumulator → remove dari tracking. Tidak
   pernah nulis CSV sendiri — flush selalu lewat CloseAllAndFlushBatch (step 0).
4. CheckIdmTaken: cek idm taken LTF pada closed bar (entry decision, tidak berubah)
   - Kalau lolos (no body break) → daily limit → session filter (InSession) →
     HtfEntryAllowed (prev-swing body-break filter + reference swing HTF +
     equilibrium HTF + min points) → OpenTrade (fixed lot, tanpa SL/TP)
5. If entry: place MT5 order, AddEntry to tracking
6. Multi-position — tidak ada batasan jumlah posisi
```

## Position Management

- Tidak ada TP/SL di entry — order selalu dibuka dengan SL=0, TP=0. TP tetap 0
  selamanya (tidak pernah ada TP order); SL bisa berubah setelah partial close
  (lihat di bawah).
- Lot size: fixed, `InpFixedLot` untuk setiap entry (tidak dihitung dari target profit).
- Multi-position — tidak ada batasan jumlah posisi terbuka.
- Partial close + breakeven SL: one-time per posisi, tiap tick via
  `CheckPartialClose` — begitu floating profit posisi >= `InpPartialClosePoints`,
  tutup `InpPartialClosePercent` dari volumenya (`PositionClosePartial`), lalu
  `PositionModify` SL sisa posisi ke `entryPrice` (breakeven, TP tetap 0).
  Di-skip (termasuk BE SL-nya) kalau closeVolume atau remainder di bawah
  `SYMBOL_VOLUME_MIN` broker.
- Daily close-all: `InpDailyMaxProfit`/`InpDailyMaxLoss` (0=disabled). Tiap tick,
  `CheckDailyCloseAll` jumlah `GetDailyPnL()` (realized SEMUA batch hari ini) +
  `GetFloatingPnL()` — begitu nyentuh target/loss, `CloseAllAndFlushBatch`
  menutup SEMUA posisi (symbol+magic ini) + flush batch. Setelah itu
  `DailyLimitReached()` (realized-only) otomatis skip entry baru untuk SISA
  HARI itu — circuit breaker tertinggi.
- Batch close-all: `InpBatchMaxProfit`/`InpBatchMaxLoss` (0=disabled), TERPISAH
  dari daily. Tiap tick, `CheckBatchCloseAll` jumlah `g_batchRealizedPnl`
  (realized batch INI SAJA, bukan seluruh hari) + `GetFloatingPnL()` — begitu
  nyentuh target/loss batch, `CloseAllAndFlushBatch` menutup+flush batch itu
  SAJA. TIDAK ngeblok entry baru — batch baru boleh langsung mulai lagi
  selama daily limit belum ikut kena. Lihat [Daily vs Batch Limit](architecture.md#daily-vs-batch-limit).
- Trading session: `InpSessionStart`/`InpSessionEnd` (server time `HH:MM`,
  di-parse sekali di `OnInit` — start==end atau unparseable = filter
  nonaktif). `InSession()` dicek sebagai entry gate (sejajar
  `DailyLimitReached()`) di `CheckIdmTaken`/`CheckAggressiveIdmTouch` — di
  luar sesi, entry baru di-skip. `CheckSessionCloseAll` (tiap tick): di luar
  sesi DAN total (realized+floating) > 0 → `CloseAllAndFlushBatch`, walaupun
  belum nyentuh `InpDailyMaxProfit` — supaya profit tidak "dibalikin" di
  luar jam trading. Kalau PnL negatif saat di luar sesi, posisi TIDAK
  dipaksa tutup.
- Tidak ada mekanisme invalidation per-struktur lagi (mekanisme HTF body-break
  invalidation versi TP/SL sebelumnya sudah dihapus di varian ini) — exit
  murni dari partial close + batch/daily/session close-all.
