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

## Entry Invalidation (body break setelah entry)

Entry premise: idm sweep (wick takes idm) tapi close reclaim.

**Sweep level** = high/low bar yang ambil idm (bukan idm price):
- BUY: sweep level = LOW bar yang sweep
- SELL: sweep level = HIGH bar yang sweep

**Sweep update:** jika bar berikutnya sweep lebih dalam, update sweep level.

**Body break = invalidasi:** close menembus sweep level TERBARU → premise gagal. Aksi ditentukan oleh `InpInvalidationMode`:

```
INVALIDATION_DO_NOTHING (default): TP/SL dibiarkan apa adanya, tidak ada modify.
INVALIDATION_FIXED_TP: TP digeser ke entry ± InpInvalidationTpPoints
  BUY:  newTP = entryPrice + (InpInvalidationTpPoints * point)
  SELL: newTP = entryPrice - (InpInvalidationTpPoints * point)
  InpInvalidationTpPoints = 0 → setara TP to break-even (newTP = entryPrice)
```

SL tetap tidak berubah pada kedua mode. Posisi TIDAK di-close — biarkan broker manage.

**Multi-position:** tiap entry ditrack per-ticket (EntryTracker array: ticket, sweepPrice, dir).
Auto-cleanup: posisi yang sudah TP/SL hit otomatis di-remove dari tracking.

**Body break dievaluasi SEBELUM sweep update** (fix bug: sweep update duluan menyembunyikan body break).
Invalidasi dievaluasi pada CLOSED bar, BEFORE CheckIdmTaken.

## HTF Trend Filter (opsional)

Filter entry berdasarkan trend di timeframe lebih tinggi (`InpHtfTimeframe`), pakai algoritma SL/SH + idm YANG SAMA seperti LTF (bukan MA/indicator lain) — supaya definisi trend konsisten di seluruh EA.

```
InpUseHtfFilter=true:
  BUY  entry hanya jalan jika g_htfTrend == TREND_UP
  SELL entry hanya jalan jika g_htfTrend == TREND_DOWN
  g_htfTrend == TREND_NONE (belum ke-init) → BUY dan SELL dua-duanya diblok
```

HTF context adalah engine terpisah & mandiri (`AjipIDM_HtfContext.mqh`, globals `g_htf*`):
- Struktur/idm-nya sendiri, di-update tiap HTF bar closed (gate independen dari LTF new-bar gate — HTF bar closed lebih jarang dari LTF, jadi HTF check jalan tiap tick, TIDAK boleh diletakkan setelah LTF early-return).
- TIDAK PERNAH entry, TIDAK PERNAH invalidation, TIDAK PERNAH daily-limit check — murni context/filter.
- Reuse `InpCandlesInit` untuk lookback init (tidak ada input terpisah).
- Logic (pullback, simple structure, idm, reversal) adalah port 1:1 dari engine LTF — lihat file untuk detail.

**HTF structure/idm digambar juga di chart** (`DrawHtfSwings()`, aktif jika `InpDrawLines && InpUseHtfFilter`):
- Object prefix `g_htfObjPrefix` ("AjipIDMHtf_") — terpisah dari `g_objPrefix` LTF dan `g_panelPrefix`, supaya tidak saling ke-wipe oleh `ObjectsDeleteAll`.
- Visual dibedakan dari garis LTF: swing line dotted (`STYLE_DOT`, width 2, ungu untuk SH / emas untuk SL) vs LTF solid (dodger blue/orange red). idm line HTF kuning dash-dot vs idm LTF hitam dash.
- Redraw dipanggil tiap HTF bar closed diproses, plus di `InitHtfStructure` dan tiap kali `HtfReverseToDowntrend`/`HtfReverseToUptrend` (mirror pola LTF).

## Aggressive Entry Mode (opsional)

Default (**confirmation entry**): entry hanya jalan setelah bar close, memakai `bar.close` untuk memutuskan sweep (no body break) vs body break. Ini filter inti strategi — entry cuma terjadi kalau close sudah reclaim idm.

**Aggressive entry** (`InpUseAggressiveEntry=true`): entry market langsung begitu harga MENYENTUH idm intrabar (per-tick, bar belum close), tanpa nunggu konfirmasi reclaim. Begitu tersentuh, structure LANGSUNG di-reverse (bukan nunggu close) dengan trik: origin & retroactive rebuild pakai bar CLOSED terakhir sebagai boundary (bukan bar yang lagi forming) — jadi datanya tetap 100% final, tidak ada repaint risk. TP structural pun langsung tersedia → SL/TP dipasang di order SEJAK ENTRY, tidak ada window naked sama sekali.

```
Per-tick, saat idm tersentuh (CheckAggressiveIdmTouch):
  TREND_UP   & Bid < idm → arah BUY (fade)
  TREND_DOWN & Bid > idm → arah SELL (fade)

  1. Guard: 1x entry per bar forming (g_aggressiveFiredBarTime), HTF filter +
     daily limit dicek di titik ini (kalau gagal, tidak entry; confirmation-mode
     di bar close tetap jadi fallback normal)
  2. oldIdm = g_idmPrice (level yang disweep — disimpan sebelum trend berubah)
  3. ReverseToDowntrend/Uptrend(rates[1])  ← rates[1] = bar CLOSED terakhir,
     BUKAN bar yang sedang forming. Origin + retroactive structure 100% dari
     data final, g_trend & g_idmPrice langsung pindah ke trend baru.
  4. TP = GetLastSHDPrice/GetLastSLUPrice (structural, sama formula seperti
     confirmation entry) — cek valid + InpMinTpPoints (equilibrium filter TIDAK
     dicek di sini, karena "close" belum ada — entry price = bar.low/high proxy
     itu sendiri, jadi filter itu tidak bermakna di titik ini)
  5. SL = entry ∓ (tpDistance / InpRR)  (RR=0 → no SL, sama seperti confirmation)
  6. OpenTrade(isBuy, entry, sl, tp) — SL/TP REAL langsung terpasang di order
  7. AddEntry(ticket, sweepPrice=oldIdm, dir) — masuk tracking normal

Begitu bar yang tadi "disentuh" itu BENERAN close (flow OnTick standar, tidak ada
kode khusus tambahan):
  - UpdateStructure() → bar itu diproses sebagai bar pertama trend baru (structure
    sudah di-reverse duluan di step 3), pakai fungsi yang sama seperti bar manapun.
  - CheckEntryInvalidation() → entry yang barusan dibuka dicek otomatis:
      close TIDAK reclaim oldIdm → body break → InpInvalidationMode diterapkan
        (di atas SL/TP yang SUDAH ada, bukan set awal) → entry di-remove dari tracking
      close reclaim oldIdm → bukan body break → sweepPrice di-refine ke bar.low/high
        (Phase 2, existing logic) → lanjut tracking normal seperti entry biasa
  - CheckIdmTaken() → cek idm BARU (trend baru), hampir selalu belum taken di bar
    yang sama → no-op, tidak ada reverse dobel.
```

**Beda vs confirmation entry:** aggressive entry mengorbankan filter "no body break" (entry di setiap sentuhan idm, bukan cuma yang confirmed reclaim) demi harga entry lebih awal + reverse structure lebih cepat. Trade-off: lebih banyak entry yang berakhir body-break (invalidasi di bar yang sama), dan TP/lot bisa sedikit beda dari yang akan dihitung confirmation-mode di bar yang sama — karena retroactive rebuild-nya tidak menyertakan bar yang lagi forming itu sendiri (biasanya nggak masalah, karena bar itu dicirikan oleh ekstrem tipe berlawanan dari yang menentukan TP — kecuali kasus outside-bar yang jarang terjadi). Equilibrium filter (`InpUseEquilibriumFilter`) tidak diterapkan ke aggressive entry (secara struktural belum bisa dievaluasi di titik touch).

## Equilibrium Filter (opsional)

Filter premium/discount ala ICT: skip entry kalau close candle sweep sudah lewat titik tengah (equilibrium) dari range sweep-level → TP. Diaktifkan via `InpUseEquilibriumFilter` (default false).

```
BUY:  range = [sweepLow (bar.low candle idm-taken), tp]
      equilibrium = (sweepLow + tp) / 2
      close > equilibrium → SKIP (sudah premium, room ke TP relatif terlalu sedikit)

SELL: range = [tp, sweepHigh (bar.high candle idm-taken)]
      equilibrium = (tp + sweepHigh) / 2
      close < equilibrium → SKIP (sudah discount, room ke TP relatif terlalu sedikit)
```

Dicek di `CheckIdmTaken` (AjipIDM_Entry.mqh), sejajar dengan Min TP Points filter — setelah TP tervalidasi (`tp > 0.0`), sebelum `OpenTrade`. Filter ini independen dari HTF filter dan daily limit (semua filter dicek berurutan, entry hanya jalan kalau semua lolos).

## Contoh Full Cycle (Chained Example)

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
