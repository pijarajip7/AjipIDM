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
InpDailyMaxProfit = 0.0          — Daily target — close ALL positions + stop entry baru saat tercapai (0=disabled)
InpDailyMaxLoss   = 0.0          — Daily max loss — close ALL positions + stop entry baru saat tercapai (0=disabled)
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
Session:   OPEN / CLOSED / all day
Open MFE:  <sum floating best-case, semua posisi open>
Open MAE:  <sum floating worst-case, semua posisi open>
```

P/L (Today/Week/Month) dihitung dari realized deals (symbol + magic number sama) — BUKAN floating/unrealized PnL posisi terbuka. Baris `Daily` beda: itu status dari `ClassifyDailyStatus(todayPnl + GetFloatingPnL())` — realized + floating, TOTAL YANG SAMA dipakai `CheckDailyCloseAll` buat memutuskan close-all, jadi bisa lebih tinggi/rendah dari `Today P/L` kalau ada floating besar. `disabled` kalau `InpDailyMaxProfit`/`InpDailyMaxLoss` keduanya 0. Baris `Session` dari `InSession()` — `all day` kalau `InpSessionStart`==`InpSessionEnd` (filter nonaktif), sebaliknya `OPEN`/`CLOSED` sesuai jam server saat ini vs `InpSessionStart`/`InpSessionEnd`. Object chart pakai prefix `g_panelPrefix` ("AjipIDMPanel_"), terpisah dari `g_objPrefix` ("AjipIDM_") supaya tidak ke-wipe oleh `ObjectsDeleteAll` di `DrawSwings()`.

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

Saat posisi terdeteksi FULL closed (daily close-all atau manual — dicek di `CheckEntryCleanup`), `WriteTradeCsv()` dipanggil SEBELUM entry dihapus dari tracking:
- Query exit info dari `HistorySelectByPosition(ticket)`: exit price/time, close reason (TP/SL/STOPOUT/OTHER dari `DEAL_REASON` — TP/SL praktis tidak pernah muncul lagi karena tidak ada order TP/SL), realized P/L (sum semua deal exit termasuk partial close sebelumnya).
- Append 1 baris ke `MQL5/Files/AjipIDM_Trades_<symbol>_<magic>.csv` (dibuat otomatis kalau belum ada, header ditulis sekali).
- Kolom: `Ticket,Dir,EntryTime,EntryPrice,ExitTime,ExitPrice,CloseReason,RealizedPnL,MFE,MAE`.

Catatan:
- Partial close (`InpPartialClosePoints`) TIDAK menutup posisi sepenuhnya — ticket tetap ada, jadi tidak memicu CSV write. Row CSV hanya ditulis saat posisi BENAR-BENAR closed (volume habis).
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
0. UpdateMfeMae (tiap tick) → CheckPartialClose (tiap tick, one-time per
   posisi, + breakeven SL) → CheckDailyCloseAll (tiap tick, realized+floating
   vs InpDailyMaxProfit/Loss — CloseAllPositions kalau tercapai) →
   CheckSessionCloseAll (tiap tick, di luar sesi + PnL > 0 → CloseAllPositions)
0.5 HTF context (SELALU aktif, gate TERPISAH dari LTF via g_htfLastBarTime,
   jalan tiap tick SEBELUM early-return LTF): detect new closed HTF bar →
   UpdateHtfStructure → HtfCheckIdmTaken (idm taken? reverse structure HTF)
0.7 (jika InpUseAggressiveEntry) CheckAggressiveIdmTouch — per-tick, sebelum
   early-return LTF: idm LTF tersentuh intrabar → reverse LTF early (pakai
   last closed bar sbg boundary) → HtfEntryAllowed → OpenTrade langsung
1. Detect new closed LTF bar (via g_lastBarTime)
2. UpdateStructure: pullback detection + simple structure build
3. CheckEntryCleanup: untuk semua tracked entries — posisi yang BENAR-BENAR
   closed (partial close tidak menghapus ticket) → log CSV → remove dari
   tracking.
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
  `CheckDailyCloseAll` jumlah `GetDailyPnL()` (realized) + `GetFloatingPnL()`
  (floating semua posisi open) — begitu nyentuh target/loss, `CloseAllPositions()`
  menutup SEMUA posisi (symbol+magic ini). Setelah itu `DailyLimitReached()`
  (realized-only) otomatis skip entry baru untuk sisa hari itu.
- Trading session: `InpSessionStart`/`InpSessionEnd` (server time `HH:MM`,
  di-parse sekali di `OnInit` — start==end atau unparseable = filter
  nonaktif). `InSession()` dicek sebagai entry gate (sejajar
  `DailyLimitReached()`) di `CheckIdmTaken`/`CheckAggressiveIdmTouch` — di
  luar sesi, entry baru di-skip. `CheckSessionCloseAll` (tiap tick): di luar
  sesi DAN total (realized+floating) > 0 → `CloseAllPositions()`, walaupun
  belum nyentuh `InpDailyMaxProfit` — supaya profit tidak "dibalikin" di
  luar jam trading. Kalau PnL negatif saat di luar sesi, posisi TIDAK
  dipaksa tutup.
- Tidak ada mekanisme invalidation per-struktur lagi (mekanisme HTF body-break
  invalidation versi TP/SL sebelumnya sudah dihapus di varian ini) — exit
  murni dari partial close + daily close-all.
