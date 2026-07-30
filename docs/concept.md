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
3. Cek close candle untuk entry decision

## Entry Rules

Keputusan ENTRY (kapan & arah) masih murni dari struktur LTF (`InpTimeframe`) — tidak berubah dari sebelumnya. Yang berubah: equilibrium (discount/premium) filter sekarang mengacu ke HTF (`InpHtfTimeframe`) — lihat [HTF-Referenced Equilibrium Gate](#htf-referenced-equilibrium-gate) di bawah. **Tidak ada TP/SL** — lot selalu fixed (`InpFixedLot`), exit murni lewat [Partial Close](#partial-close-one-time-per-posisi) dan [Daily Close-All](#daily-close-all-target--max-loss).

**BUY** (uptrend → idm taken dari bawah):
```
Condition: candle low < SLU_last (idm LTF) AND close > SLU_last
→ No body break = sweep/fakeout
→ Equilibrium HTF dicek via HtfEntryAllowed — kalau lolos semua filter,
  BUY @ close price, lot = InpFixedLot, tanpa SL/TP
```

**SELL** (downtrend → idm taken dari atas):
```
Condition: candle high > SHD_last (idm LTF) AND close < SHD_last
→ No body break = sweep/fakeout
→ Equilibrium HTF dicek via HtfEntryAllowed — kalau lolos semua filter,
  SELL @ close price, lot = InpFixedLot, tanpa SL/TP
```

**Body break = no entry:**
- Uptrend idm: close < SLU_last → downtrend confirmed, lanjut track
- Downtrend idm: close > SHD_last → uptrend confirmed, lanjut track

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
- Exit datang dari dua mekanisme di bawah — tidak ada TP order sama sekali. SL
  TETAP nol sampai partial close terjadi (lihat breakeven SL di bawah); tidak
  ada SL awal di entry.

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
Sisa volume (`remainder`) jalan terus dengan SL di breakeven (tanpa TP), menunggu stop-out di entry, daily close-all, atau ditutup manual.

## Daily Close-All (Target / Max Loss)

`CheckDailyCloseAll` (`AjipIDM_Entry.mqh`), jalan tiap tick:
```
total = GetDailyPnL() (realized, closed deals hari ini) + GetFloatingPnL() (floating semua posisi open)

InpDailyMaxProfit > 0 DAN total >= InpDailyMaxProfit → CloseAllPositions()
InpDailyMaxLoss   > 0 DAN total <= -InpDailyMaxLoss  → CloseAllPositions()
```
`CloseAllPositions()` menutup SEMUA posisi (symbol + magic ini), termasuk yang sudah kena partial close sebagian. Floating diikutkan di `total` supaya trigger-nya reaktif — tidak perlu nunggu posisi ditutup manual dulu baru target/loss "kehitung". Setelah close-all, `DailyLimitReached()` (realized-only) otomatis memblokir entry baru untuk sisa hari itu.

`CheckEntryCleanup()` cuma tugas cleanup: deteksi posisi yang BENAR-BENAR closed (bukan partial) → log CSV → hapus dari tracking.

## Aggressive Entry Mode (opsional)

Default (**confirmation entry**): entry hanya jalan setelah bar close, memakai `bar.close` untuk memutuskan sweep (no body break) vs body break. Ini filter inti strategi — entry cuma terjadi kalau close sudah reclaim idm.

**Aggressive entry** (`InpUseAggressiveEntry=true`): entry market langsung begitu harga MENYENTUH idm intrabar (per-tick, bar belum close), tanpa nunggu konfirmasi reclaim. Begitu tersentuh, structure LANGSUNG di-reverse (bukan nunggu close) dengan trik: origin & retroactive rebuild pakai bar CLOSED terakhir sebagai boundary (bukan bar yang lagi forming) — jadi datanya tetap 100% final, tidak ada repaint risk.

```
Per-tick, saat idm LTF tersentuh (CheckAggressiveIdmTouch):
  TREND_UP   & Bid < idm → arah BUY (fade)
  TREND_DOWN & Bid > idm → arah SELL (fade)

  1. Guard: 1x entry per bar forming (g_aggressiveFiredBarTime), daily limit
     dicek di titik ini (kalau gagal, tidak entry; confirmation-mode di bar
     close tetap jadi fallback normal)
  2. ReverseToDowntrend/Uptrend(rates[1])  ← rates[1] = bar LTF CLOSED terakhir,
     BUKAN bar yang sedang forming. Origin + retroactive structure LTF 100%
     dari data final, g_trend & g_idmPrice (LTF) langsung pindah ke trend baru.
     (Struktur LTF ini dipakai buat entry-decision bar berikutnya.)
  3. Equilibrium via HtfEntryAllowed (HTF) — SAMA PERSIS logic-nya seperti
     confirmation entry (equilibrium BISA dievaluasi di titik touch karena
     rangenya dari HTF, bukan dari bar LTF yang lagi forming).
  4. OpenTrade(isBuy, entry) — fixed lot, tanpa SL/TP
  5. AddEntry(ticket, dir) — masuk tracking normal

**Anti-double-entry:** begitu bar LTF yang disentuh itu BENERAN close, trend/idm
sudah pindah ke yang baru (dari step 2) — jadi `CheckIdmTaken` di closed-bar bisa
saja NEMU "taken" lagi untuk trend baru itu PADA BAR YANG SAMA (kalau bar-nya
lebar), dan mau buka entry KEDUA untuk event yang sebenarnya sama. Dicegah via
guard `bar.time == g_aggressiveFiredBarTime` di `CheckIdmTaken` — kalau match,
entry di-skip (structure/reverse tetap jalan normal, cuma bagian OpenTrade-nya
yang disuppress buat bar itu).

Begitu bar LTF yang tadi "disentuh" itu BENERAN close (flow OnTick standar,
tidak ada kode khusus tambahan): UpdateStructure() melanjutkan structure LTF
yang sudah di-reverse duluan di step 2, seperti bar manapun.
```

**Beda vs confirmation entry:** aggressive entry mengorbankan filter "no body break" LTF (entry di setiap sentuhan idm LTF, bukan cuma yang confirmed reclaim) demi harga entry lebih awal. Equilibrium gate sama persis (HTF-referenced) — bedanya cuma KAPAN entry-nya dieksekusi.

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
