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

### Session 15 (2026-07-26): Equilibrium (premium/discount) filter
- Fitur baru: `InpUseEquilibriumFilter` (default false) — skip entry kalau close candle idm-taken sudah lewat midpoint (equilibrium) dari range sweep-level → TP.
- BUY: equilibrium = (sweepLow + tp) / 2, skip jika `close > equilibrium`. SELL: equilibrium = (tp + sweepHigh) / 2, skip jika `close < equilibrium`.
- Ditempatkan di `CheckIdmTaken` (AjipIDM_Entry.mqh), sejajar dengan Min TP Points filter — dicek setelah TP tervalidasi, sebelum `OpenTrade`.
- `InpUseEquilibriumFilter=false` (default) → zero behavior change dari sebelumnya.

### Session 16 (2026-07-26): MFE/MAE tracking (CSV export + live panel)
- `EntryTracker` (Globals.mqh) ditambah field: `entryPrice`, `entryTime`, `mfe`, `mae`. Diisi di `AddEntry` (entryPrice/entryTime dari `POSITION_PRICE_OPEN`/`POSITION_TIME` sesaat setelah `OpenTrade` sukses — actual fill, bukan `bar.close`).
- `UpdateMfeMae()` (AjipIDM_Entry.mqh) dipanggil TIAP TICK di `OnTick` (tidak digate per-bar) — untuk tiap tracked entry, `mfe = max(mfe, POSITION_PROFIT)`, `mae = min(mae, POSITION_PROFIT)`. Pakai floating profit MT5 langsung (bukan hitung manual dari price), otomatis benar untuk lot/symbol currency apa pun.
- `WriteTradeCsv()` (AjipIDM_Trade.mqh) dipanggil dari `CheckEntryInvalidation` pas posisi terdeteksi closed (SEBELUM `RemoveEntry`) — query exit info via `HistorySelectByPosition`, append row ke `MQL5/Files/AjipIDM_Trades_<symbol>_<magic>.csv` (header ditulis sekali kalau file belum ada).
- Panel: 2 baris baru "Open MFE"/"Open MAE" — sum floating mfe/mae semua tracked open positions, refresh sama cadence-nya dengan baris lain (per closed bar), tapi nilai underlying-nya sendiri sudah live per-tick.
- Body-break invalidation TIDAK memicu CSV write (posisi belum benar-benar closed) — hanya TP/SL/BE hit (posisi hilang dari broker) yang di-log.

### Session 17 (2026-07-27): HTF jadi sumber TP, equilibrium, dan invalidation
- Refactor besar: TP, equilibrium filter, dan invalidation semuanya direferensikan ke HTF, bukan lagi struktur LTF.

### Session 18 (2026-07-28): HTF alignment + anti double-entry + body-break filter
- Wajib HTF trend align sebelum menghitung TP/equilibrium entry — tanpa ini, referensi swing diambil dari range berbentuk salah (mis. BUY saat HTF DOWN memakai high yang lebih rendah sebagai referensi, membuat split equilibrium tidak bermakna dan nyaris selalu lolos).
- Cegah double entry antara aggressive touch dan confirmation close pada bar yang sama.
- Tambah filter HTF prev-swing body-break: swing sebelum referensi harus pernah ditembus BODY candle HTF, bukan sekadar disapu wick — kalau cuma swept, leg-nya lemah secara struktural dan entry dilewati.

### Session 19 (2026-07-29): Outside bar resolution
- Perbaiki resolusi outside bar yang menghilangkan pending swing, dan penanganan outside bar beruntun.

### Session 20 (2026-07-30): Varian fixed lot tanpa SL/TP
- Ganti total ke varian fixed lot: `OpenTrade` selalu SL=0 TP=0, exit lewat one-time partial close + daily close-all.
- Panel menampilkan status daily target/max-loss.
- SL pindah ke breakeven setelah partial close.

### Session 21 (2026-07-31): Session filter + batch report + batch limit
- Trading session filter (jam buka/tutup) + profit-lock di luar sesi.
- Report CSV per-setup (batch) menggantikan baris per-posisi.
- Batch-level target/max-loss dipisah dari daily limit — batch tidak memblokir entry baru.
- Tuning default input untuk eksperimen fixed-lot + partial-close.

### Session 22 (2026-08-01): Logging toggle + news filter
- `InpEnableLog` untuk mematikan seluruh Print/PrintFormat diagnostik.
- News blackout filter high-impact sebagai gate entry (tidak menutup posisi terbuka).

### Session 23 (2026-08-03): Entry decoupling + orchestrator multi-akun
- **Perubahan arsitektur besar:** entry dilepas total dari reversal struktural. `CheckIdmTaken`/`CheckAggressiveIdmTouch` sekarang murni reversal; entry pindah ke `CheckIdmZoneEntry`/`CheckAggressiveZoneEntry` yang dipicu `g_idmZonePrice` (extreme berlawanan dari bar idm) — boundary lebih longgar yang tersentuh lebih dulu saat retrace.
- Fix: batch di-flush begitu kosong, bukan hanya saat close-all (Round 11).
- Handoff signal multi-akun di EA + orchestrator Python.
- Fix: nama batch CSV menyertakan login akun (Round 13).
- Fix: `g_idmConfirmed` mencegah entry dari dangling origin-as-idm (Round 12).

### Session 24 (2026-08-04): Dashboard + grouping input + final target
- Dashboard monitoring multi-akun + launcher satu perintah.
- Deteksi akun yang tidak ada EA-nya (lewat heartbeat).
- Input EA dikelompokkan `input group`; tambah batch cooldown dan final profit target.
- Fix: dashboard membaca folder Files yang salah sehingga statistik batch selalu kosong (Round 13).

### Session 25 (2026-08-05): Aggregate SL, kill switch, dan pengerasan
- Kill switch max-loss level akun (`InpFinalMaxLoss`) + cap lot per arah (`InpMaxTotalLots`) + aggregate SL (budget max-loss terkecil dibagikan ke posisi yang belum punya stop, per arah dengan budget penuh masing-masing).
- Fix: `RebuildTrackedPositions` memulihkan tracking posisi setelah re-init (Round 14).
- Fix: partial close tidak lagi mematikan ticket permanen saat penolakan broker pertama (Round 14).
- Fix: reversal agresif mensyaratkan `g_idmConfirmed` — sumber flip-flop reversal yang sering terlihat di log (Round 15). Logging reversal diperkaya (Bid, OHLC bar closed & forming, window scan).
- Tambah `InpAllowHedging` — BUY/SELL tidak boleh bersamaan saat `false`, memblokir entry baru alih-alih menutup paksa sisi lawan. Untuk prop firm yang melarang hedging.
- Sinkronisasi dokumentasi menyeluruh: `concept.md` masih mendeskripsikan alur entry lama (pra-decoupling Session 23), `architecture.md` masih memuat daftar input lama; keduanya diperbarui bersama README, bugfixes (Round 11–15), dan sessions.
