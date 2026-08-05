# AjipIDM — Konsep & Strategi

AjipIDM berbeda dari AjipSMC dalam hal:

| Aspek | AjipSMC | AjipIDM |
|-------|---------|---------|
| Structure levels | SL/SH + VH/VL (Weak) | SL/SH saja |
| idm role | Trigger untuk Weak confirmation | Trigger reversal trend |
| idm taken effect | Confirm Weak, cycle berhenti | Trend SELALU berubah |
| Entry | OF/OB/FVG analysis | idm taken + no body break → fade |
| Entry direction | Trend-following (menuju Weak) | Counter-trend (sweep/fakeout) |
| Target | Weak VL/VH | Swing terakhir di struktur baru (equilibrium reference saja, bukan TP order) |
| RR | 1:2 minimum | Tidak ada — fixed lot (`InpFixedLot`), tanpa TP/SL |
| SL | Hybrid structural + ATR | Tidak ada — exit via partial close (`InpPartialClosePoints`) + daily close-all |
| Platform | Python + TradingView | MT5 EA (MQL5) |

## Naming Convention

```
Uptrend:   SLU0 → SHU1 → SLU1 → SHU2 → SLU2 → ...
           SLU = Simple Low Up,  SHU = Simple High Up
           SLU must be HL, SHU must be HH

Downtrend: SHD0 → SLD1 → SHD1 → SLD2 → SHD2 → ...
           SHD = Simple High Down,  SLD = Simple Low Down
           SHD must be LH, SLD must be LL
```

## idm Definition

idm = swing TERAKHIR dari tipe inducement yang sudah CONFIRMED (memiliki swing lawan setelahnya):
- Uptrend: idm = SL terakhir yang punya SH setelahnya (confirmed pullback — price sudah buat HH sejak SL itu)
- Downtrend: idm = SH terakhir yang punya SL setelahnya (confirmed pullback — price sudah buat LL sejak SH itu)

Implementasi (`UpdateIdm`): walk backward dari index n-2 (EXCLUDE swing terakhir / dangling).
Swing terakhir = kandidat unconfirmed. Contoh uptrend [SL100, SH110, SL105, SH120, SL108]:
SL108 belum punya SH setelahnya → BUKAN idm. idm = SL105 (punya SH120 setelahnya).
Saat price buat HH di atas SH120, SL108 otomatis jadi confirmed → jadi idm baru.

UpdateIdm dipanggil di: InitStructure, UpdateStructure (live), RebuildStructure (replay).
Sebelumnya hanya di Init/Rebuild → g_idmPrice stale setelah init/reversal.

idm TIDAK bergeser meski wick lebih dalam. Yang penting hanya close vs idm level.

## idm Taken → Trend Change (ALWAYS)

Saat idm taken (candle low/high menembus idm level):
1. Trend SELALU berubah — regardless of body break
2. Build struktur baru dari titik ekstrem sebelumnya
3. **Tidak ada keputusan entry di sini.** Entry jalan terpisah — lihat [Entry Decoupling](#entry-decoupling-zone-entry).

## Entry Rules

Keputusan ENTRY (kapan & arah) murni dari struktur LTF (`InpTimeframe`), digate equilibrium HTF (`InpHtfTimeframe`) — lihat [HTF-Referenced Equilibrium Gate](#htf-referenced-equilibrium-gate). **Tidak ada TP/SL di entry** — lot selalu fixed (`InpFixedLot`); SL baru muncul belakangan dari breakeven partial-close atau aggregate SL.

Pemicunya **`g_idmZonePrice`** (extreme berlawanan dari bar idm), bukan sweep penuh `g_idmPrice`. Filter "no body break" tetap ada, tapi diukur terhadap `g_idmPrice`:

**BUY** (uptrend, harga retrace ke zone idm):
```
Condition: bar.low < g_idmZonePrice   ← zone tersentuh
       AND bar.close > g_idmPrice     ← belum body break di bawah idm penuh
→ BUY @ close price, lot = InpFixedLot, tanpa SL/TP
```

**SELL** (downtrend, harga retrace ke zone idm):
```
Condition: bar.high > g_idmZonePrice
       AND bar.close < g_idmPrice
→ SELL @ close price, lot = InpFixedLot, tanpa SL/TP
```

**Body break = no entry:** close menembus `g_idmPrice` (uptrend: close < idm, downtrend: close > idm) → bukan sweep, tidak entry. Reversal strukturnya sendiri diurus jalur terpisah.

Versi per-tick (`CheckAggressiveZoneEntry`) memakai boundary zone yang sama tapi dievaluasi dari Bid intrabar, tanpa syarat close — konsekuensi wajar karena bar belum selesai.

## HTF-Referenced Equilibrium Gate

HTF context (`AjipIDM_HtfContext.mqh`, globals `g_htf*`) **selalu aktif** (tidak ada toggle) — sumber satu-satunya filter equilibrium (discount/premium) untuk SETIAP entry:

- Struktur/idm HTF-nya sendiri (algoritma SL/SH + idm YANG SAMA seperti LTF), di-update tiap HTF bar closed (gate independen dari LTF new-bar gate — HTF bar closed lebih jarang dari LTF, jadi HTF check jalan tiap tick, TIDAK boleh diletakkan setelah LTF early-return).
- Reuse `InpCandlesInit` untuk lookback init (tidak ada input terpisah).
- Logic (pullback, simple structure, idm, reversal) adalah port 1:1 dari engine LTF.

**HTF trend alignment** — WAJIB, dicek pertama sebelum apa pun:
```
BUY  hanya jalan kalau g_htfTrend == TREND_UP
SELL hanya jalan kalau g_htfTrend == TREND_DOWN
```
Tanpa ini, `GetLastHtfSHDPrice`/`SLUPrice` bisa ambil swing dari struktur yang
"salah bentuk" — misal BUY saat `g_htfTrend == DOWN`: reference (SH terakhir)
malah lebih RENDAH dari `g_htfIdmPrice` (SH lama, lebih tinggi) karena downtrend
bikin higher-highs makin turun. Equilibrium jadi ada DI ATAS reference, sehingga
syarat `reference > entry` (validasi arah) hampir otomatis bikin equilibrium
check lolos — filter discount/premium-nya jadi nyaris tidak menyaring apa-apa.

**Previous-swing body-break filter** (`HtfPrevSwingBodyBroken`, `AjipIDM_HtfContext.mqh`) — WAJIB, dicek sebelum reference swing:
```
Uptrend (BUY):   reference = SHU_cur (SH terakhir). SHU_prev = SH sebelum itu.
                 Walk HTF bar-by-bar dari SHU_prev sampai SHU_cur, watchLevel
                 mulai dari SHU_prev.price:
                   bar.close > watchLevel → BROKEN, entry BOLEH lanjut, stop
                   belum broken, tapi bar.high > watchLevel → watchLevel
                     naik ke bar.high itu (RATCHET, ikut level sweep terdalam)
                 Kalau sampai SHU_cur tidak ada bar yang close lewat watchLevel
                 (yang sudah ter-ratchet) → SKIP entry.
Downtrend (SELL): sama, cermin (watchLevel turun ke bar.low, close harus < watchLevel).
```
Rasional: kalau level SH/SL sebelumnya cuma disweep (wick tembus, close gagal
reclaim), leg yang membentuk swing reference saat ini secara struktural lemah —
bukan breakout asli, jadi entry di-skip. **Level yang wajib ditembus ikut naik/turun**
kalau price sweep makin dalam tanpa reclaim — reclaim balik ke atas level
SHU_prev ASLI saja TIDAK cukup kalau price sempat sweep lebih jauh lagi sebelum
reclaim itu; harus reclaim lewat titik sweep TERDALAM. Kalau belum ada swing
sejenis sebelumnya (baru saja reversal, cuma 1 swing sejenis) filter ini
fail-open (BOLEH entry) — tidak ada history buat dibandingkan.

**Reference swing** (`HtfEntryAllowed`, `AjipIDM_Entry.mqh`) — dipakai HANYA untuk menghitung equilibrium, bukan sebagai TP order:
```
BUY:  reference = GetLastHtfSHDPrice()   (last SH-type swing di g_htfSwings)
SELL: reference = GetLastHtfSLUPrice()   (last SL-type swing di g_htfSwings)
reference harus valid (>0) dan searah entry (BUY: reference > entry, SELL: reference < entry)
```

**Equilibrium (discount/premium) filter** — WAJIB, bukan opsional:
```
range = [g_htfIdmPrice, reference]
equilibrium = (g_htfIdmPrice + reference) / 2

BUY:  entry price harus <= equilibrium (discount) → kalau lebih tinggi, SKIP
SELL: entry price harus >= equilibrium (premium)  → kalau lebih rendah, SKIP
```

Min-points filter (`InpMinTpPoints`) tetap dicek di sini juga — jarak reference
ke entry harus >= `InpMinTpPoints`, sekadar filter kualitas setup (reference
swing HTF-nya jangan terlalu dekat), bukan penentu TP karena tidak ada TP.
Kalau `g_htfIdmPrice` belum siap (belum ke-init), entry di-skip.

**HTF structure/idm digambar juga di chart** (`DrawHtfSwings()`, aktif kalau `InpDrawLines`):
- Object prefix `g_htfObjPrefix` ("AjipIDMHtf_") — terpisah dari `g_objPrefix` LTF dan `g_panelPrefix`, supaya tidak saling ke-wipe oleh `ObjectsDeleteAll`.
- Visual dibedakan dari garis LTF: swing line dotted (`STYLE_DOT`, width 2, ungu untuk SH / emas untuk SL) vs LTF solid (dodger blue/orange red). idm line HTF kuning dash-dot vs idm LTF hitam dash.
- Redraw dipanggil tiap HTF bar closed diproses, plus di `InitHtfStructure` dan tiap kali `HtfReverseToDowntrend`/`HtfReverseToUptrend` (mirror pola LTF).

## Fixed Lot, No SL/TP at Entry

Varian ini tidak lagi menghitung lot dari target profit maupun SL dari RR:
- `OpenTrade` selalu buka posisi dengan lot = `InpFixedLot`, SL=0, TP=0.
- Tidak ada TP order sama sekali, selamanya.
- SL nol **di entry**, tapi bisa muncul belakangan dari dua sumber: breakeven
  setelah partial close, atau [Aggregate SL](architecture.md#aggregate-sl) yang
  membagikan budget max-loss terkecil ke posisi yang belum punya stop.

**Batas eksposur** (bukan exit, tapi pembatas pembukaan posisi baru):
- `InpMaxTotalLots` — cap volume **per arah, independen**. Jumlah posisi tidak
  dibatasi; yang dibatasi volume.
- `InpAllowHedging=false` — BUY dan SELL tidak boleh terbuka bersamaan. Entry
  baru diblokir selama sisi lawan masih ada (bukan menutup paksa sisi lawan).
  Untuk prop firm yang melarang hedging.

## Partial Close (One-Time per Posisi) + Breakeven SL

`CheckPartialClose` (`AjipIDM_Entry.mqh`), jalan tiap tick untuk setiap posisi yang ditrack:
```
profitPoints = (dir BUY: Bid - entryPrice) atau (dir SELL: entryPrice - Ask), dalam points

Kalau profitPoints >= InpPartialClosePoints DAN belum pernah partial-close:
  closeVolume = posVolume * (InpPartialClosePercent / 100), dibulatkan ke volume step
  Kalau closeVolume atau remainder < g_volMin → skip (terlalu kecil buat displit)
  Sebaliknya:
    1. PositionClosePartial(ticket, closeVolume)
    2. Kalau berhasil dan sisa posisi masih ada → PositionModify(ticket, SL=entryPrice, TP=0)
       (SL dipindah ke BREAKEVEN — TP tetap 0, tidak berubah)
  → tandai partialClosed = true (SATU KALI SAJA per posisi, tidak scaling —
    BE SL juga cuma di-set sekali di titik ini, tidak di-trail lebih lanjut)
```
Sisa volume (`remainder`) jalan terus dengan SL di breakeven (tanpa TP), menunggu stop-out di entry, batch/daily close-all, atau ditutup manual.

## Final Close-All (Target / Max Loss) — Berhenti PERMANEN

Lapisan risiko paling tinggi, **lintas hari** dan tidak reset tiap pagi. Dicek paling awal tiap tick, sebelum batch dan daily.

```
baseline = InpStartingBalance (0 = auto-capture balance saat first run, lalu dipersist)
total    = (balance sekarang - baseline) + GetFloatingPnL()

InpFinalProfitTarget > 0 DAN total >= InpFinalProfitTarget → CloseAllAndFlushBatch + STOP PERMANEN
InpFinalMaxLoss      > 0 DAN total <= -InpFinalMaxLoss     → CloseAllAndFlushBatch + STOP PERMANEN
```

Bedanya dengan daily: daily membuka lagi keesokan harinya, final **tidak pernah** — entry baru berhenti sampai input di-reset manual. Baseline dipersist supaya tidak ikut bergeser tiap restart EA.

## Daily Close-All (Target / Max Loss) — Blokir Entry Sisa Hari

`CheckDailyCloseAll` (`AjipIDM_Trade.mqh`), jalan tiap tick:
```
total = GetDailyPnL() (realized, SEMUA batch hari ini) + GetFloatingPnL() (floating semua posisi open)

InpDailyMaxProfit > 0 DAN total >= InpDailyMaxProfit → CloseAllAndFlushBatch("DAILY_TARGET")
InpDailyMaxLoss   > 0 DAN total <= -InpDailyMaxLoss  → CloseAllAndFlushBatch("DAILY_MAX_LOSS")
```
Setelah close-all, `DailyLimitReached()` (realized-only) otomatis memblokir entry baru untuk **SISA HARI ITU** — ini circuit breaker paling tinggi, terpisah dari batch limit di bawah.

## Batch Close-All (Target / Max Loss) — TIDAK Blokir Entry

`CheckBatchCloseAll` (`AjipIDM_Trade.mqh`), jalan tiap tick, TERPISAH dari daily:
```
total = g_batchRealizedPnl (realized BATCH INI SAJA, bukan seluruh hari) + GetFloatingPnL()

InpBatchMaxProfit > 0 DAN total >= InpBatchMaxProfit → CloseAllAndFlushBatch("BATCH_TARGET")
InpBatchMaxLoss   > 0 DAN total <= -InpBatchMaxLoss  → CloseAllAndFlushBatch("BATCH_MAX_LOSS")
```
Bedanya sama Daily: batch limit CUMA nutup batch yang sedang berjalan — **tidak ada apa pun yang ngeblok entry baru** setelahnya (`DailyLimitReached()`/`InSession()` gak disentuh). Selama daily limit belum ikut kena, batch baru boleh langsung mulai lagi begitu ada sinyal entry berikutnya. Ini yang bikin **1 hari kalender bisa punya lebih dari 1 baris di batch CSV** — tiap kali batch limit kena, itu 1 baris, dan siklusnya bisa berulang berkali-kali dalam 1 hari selama daily limit belum tercapai.

`CloseAllAndFlushBatch(reason)` (`AjipIDM_Trade.mqh`) yang benar-benar menutup posisi + nulis CSV, dipanggil dari kedua fungsi di atas maupun `CheckSessionCloseAll`. Ini dikerjakan SECARA ATOMIK (tutup + accumulate + tulis CSV + reset, satu pemanggilan) — bukan nunggu bar berikutnya — supaya entry baru (yang boleh langsung nyala lagi khusus buat batch limit) gak nyelip masuk sebelum batch lama beres di-flush. `CheckEntryCleanup()` (`AjipIDM_Entry.mqh`) cuma nangkep posisi yang closed DI LUAR close-all (mis. kena breakeven stop) — fold ke accumulator, gak pernah nulis CSV sendiri. Detail lengkap kolom CSV & flush mechanics — lihat [Batch CSV Report](architecture.md#batch-csv-report-per-setup) di architecture.md.

## Trading Session (Jam Buka/Tutup)

`InpSessionStart`/`InpSessionEnd` (server time, format `"HH:MM"`) membatasi KAPAN entry baru boleh dibuka, dan memicu profit-lock di luar jam tersebut:

```
Parse sekali di OnInit → g_sessionStartMin/g_sessionEndMin (menit sejak tengah malam).
start == end (atau parse gagal) → g_sessionFilterEnabled = false (TIDAK ada
  restriction sama sekali — InSession() selalu true, default kalau kedua
  input dibiarkan "00:00").

InSession() — tiap dipanggil, bandingkan TimeCurrent() (server time, SAMA
  clock dengan GetDailyPnL) terhadap [start, end):
  start <= end : nowMin >= start AND nowMin < end
  start >  end : nowMin >= start OR  nowMin < end   (wrap tengah malam, mis. 22:00-06:00)
```

**Entry gate:** `InSession()` dicek di `CheckIdmZoneEntry` dan `CheckAggressiveZoneEntry` (kedua jalur ENTRY), sejajar dengan `DailyLimitReached()` — di luar sesi, entry baru di-skip. Struktur/reversal LTF tetap jalan normal; yang di-suppress hanya entry-nya.

**Profit lock di luar sesi** (`CheckSessionCloseAll`, tiap tick):
```
Kalau !InSession() DAN total (realized+floating, SAMA formula dengan
  CheckDailyCloseAll) > 0 → CloseAllAndFlushBatch("SESSION_END")
```
Ini yang menjawab kasus "PnL belum mencapai `InpDailyMaxProfit` tapi udah positif waktu jam tutup" — begitu keluar dari jendela sesi dan total masih positif (berapa pun besarnya, tidak perlu sampai `InpDailyMaxProfit`), semua posisi ditutup supaya profit tidak "dibalikin" di luar jam trading. Kalau PnL negatif saat itu, posisi TIDAK dipaksa tutup — tetap jalan (nunggu balik positif, kena `InpDailyMaxLoss`, atau ditutup manual).

## News Blackout (Gate Entry)

`InpNewsFilterEnabled` (default aktif) memblokir entry baru di sekitar rilis kalender high-impact yang menyangkut mata uang simbol ini — XAUUSD mengecek event XAU **dan** USD.

```
Window blokir: [now - InpNewsMinutesAfter, now + InpNewsMinutesBefore]
Importance minimum: InpNewsMinImportance (default CALENDAR_IMPORTANCE_HIGH)
```

Hanya gate entry — **posisi yang sudah terbuka tidak ditutup**. Kalau kalender MT5 tidak tersedia (mis. Strategy Tester tanpa data ter-cache), filter ini otomatis non-blocking, bukan memblokir semuanya. Detail cache & implementasi: [News Blackout](architecture.md#news-blackout).

## Batch Cooldown

`InpBatchCooldownMinutes` — setelah sebuah batch benar-benar flat, entry baru ditahan selama N menit. Mencegah batch baru langsung nyambung ke batch yang baru saja ditutup, sehingga tiap batch berdiri sebagai satu "ronde" yang terpisah.

## Entry Decoupling (Zone Entry)

**Entry dan reversal sudah dipisah total.** Dulu keduanya satu fungsi: idm ter-sweep → reverse structure → langsung `OpenTrade`. Sekarang dua jalur independen yang tidak saling menunggu:

| | Fungsi | Level pemicu | Tugas |
|---|---|---|---|
| **Reversal** | `CheckIdmTaken` (bar-close)<br>`CheckAggressiveIdmTouch` (per-tick) | `g_idmPrice` — sweep PENUH idm | Hanya membalik struktur. **Tidak pernah entry.** |
| **Entry** | `CheckIdmZoneEntry` (bar-close)<br>`CheckAggressiveZoneEntry` (per-tick) | `g_idmZonePrice` — extreme BERLAWANAN dari bar idm | Hanya entry. **Tidak menyentuh struktur.** |

`g_idmZonePrice` adalah boundary yang lebih LONGGAR: ia extreme berlawanan dari bar idm (uptrend: `high` dari bar SL yang jadi idm), jadi harga menyentuhnya **lebih dulu** saat retrace, sebelum sampai ke sweep penuh `g_idmPrice`. Konsekuensinya entry bisa terjadi sebelum, sesudah, atau **tanpa** reversal itu pernah terjadi sama sekali.

**One-shot per level idm:** `g_idmZoneEntryFiredTime == g_idmTime` dipakai bersama oleh kedua jalur entry — jadi hanya SATU entry per level idm, tidak peduli jalur mana yang menangkap duluan. Ini yang menggantikan guard anti-double-entry versi lama.

**Syarat `g_idmConfirmed`:** kedua jalur entry menolak idm yang masih dangling (origin tunggal tepat setelah reversal, belum punya swing lawan) — itu belum idm sungguhan, cuma ekor leg yang baru selesai. `CheckAggressiveIdmTouch` juga mensyaratkan ini sejak commit `9f81db4`, kalau tidak satu wick tunggal bisa membalik trend bolak-balik tanpa struktur nyata di belakangnya.

## Aggressive Mode (`InpUseAggressiveEntry`)

Toggle ini mengaktifkan **jalur per-tick** untuk keduanya (reversal dan zone entry). Kalau `false`, hanya jalur bar-close yang jalan.

**Reversal per-tick** (`CheckAggressiveIdmTouch`): begitu Bid menembus `g_idmPrice` intrabar, struktur dibalik SAAT ITU JUGA tanpa menunggu bar close. Anti-repaint-nya: origin dan retroactive rebuild memakai **bar CLOSED terakhir** (`rates[1]`) sebagai boundary, bukan bar yang sedang terbentuk — jadi seluruh perhitungan tetap dari data final.

```
Per-tick (CheckAggressiveIdmTouch):
  Guard: g_idmTaken, g_idmPrice > 0, !g_initMode, g_idmConfirmed
  TREND_UP   & Bid < g_idmPrice → ReverseToDowntrend(rates[1])
  TREND_DOWN & Bid > g_idmPrice → ReverseToUptrend(rates[1])
  1x per bar forming (g_aggressiveFiredBarTime)
```

Begitu bar yang disentuh itu benar-benar close, ia mengalir lewat `UpdateStructure()` normal seperti bar mana pun — melanjutkan struktur yang sudah dibalik duluan.

**Trade-off:** jalur per-tick mengorbankan filter "no body break" (bereaksi di setiap sentuhan, bukan hanya yang close-nya sudah reclaim) demi harga lebih awal. Gate HTF equilibrium sama persis di kedua jalur — yang beda cuma KAPAN dieksekusi.

## Contoh Full Cycle (Chained Example)

Contoh ini mengilustrasikan siklus reversal + ENTRY DECISION di LTF (kapan/arah entry).

```
1. UP: SLU0(100) - SHU1(110) - SLU1(105) - SHU2(115) - SLU2(108, idm) - SHU3(120)
2. Price dari SHU3 turun, candle low = 107 (< SLU2=108) → IDM TAKEN (LTF)
   Trend LTF → DOWN. Build dari SHU3(120) = SHD0
   Retroactive structure LTF: SHD0(120) - SLD1(112) - SHD1(118) - SLD2(107)
3. Candle close = 109 (> SLU2=108) → sinyal BUY di harga close 109
   Equilibrium HTF dicek via HtfEntryAllowed (struktur HTF saat itu) — kalau
   lolos, BUY @ 109, lot = InpFixedLot, tanpa SL/TP.

4. Posisi jalan tanpa TP/SL — di +InpPartialClosePoints, partial close sekali
   (InpPartialClosePercent dari volume) lalu SL sisanya dipindah ke breakeven
   (109). Sisa posisi ditutup saat kena BE atau daily target/max loss
   tercapai (CheckDailyCloseAll).
5. Siklus reversal LTF berikutnya berjalan sama seperti di atas untuk SELL.
```
