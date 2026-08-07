# AjipIDM — EA Architecture

Files: `AjipIDM.mq5` (main) + 10 `.mqh` includes (see Files table in [README.md](../README.md)).

## Input Parameters

Dikelompokkan dengan `input group` — urutan di bawah sama dengan urutan di dialog EA. Nilai yang ditulis adalah default di source, bukan rekomendasi.

**Strategy / Structure**
```
InpTimeframe          = PERIOD_M1    — Working timeframe
InpHtfTimeframe       = PERIOD_M15   — Higher timeframe — SELALU aktif, sumber equilibrium filter
InpUseAggressiveEntry = true         — Aktifkan jalur per-tick (reversal + zone entry intrabar)
InpCandlesInit        = 50           — Lookback candles untuk initial trend
```

**Entry & Trade Sizing**
```
InpFixedLot     = 0.02   — Fixed lot per entry (tidak ada SL/TP di entry)
InpMaxTotalLots = 0.0    — Max open volume PER ARAH — BUY & SELL di-cap independen (0=disabled)
InpAllowHedging = true   — Boleh BUY & SELL terbuka bersamaan. false = entry baru diblokir
                           selama sisi lawan masih open (prop firm yang melarang hedging)
InpMinTpPoints  = 1000   — Min jarak HTF reference (points) — setup-quality filter
InpDeviation    = 10     — Slippage (points)
InpMagicNumber  = 99001  — Magic number
```

**Risk Management — Final Target** (permanen, lintas hari)
```
InpFinalProfitTarget = 0.0  — Target profit keseluruhan → close ALL + stop entry PERMANEN (0=disabled)
InpFinalMaxLoss      = 0.0  — Max loss keseluruhan → close ALL + stop entry PERMANEN (0=disabled)
InpStartingBalance   = 0.0  — Baseline pengukuran keduanya (0 = auto-capture saat first run, lalu dipersist)
```

**Risk Management — Daily**
```
InpDailyMaxProfit = 60.0   — Daily target → close ALL + blokir entry SISA HARI (0=disabled)
InpDailyMaxLoss   = 280.0  — Daily max loss → close ALL + blokir entry SISA HARI (0=disabled)
```

**Risk Management — Batch**
```
InpBatchMaxProfit       = 20.0  — Batch target → tutup batch INI saja, entry baru tetap boleh (0=disabled)
InpBatchMaxLoss         = 0.0   — Batch max loss → tutup batch INI saja, entry baru tetap boleh (0=disabled)
InpBatchCooldownMinutes = 11    — Jeda setelah batch flat sebelum batch baru boleh mulai (0=disabled)
```

**Partial Close**
```
InpPartialCloseProfit  = 10.0  — Floating profit ($, POSITION_PROFIT) untuk trigger one-time partial close (0=disabled)
InpPartialClosePercent = 50.0  — % volume yang ditutup di threshold partial close
```

**Session Filter**
```
InpSessionStart = "02:00"  — Session start (server time HH:MM) — start==end = filter nonaktif
InpSessionEnd   = "20:00"  — Session end — di luar sesi: no entry; kalau PnL > 0 → close ALL
```

**News Filter**
```
InpNewsFilterEnabled = true                       — Blokir entry di sekitar news high-impact
InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH   — Importance minimum yang memblokir
InpNewsMinutesBefore = 30                         — Menit sebelum event mulai memblokir
InpNewsMinutesAfter  = 30                         — Menit sesudah event masih memblokir
```

**Chart Display**
```
InpDrawLines   = true / InpMaxLines = 500
InpShowPanel   = true / InpPanelCorner = CORNER_LEFT_UPPER / InpPanelX = 20 / InpPanelY = 50
```

**Diagnostics**
```
InpEnableLog = true  — Toggle semua Print/PrintFormat diagnostik ke tab Experts
```

**Multi-Account Orchestrator**
```
InpHandoffEnabled = false                    — Tulis handoff signal saat daily target/max-loss kena
InpHandoffFile    = "AjipIDM_Handoff.csv"    — Ditulis ke Common\Files (FILE_COMMON)
InpHeartbeatFile  = "AjipIDM_Heartbeat.csv"  — "EA hidup di akun ini", ditulis ~30s sekali
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
- Partial close (`InpPartialCloseProfit`) TIDAK menutup posisi sepenuhnya — ticket tetap ada, jadi tidak memicu akumulasi. Posisi baru dihitung sekali batch (win/loss/BE) saat BENAR-BENAR closed (volume habis).
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

**Reversal dan entry sudah DIPISAH.** `CheckIdmTaken`/`CheckAggressiveIdmTouch` sekarang murni mengurus struktur (reversal), sementara entry dijalankan `CheckIdmZoneEntry`/`CheckAggressiveZoneEntry` dari boundary yang lebih longgar (`g_idmZonePrice` = extreme berlawanan dari bar idm). Keduanya tidak saling menunggu — lihat [Entry Decoupling](concept.md#entry-decoupling-zone-entry) di concept.md.

```
0. Tiap tick, TIDAK digate new-bar:
   WriteHeartbeat (self-throttled ~30s, no-op kalau InpHandoffEnabled=false)
   UpdateMfeMae
   CheckPartialClose            (one-time per posisi + breakeven SL)
   CheckFinalTargetCloseAll     (PERMANEN — paling signifikan, dicek duluan)
   CheckFinalMaxLossCloseAll    (PERMANEN)
   CheckBatchCloseAll           (batch INI saja, entry baru tetap boleh)
   CheckDailyCloseAll           (flush + blokir entry sisa hari)
   CheckSessionCloseAll         (di luar sesi + PnL > 0 → flush)
   RecalculateAggregateSL       (setelah semua close-all + MFE/MAE di atas)
0.5 HTF context (SELALU aktif, gate TERPISAH via g_htfLastBarTime, jalan tiap
   tick SEBELUM early-return LTF): new closed HTF bar → UpdateHtfStructure →
   HtfCheckIdmTaken
0.7 Jalur per-tick (InpUseAggressiveEntry):
   CheckAggressiveZoneEntry  ← ENTRY. Dicek DULUAN: g_idmZonePrice lebih dekat
                               ke harga daripada sweep penuh g_idmPrice
   CheckAggressiveIdmTouch   ← REVERSAL saja, tidak entry. Butuh g_idmConfirmed
   Kalau g_trend berubah di sini → UpdatePanel (label trend jangan telat sebar)
1. Detect new closed LTF bar (via g_lastBarTime) — di bawah ini per-bar
2. UpdateStructure: pullback detection + simple structure build + UpdateIdm
3. CheckEntryCleanup: posisi yang closed DI LUAR close-all (mis. breakeven
   stop) → fold ke batch accumulator → remove dari tracking
4. CheckIdmZoneEntry(bar)  ← ENTRY (bar-close), dicek duluan
   CheckIdmTaken(bar)      ← REVERSAL saja
5. UpdatePanel
```

**Gate entry** (urutan sama di kedua jalur entry): `FinalTargetReached` → `FinalMaxLossReached` → `DailyLimitReached` → `MaxTotalLotsReached(dir)` → `HedgeBlocked(dir)` → `BatchCooldownActive` → `InSession` → `InNewsBlackout` → `HtfEntryAllowed`. Jalur per-tick sengaja tidak nge-log tiap gate (spam); jalur bar-close nge-log alasan skip-nya.

## Position Management

- Tidak ada TP/SL di entry — order selalu dibuka dengan SL=0, TP=0 (log:
  `SL=NONE, TP=NONE`). TP tetap 0 selamanya; SL bisa muncul belakangan dari DUA
  sumber: breakeven setelah partial close, atau aggregate SL (lihat di bawah).
- Lot size: fixed, `InpFixedLot` untuk setiap entry (tidak dihitung dari target profit).
- Multi-position — jumlah posisi TIDAK dibatasi. Yang dibatasi VOLUME, lewat
  `InpMaxTotalLots`, dan itu **per arah, independen**: sisi BUY penuh dan sisi
  SELL penuh boleh hidup bersamaan, masing-masing sampai cap-nya sendiri
  (`MaxTotalLotsReached(dir)`).
- Hedging (`InpAllowHedging`): default `true` = BUY dan SELL boleh terbuka
  bersamaan. Set `false` → `HedgeBlocked(dir)` menolak entry baru selama masih
  ada volume tracked di sisi lawan, jadi kedua arah tidak pernah bersamaan.
  Ini **memblokir entry**, bukan menutup paksa sisi lawan — menutup paksa akan
  merealisasikan kerugian yang tidak diminta strategi. Sisi lama tetap keluar
  lewat jalur normalnya, arah baru menunggu. Diperlukan untuk prop firm yang
  memasukkan hedging sebagai forbidden strategy.
- Partial close + breakeven SL: one-time per posisi, tiap tick via
  `CheckPartialClose` — begitu `POSITION_PROFIT` posisi >= `InpPartialCloseProfit` ($),
  tutup `InpPartialClosePercent` dari volumenya (`PositionClosePartial`), lalu
  `PositionModify` SL sisa posisi ke `entryPrice` (breakeven, TP tetap 0).
  Di-skip (termasuk BE SL-nya) kalau closeVolume atau remainder di bawah
  `SYMBOL_VOLUME_MIN` broker.
- Daily close-all: `InpDailyMaxProfit`/`InpDailyMaxLoss` (0=disabled). Tiap tick,
  `CheckDailyCloseAll` jumlah `GetDailyPnL()` (realized SEMUA batch hari ini) +
  `GetFloatingPnL()` — begitu nyentuh target/loss, `CloseAllAndFlushBatch`
  menutup SEMUA posisi (symbol+magic ini) + flush batch. Setelah itu
  `DailyLimitReached()` (realized-only) otomatis skip entry baru untuk SISA
  HARI itu — circuit breaker harian (final target di bawah lebih tinggi lagi).
- Final target/max loss: `InpFinalProfitTarget`/`InpFinalMaxLoss` (0=disabled) —
  circuit breaker TERTINGGI, **permanen dan lintas hari**, bukan reset harian.
  Diukur dari `InpStartingBalance` (0 = auto-capture balance saat first run,
  lalu dipersist supaya tidak ikut bergeser tiap restart). Begitu kena,
  `CloseAllAndFlushBatch` + entry baru berhenti SELAMANYA sampai input di-reset
  manual. Dicek paling awal tiap tick, sebelum batch/daily.
- Batch close-all: `InpBatchMaxProfit`/`InpBatchMaxLoss` (0=disabled), TERPISAH
  dari daily. Tiap tick, `CheckBatchCloseAll` jumlah `g_batchRealizedPnl`
  (realized batch INI SAJA, bukan seluruh hari) + `GetFloatingPnL()` — begitu
  nyentuh target/loss batch, `CloseAllAndFlushBatch` menutup+flush batch itu
  SAJA. TIDAK ngeblok entry baru — batch baru boleh langsung mulai lagi
  selama daily limit belum ikut kena. Lihat [Daily vs Batch Limit](architecture.md#daily-vs-batch-limit).
- Batch cooldown: `InpBatchCooldownMinutes` (0=disabled) — setelah sebuah batch
  benar-benar flat (`g_lastBatchEndTime`), entry baru ditahan selama N menit
  (`BatchCooldownActive()`). Mencegah batch baru langsung nyambung ke batch yang
  baru saja ditutup.
- Trading session: `InpSessionStart`/`InpSessionEnd` (server time `HH:MM`,
  di-parse sekali di `OnInit` — start==end atau unparseable = filter
  nonaktif). `InSession()` dicek sebagai entry gate (sejajar
  `DailyLimitReached()`) di `CheckIdmZoneEntry`/`CheckAggressiveZoneEntry` — di
  luar sesi, entry baru di-skip. `CheckSessionCloseAll` (tiap tick): di luar
  sesi DAN total (realized+floating) > 0 → `CloseAllAndFlushBatch`, walaupun
  belum nyentuh `InpDailyMaxProfit` — supaya profit tidak "dibalikin" di
  luar jam trading. Kalau PnL negatif saat di luar sesi, posisi TIDAK
  dipaksa tutup.
- Tidak ada mekanisme invalidation per-struktur lagi (mekanisme HTF body-break
  invalidation versi TP/SL sebelumnya sudah dihapus di varian ini) — exit
  murni dari partial close + batch/daily/session close-all.

## Aggregate SL

`RecalculateAggregateSL()` (`AjipIDM_Entry.mqh`), tiap tick, SETELAH semua
close-all dan MFE/MAE. Membagikan satu budget risiko ke setiap posisi tracked
yang belum punya stop sendiri. Posisi dengan `partialClosed==true` sudah di
breakeven → dilewati (breakeven selalu minimal seaman SL dari budget).

```
budget = MIN dari InpBatchMaxLoss / InpDailyMaxLoss / InpFinalMaxLoss
         yang aktif (>0). Tidak ada yang aktif → tidak ada SL sama sekali.
valuePerPointPerLot = (SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE) * point

ApplyAggregateSLForDirection(+1, budget, ...)   ← pool BUY
ApplyAggregateSLForDirection(-1, budget, ...)   ← pool SELL
```

**Tiap arah dapat budget PENUH, bukan setengah-setengah.** Ini disengaja: satu
pergerakan harga hanya bisa melukai satu sisi pada satu waktu — kalau harga
turun, hanya pool BUY yang rugi (SELL justru floating profit). Karena worst-case
kedua sisi mutually exclusive, memberi masing-masing budget penuh adalah sizing
yang benar untuk "kerugian terburuk dari satu pergerakan arah". Menggabungkan
keduanya (versi lama) menghitung ganda posisi hedge dan membuat stop terlalu
ketat setiap kali BUY dan SELL terbuka bersamaan.

**Batasannya** — ini jaring pengaman broker-side, BUKAN pengganti circuit
breaker. Tidak membatasi kerugian total lintas whipsaw (SELL kena stop saat naik,
lalu BUY baru kena stop saat turun) karena itu skenario berurutan, bukan
bersamaan; yang menangani itu tetap `CheckBatchCloseAll`/`CheckDailyCloseAll`/
`CheckFinalMaxLossCloseAll` yang jalan LEBIH DULU tiap tick. `budget` juga
perbandingan config statis, belum dinetokan terhadap PnL yang sudah realized.
Gunanya: menutup celah saat ketiga check itu tidak sempat bereaksi — disconnect,
gap, atau slippage pada close-all itu sendiri.

## News Blackout

`InNewsBlackout()` (`AjipIDM_News.mqh`) — bukan cuma gate entry, digerbangkan juga
di setiap aksi close yang sifatnya profit-taking: `CheckPartialClose`,
`CheckFinalTargetCloseAll`, `CheckSessionCloseAll`, dan cabang `TARGET_HIT` di
`CheckDailyCloseAll`/`CheckBatchCloseAll` (dua fungsi ini menangani profit DAN
loss dalam satu body via `ClassifyLimitStatus` — gate-nya cuma di cabang profit,
bukan di seluruh fungsi). Kill switch max-loss (`CheckFinalMaxLossCloseAll`,
cabang `MAXLOSS_HIT` di Daily/Batch) **sengaja TIDAK PERNAH digerbangkan** —
lihat rasional lengkapnya di [News Blackout](concept.md#news-blackout-gate-entry--profit-side-exit)
di concept.md.

Memakai Calendar API bawaan MT5, mencocokkan event dengan base + profit
currency simbol (XAUUSD → cek XAU dan USD). Window: `now - InpNewsMinutesAfter`
sampai `now + InpNewsMinutesBefore`.

Hasilnya di-cache 15 detik supaya tidak dihitung ulang tiap tick — window
blackout lebarnya menit, lag cache beberapa detik tidak material. Kalau kalender
tidak tersedia (mis. Strategy Tester tanpa data ter-cache), query mengembalikan
nol event dan filter ini **non-blocking** — fallback yang sama dengan session
filter saat input tidak bisa di-parse.

## Restart Recovery

`RebuildTrackedPositions()` (`AjipIDM_Entry.mqh`), dipanggil di `OnInit`. Saat EA
di-reattach/recompile/restart, `g_entries[]` kosong sementara posisi di broker
masih ada. Tanpa ini, posisi lama jadi "yatim": tidak ikut MFE/MAE, tidak kena
partial close, tidak dilindungi aggregate SL, dan tidak masuk batch report.

Recovery memindai posisi terbuka dengan symbol+magic yang cocok, memasukkannya
kembali ke tracking, lalu merekonstruksi `g_batchActive`/`g_batchFirstEntryTime`/
`g_batchLastEntryTime` dari waktu buka posisi-posisi itu. MFE/MAE dimulai ulang
dari nilai sekarang (excursion sebelum restart hilang — tidak terekam di mana
pun).

## Multi-Account Orchestrator (opsional)

Aktif hanya kalau `InpHandoffEnabled=true`. EA menulis dua file ke folder
**Common\Files** (`FILE_COMMON`, dipakai bersama semua terminal):

- `InpHandoffFile` — ditulis saat daily target / daily max loss kena. Sinyal ke
  orchestrator eksternal bahwa akun ini sudah selesai untuk hari itu.
- `InpHeartbeatFile` — "EA hidup di akun ini", ditulis ~30 detik sekali
  (`WriteHeartbeat`, self-throttled, aman dipanggil tiap tick). Dipakai
  orchestrator untuk mendeteksi akun yang tidak ada EA-nya.

Sisi Python-nya ada di `orchestrator/` — lihat [orchestrator/README.md](../orchestrator/README.md).
