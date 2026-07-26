# AjipIDM — Session History

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

### Session 5 (2026-07-24): RebuildStructure live replay
- RebuildStructure: reversal di tengah range (idm taken) sekarang diproses, tidak di-skip
- Replay loop identik dengan InitStructure: DetectPullback + BuildSimpleStructure + UpdateIdm + CheckIdmTaken per bar
- g_initMode save/restore selama replay → entry suppressed, struktur tetap diproses
- Reversal kedua (chained) di tengah replay terdeteksi → trend/idm benar going forward

### Session 6 (2026-07-24): Multiple mid-replay reverses fix
- Bug: g_idmTaken=true saat live idm taken → CheckIdmTaken early-return di tengah RebuildStructure → mid-replay reverse hilang
- Fix: reset g_idmTaken=false SEBELUM RebuildStructure di ReverseToDowntrend & ReverseToUptrend
- Chained reverse (down→up→down) di tengah replay sekarang terdeteksi → idm level dari reverse TERAKHIR
- Modular split: code dipisah ke 7 file .mqh (Globals, Pullback, Structure, Reversal, Entry, Trade, Core)

### Session 7 (2026-07-25): Stale index pointer fix (array out of range)
- Bug: `array out of range in AjipIDM_Structure.mqh (72,50)` saat backtest di Strategy Tester
- Root cause: premature-pop di BuildSimpleStructure hanya recompute pointer tipe yang di-pop; pointer tipe lawan jadi stale setelah PopSwingAt shift elemen
- Fix: recompute ketiga pointer (lastSHIdx, lastSLIdx, lastIdx) sekaligus setelah pop
- Verifikasi: 20,000-trial fuzz (OLD 1114 crash, NEW 0 crash). Compile test di MetaEditor menunggu backtest ulang user.

### Session 8 (2026-07-25): idm staleness — trend tidak berubah saat idm taken
- Bug: uptrend idm taken tapi trend tidak berubah ke downtrend
- Root cause 1: `UpdateIdm()` tidak dipanggil di live path (`UpdateStructure`). `g_idmPrice` frozen sejak init/reversal. Fix: tambah `UpdateIdm()` ke `UpdateStructure()`.
- Root cause 2: `UpdateIdm()` skip dangling last swing (walk dari n-2). HL/LH terbaru = live inducement. Fix: walk dari n-1 (include dangling).
- Spec change: idm = SL/SH terakhir dari tipe inducement (tidak perlu swing lawan setelahnya).
- Verifikasi: simulation — OLD idm=105 (stale), NEW idm=108 (correct). Price 107 < 108 → reversal fires.

### Session 9 (2026-07-25): Revert idm n-1 + origin reversal scan actual bars
- Revert: UpdateIdm n-1 terlalu agresif (SLU unconfirmed langsung jadi idm → false reversal). Revert ke n-2. Root cause bug asli (#31 stale idm) tetap teratasi via UpdateIdm di live path.
- Bug: origin reversal pakai last committed swing. Fast reversal (down→up) → lowest bar belum commit jadi SLD → origin uptrend pakai SLD lama. Fix: scan CopyRates dari leg start ke taken bar, cari actual highest high (down) / lowest low (up). Fallback ke committed swing.

### Session 10 (2026-07-26): Invalidation mode dibuat opsional (do nothing / fixed TP)
- Sebelumnya body-break invalidation hardcoded modify TP ke break-even (entry price).
- Fix: tambah `ENUM_INVALIDATION_MODE` (`INVALIDATION_DO_NOTHING` default, `INVALIDATION_FIXED_TP`) + input `InpInvalidationTpPoints`.
- `INVALIDATION_DO_NOTHING`: TP/SL dibiarkan, tidak ada modify sama sekali.
- `INVALIDATION_FIXED_TP`: TP = entry ± `InpInvalidationTpPoints` (arah sesuai dir BUY/SELL). Set `InpInvalidationTpPoints=0` untuk setara behavior lama (TP to BE).

### Session 11 (2026-07-26): HTF trend filter
- Fitur baru: filter entry berdasarkan trend di timeframe lebih tinggi (`InpUseHtfFilter`, `InpHtfTimeframe`).
- Desain: bukan refactor engine LTF jadi class untuk dipakai 2x — engine LTF yang sudah battle-tested (10 round bug fix, lihat [bugfixes.md](bugfixes.md)) dibiarkan utuh, TIDAK disentuh. Sebagai gantinya, dibuat file baru `AjipIDM_HtfContext.mqh` berisi port 1:1 (trimmed) dari pipeline structure/idm, dengan prefix `Htf`/`g_htf`, khusus untuk HTF context.
- HTF engine: structure/idm tracking sama persis (pullback, simple structure, idm, reversal, replay) tapi TANPA entry placement, invalidation, daily-limit, atau chart drawing — karena HTF tidak pernah trading.
- Filter rule: BUY entry hanya jalan jika `g_htfTrend == TREND_UP`, SELL hanya jika `g_htfTrend == TREND_DOWN`. `TREND_NONE` (belum ke-init) otomatis blok keduanya.
- OnTick: HTF new-bar check jalan tiap tick, SEBELUM early-return gate LTF (karena HTF bar closed lebih jarang — kalau diletakkan setelah gate LTF, boundary HTF bisa ke-skip).
- `InpUseHtfFilter=false` (default) → zero behavior change dari sebelumnya (filter check short-circuit di awal kondisi).

### Session 12 (2026-07-26): On-chart info panel
- Fitur baru: dashboard on-chart (`AjipIDM_Panel.mqh`) — Trend, HTF Trend, Today/Week/Month P/L. Input `InpShowPanel`, `InpPanelCorner`, `InpPanelX`, `InpPanelY`.
- Refresh sekali per closed LTF bar (bukan `OnTimer`) — `OnTimer` tidak reliable di Strategy Tester, sedangkan `OnTick` per-bar cadence sudah dipakai konsisten di seluruh EA ini.
- P/L: realized deals only (symbol + magic), definisi sama dengan `GetDailyPnL` yang sudah dipakai daily-limit. Ditambah `GetPeriodPnL` (shared helper), `GetWeekPnL` (sejak Senin 00:00), `GetMonthPnL` (sejak tanggal 1 00:00) di `AjipIDM_Trade.mqh`.
- Object prefix panel (`g_panelPrefix = "AjipIDMPanel_"`) sengaja dibuat TIDAK diawali `g_objPrefix` ("AjipIDM_") — kalau sama, `DrawSwings()` yang jalan `ObjectsDeleteAll(0, g_objPrefix)` tiap redraw bakal ikut menghapus panel.

### Session 13 (2026-07-26): Draw HTF structure + idm di chart
- Fitur baru: `DrawHtfSwings()` di `AjipIDM_HtfContext.mqh` — gambar swing zigzag + idm line HTF, port dari `DrawSwings()` LTF, aktif jika `InpDrawLines && InpUseHtfFilter`.
- Object prefix baru `g_htfObjPrefix = "AjipIDMHtf_"` — terpisah dari `g_objPrefix` (LTF) dan `g_panelPrefix`, alasan sama: hindari saling ke-wipe oleh `ObjectsDeleteAll`.
- Visual dibedakan dari garis LTF: dotted style, width 2, warna ungu (SH)/emas (SL), idm line kuning dash-dot — supaya HTF vs LTF gampang dibedakan di chart yang sama.
- Dipanggil di `InitHtfStructure`, tiap kali `HtfReverseToDowntrend`/`HtfReverseToUptrend`, dan tiap HTF bar closed diproses di `OnTick` — mirror persis pola pemanggilan `DrawSwings()` di engine LTF.
- `CleanupAllObjects()` diupdate untuk juga hapus object HTF saat `OnDeinit`.

### Session 14 (2026-07-26): Split README jadi beberapa doc file
- README.md yang tadinya 1 file monolitik (~487 baris) dipecah jadi `docs/concept.md`, `docs/architecture.md`, `docs/swing-detection.md`, `docs/bugfixes.md`, `docs/sessions.md` (file ini).
- README.md sekarang jadi entry point ringkas: tagline, tabel link dokumentasi, Known Limitations & TODO, Files table.
