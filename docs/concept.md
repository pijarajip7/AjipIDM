# AjipIDM — Konsep & Strategi

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

Keputusan ENTRY (kapan & arah) masih murni dari struktur LTF (`InpTimeframe`) — tidak berubah dari sebelumnya. Yang berubah: TP, equilibrium (discount/premium) filter, dan invalidation semuanya sekarang mengacu ke HTF (`InpHtfTimeframe`) — lihat [HTF-Referenced Entry Engine](#htf-referenced-entry-engine-tp-equilibrium-invalidation) di bawah.

**BUY** (uptrend → idm taken dari bawah):
```
Condition: candle low < SLU_last (idm LTF) AND close > SLU_last
→ No body break = sweep/fakeout
→ TP/SL/equilibrium dihitung via ComputeHtfEntryLevels (HTF) — kalau lolos semua
  filter, BUY @ close price
```

**SELL** (downtrend → idm taken dari atas):
```
Condition: candle high > SHD_last (idm LTF) AND close < SHD_last
→ No body break = sweep/fakeout
→ TP/SL/equilibrium dihitung via ComputeHtfEntryLevels (HTF) — kalau lolos semua
  filter, SELL @ close price
```

**Body break = no entry:**
- Uptrend idm: close < SLU_last → downtrend confirmed, lanjut track
- Downtrend idm: close > SHD_last → uptrend confirmed, lanjut track

## HTF-Referenced Entry Engine (TP, Equilibrium, Invalidation)

HTF context (`AjipIDM_HtfContext.mqh`, globals `g_htf*`) **selalu aktif** (tidak ada toggle) — dia bukan lagi sekadar filter opsional, tapi sumber TP, equilibrium filter, dan invalidation untuk SETIAP entry:

- Struktur/idm HTF-nya sendiri (algoritma SL/SH + idm YANG SAMA seperti LTF), di-update tiap HTF bar closed (gate independen dari LTF new-bar gate — HTF bar closed lebih jarang dari LTF, jadi HTF check jalan tiap tick, TIDAK boleh diletakkan setelah LTF early-return).
- Reuse `InpCandlesInit` untuk lookback init (tidak ada input terpisah).
- Logic (pullback, simple structure, idm, reversal) adalah port 1:1 dari engine LTF.

**HTF trend alignment** — WAJIB, dicek pertama sebelum apa pun:
```
BUY  hanya jalan kalau g_htfTrend == TREND_UP
SELL hanya jalan kalau g_htfTrend == TREND_DOWN
```
Tanpa ini, `GetLastHtfSHDPrice`/`SLUPrice` bisa ambil swing dari struktur yang
"salah bentuk" — misal BUY saat `g_htfTrend == DOWN`: TP (SH terakhir) malah
lebih RENDAH dari `g_htfIdmPrice` (SH lama, lebih tinggi) karena downtrend
bikin higher-highs makin turun. Equilibrium jadi ada DI ATAS tp, sehingga
syarat `tp > entry` (validasi arah) hampir otomatis bikin equilibrium check
lolos — filter discount/premium-nya jadi nyaris tidak menyaring apa-apa.

**Previous-swing body-break filter** (`HtfPrevSwingBodyBroken`, `AjipIDM_HtfContext.mqh`) — WAJIB, dicek sebelum TP:
```
Uptrend (BUY):   TP swing = SHU_cur (SH terakhir). SHU_prev = SH sebelum itu.
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
reclaim), leg yang membentuk swing TP saat ini secara struktural lemah — bukan
breakout asli, jadi entry di-skip. **Level yang wajib ditembus ikut naik/turun**
kalau price sweep makin dalam tanpa reclaim (sama seperti pola deepening watch
`g_htfSweepPrice` di [Invalidation](#htf-referenced-entry-engine-tp-equilibrium-invalidation)
di bawah) — reclaim balik ke atas level SHU_prev ASLI saja TIDAK cukup kalau
price sempat sweep lebih jauh lagi sebelum reclaim itu; harus reclaim lewat
titik sweep TERDALAM. Kalau belum ada swing sejenis sebelumnya (baru saja
reversal, cuma 1 swing sejenis) filter ini fail-open (BOLEH entry) — tidak ada
history buat dibandingkan.

**TP** (`ComputeHtfEntryLevels`, `AjipIDM_Entry.mqh`):
```
BUY:  tp = GetLastHtfSHDPrice()   (last SH-type swing di g_htfSwings)
SELL: tp = GetLastHtfSLUPrice()   (last SL-type swing di g_htfSwings)
tp harus valid (>0) dan searah entry (BUY: tp > entry, SELL: tp < entry)
```

**Equilibrium (discount/premium) filter** — WAJIB, bukan opsional:
```
range = [g_htfIdmPrice, tp]
equilibrium = (g_htfIdmPrice + tp) / 2

BUY:  entry price harus <= equilibrium (discount) → kalau lebih tinggi, SKIP
SELL: entry price harus >= equilibrium (premium)  → kalau lebih rendah, SKIP
```

Min TP points filter (`InpMinTpPoints`) tetap dicek di sini juga, terhadap TP HTF.
Kalau `g_htfIdmPrice` belum siap (belum ke-init), entry di-skip.

**SL** = `entry ∓ (tpDistance / InpRR)`, RR=0 → no SL. Sama formula seperti sebelumnya, cuma `tpDistance`-nya sekarang dari TP HTF.

**Invalidation** — HTF-driven, portfolio-level (BUKAN per-ticket lagi):
```
HtfCheckIdmTaken (tiap HTF bar close):
  idm HTF taken → simpan g_htfSweepPrice = idm HTF (sebelum reverse),
                  g_htfSweepDir = 1 (BUY terancam) kalau g_htfTrend lama UP,
                                  -1 (SELL terancam) kalau DOWN
                  → overwrite watch sebelumnya kalau ada (event terbaru menang)

CheckHtfInvalidation (tiap HTF bar close, setelah HtfCheckIdmTaken):
  Phase 1 — body break: HTF close gagal reclaim g_htfSweepPrice
    → ApplyHtfInvalidation(dir): hitung rata-rata entryPrice SEMUA posisi
      open yang dir-nya cocok → InpInvalidationMode:
        DO_NOTHING: TP/SL dibiarkan apa adanya
        FIXED_TP:   newTP = avgEntry ± InpInvalidationTpPoints (semua posisi
                    yang cocok di-modify ke TP yang SAMA)
      → posisi yang kena di-remove dari tracking (tidak dicek lagi)
  Phase 2 — belum break: kalau bar ini extreme-nya lebih dalam, geser
    g_htfSweepPrice (mirror sweep-update LTF yang lama, sekarang di level HTF)
```

Karena ini portfolio-level (bukan per-ticket), `EntryTracker` sudah tidak nyimpen `sweepPrice` lagi — cuma `ticket, dir, entryPrice, entryTime, mfe, mae`. `CheckEntryCleanup()` (dulu `CheckEntryInvalidation`) sekarang cuma tugas cleanup: deteksi posisi yang closed (TP/SL hit) → log CSV → hapus dari tracking. Auto-cleanup ini tetap jalan terlepas dari status invalidation.

**HTF structure/idm digambar juga di chart** (`DrawHtfSwings()`, aktif kalau `InpDrawLines`):
- Object prefix `g_htfObjPrefix` ("AjipIDMHtf_") — terpisah dari `g_objPrefix` LTF dan `g_panelPrefix`, supaya tidak saling ke-wipe oleh `ObjectsDeleteAll`.
- Visual dibedakan dari garis LTF: swing line dotted (`STYLE_DOT`, width 2, ungu untuk SH / emas untuk SL) vs LTF solid (dodger blue/orange red). idm line HTF kuning dash-dot vs idm LTF hitam dash.
- Redraw dipanggil tiap HTF bar closed diproses, plus di `InitHtfStructure` dan tiap kali `HtfReverseToDowntrend`/`HtfReverseToUptrend` (mirror pola LTF).

## Aggressive Entry Mode (opsional)

Default (**confirmation entry**): entry hanya jalan setelah bar close, memakai `bar.close` untuk memutuskan sweep (no body break) vs body break. Ini filter inti strategi — entry cuma terjadi kalau close sudah reclaim idm.

**Aggressive entry** (`InpUseAggressiveEntry=true`): entry market langsung begitu harga MENYENTUH idm intrabar (per-tick, bar belum close), tanpa nunggu konfirmasi reclaim. Begitu tersentuh, structure LANGSUNG di-reverse (bukan nunggu close) dengan trik: origin & retroactive rebuild pakai bar CLOSED terakhir sebagai boundary (bukan bar yang lagi forming) — jadi datanya tetap 100% final, tidak ada repaint risk. TP structural pun langsung tersedia → SL/TP dipasang di order SEJAK ENTRY, tidak ada window naked sama sekali.

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
     (Struktur LTF ini dipakai buat entry-decision bar berikutnya, BUKAN buat TP.)
  3. TP/SL/equilibrium via ComputeHtfEntryLevels (HTF) — SAMA PERSIS logic-nya
     seperti confirmation entry, termasuk equilibrium filter (equilibrium BISA
     dievaluasi di titik touch karena rangenya dari HTF, bukan dari bar LTF
     yang lagi forming).
  4. OpenTrade(isBuy, entry, sl, tp) — SL/TP REAL langsung terpasang di order
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
yang sudah di-reverse duluan di step 2, seperti bar manapun. Invalidation entry
ini sepenuhnya di luar siklus bar LTF-nya sendiri — ditentukan oleh HTF
(lihat CheckHtfInvalidation di atas), bukan oleh bar LTF yang jadi titik touch.
```

**Beda vs confirmation entry:** aggressive entry mengorbankan filter "no body break" LTF (entry di setiap sentuhan idm LTF, bukan cuma yang confirmed reclaim) demi harga entry lebih awal. TP/equilibrium/invalidation sama persis (semua HTF-referenced) — bedanya cuma KAPAN entry-nya dieksekusi.

## Contoh Full Cycle (Chained Example)

Contoh ini mengilustrasikan siklus reversal + ENTRY DECISION di LTF (kapan/arah entry) — struktur SHD1/SLU yang dipakai sebagai "TP" di bawah ini murni buat ilustrasi mekanisme reversal LTF. TP/SL yang SEBENARNYA di-set EA dihitung dari struktur HTF (`ComputeHtfEntryLevels`), bukan dari struktur LTF yang digambarkan di sini — lihat [HTF-Referenced Entry Engine](#htf-referenced-entry-engine-tp-equilibrium-invalidation).

```
1. UP: SLU0(100) - SHU1(110) - SLU1(105) - SHU2(115) - SLU2(108, idm) - SHU3(120)
2. Price dari SHU3 turun, candle low = 107 (< SLU2=108) → IDM TAKEN (LTF)
   Trend LTF → DOWN. Build dari SHU3(120) = SHD0
   Retroactive structure LTF: SHD0(120) - SLD1(112) - SHD1(118) - SLD2(107)
3. Candle close = 109 (> SLU2=108) → sinyal BUY di harga close 109
   TP/SL sebenarnya dari ComputeHtfEntryLevels (struktur HTF saat itu), bukan
   dari SHD1(118) di atas — angka itu cuma konteks reversal LTF.

4. TP HTF hit → Position closed.
5. Siklus reversal LTF berikutnya berjalan sama seperti di atas untuk SELL,
   TP/SL-nya juga tetap dari ComputeHtfEntryLevels.
```
