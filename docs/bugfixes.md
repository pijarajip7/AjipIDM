# AjipIDM — Bug Fixes History

### Round 1: Basic structure
1. New-bar detection — avoid reprocessing same bar every tick
2. Typo `highest = highest` di InitStructure
3. CheckIdmTaken logic rewrite — clean doEntry/entryBuy flags

### Round 2: Running var init
4. ReverseToDowntrend/Up: running vars init dari origin bar OHLC
5. Running max/min init: DBL_MAX/-DBL_MAX (prevent first-bar contamination)
6. RebuildStructure: skip origin bar + correct CopyRates start_pos
7. InitStructure: exclude current forming bar + correct g_lastBarTime

### Round 3: SL/SH same bar rule
8. UpdateUptrend/Down: check commit condition FIRST, commit SL from previous bar only
9. Reset tracking vars to sentinel after commit (not bar values)

### Round 4: Pullback detection (major rewrite)
10. Implementasi base_candle tracking dari perception-alignment.md
11. Pisahkan Stage 1 (pullback) dan Stage 2 (simple structure)
12. AddPbSwing/ResetPbSwings untuk pullback swing array terpisah

### Round 5: Trend rules enforcement
13. Filter approach: commit pullback swing hanya jika satisfy trend rules
14. Alternation enforcement: skip same-type swing jika last committed belum opposite
15. Origin protection: first swing always committed

### Round 6: RebuildStructure live replay
28. RebuildStructure: process reversal events (idm taken) selama replay, bukan pullback-only. Sebelumnya replay hanya DetectPullback per bar + BuildSimpleStructure di akhir — reversal di tengah range origin→takenBar hilang. Fix: replay loop sekarang panggil DetectPullback + BuildSimpleStructure + UpdateIdm + CheckIdmTaken per bar (sama dengan InitStructure pattern). g_initMode disave/restore untuk suppress entry selama replay. Reversal kedua di tengah range sekarang terdeteksi → trend/idm benar untuk bar selanjutnya.

### Round 7: Multiple mid-replay reverses
29. g_idmTaken reset BEFORE RebuildStructure (bukan setelah). Bug: `g_idmTaken=true` di-set saat live idm taken, lalu ReverseToDowntrend/Up call RebuildStructure. Tapi `CheckIdmTaken` baris pertama `if(g_idmTaken) return;` — langsung exit. Mid-replay reverse (down→up→down) tidak pernah fire. Struktur/idm berhenti di reverse pertama. Fix: pindah `g_idmTaken=false` ke sebelum `RebuildStructure` di kedua fungsi reverse. Sekarang chained reverse di tengah replay terdeteksi → idm level dari reverse TERAKHIR (correct), bukan pertama.

### Round 8: Stale index pointer in premature-pop (array out of range)
30. `BuildSimpleStructure` array out of range (line 72,50) saat backtest. Root cause: saat premature-pop, `PopSwingAt` shift elemen array ke kiri, yang membatalkan posisi index untuk KEDUA tipe swing (SH dan SL). Tapi code lama hanya recompute pointer tipe yang di-pop (misal pop SH → cuma cari SH baru), pointer tipe lawan (lastSLIdx) dibiarkan stale. Di iterasi berikutnya, `g_swings[lastSLIdx]` diakses dengan index lama yang >= ArraySize → crash. Fix: setelah PopSwingAt, recompute KETIGA pointer (lastSHIdx, lastSLIdx, lastIdx) sekaligus dalam satu backward scan. Terverifikasi via 20,000-trial fuzz: OLD code 1114 crashes, NEW code 0 crashes.

### Round 9: idm staleness — trend tidak berubah saat idm taken (uptrend)
31. `UpdateIdm()` tidak pernah dipanggil di live path (`UpdateStructure` di Core.mqh). Hanya dipanggil di `InitStructure` dan `RebuildStructure`. Akibatnya `g_idmPrice` frozen sejak init/reversal terakhir. Fix: tambah `UpdateIdm()` ke `UpdateStructure()` setelah `BuildSimpleStructure`.
32. (REVERTED) Awalnya UpdateIdm diubah walk dari n-1 (include dangling last swing) supaya HL/LH terbaru jadi idm. Tapi ini terlalu agresif: SLU yang baru terbentuk (kandidat unconfirmed) langsung jadi idm → price pullback normal (di bawah SLU kandidat) memicu false idm taken → reversal prematur. Revert ke n-2 (exclude dangling). Spec tetap: idm = SL/SH terakhir yang sudah CONFIRMED (punya swing lawan setelahnya). Root cause bug asli (#31) sudah teratasi dengan UpdateIdm di live path.

### Round 10: Origin reversal pakai committed swing, bukan actual extreme bar
33. `ReverseToDowntrend` origin = last committed SHU di g_swings. `ReverseToUptrend` origin = last committed SLD. Tapi pada fast reversal (down→up dalam range pendek), extreme bar belum ter-commit jadi swing → origin pakai swing lama yang bukan extreme sebenarnya. Contoh: uptrend reverse down, lowest bar belum jadi SLD → origin uptrend baru = SLD sebelumnya (lebih tinggi), bukan lowest bar. Fix: scan actual bar data (CopyRates) dari leg start (g_pbSwings[0].time) sampai taken bar untuk cari TRUE highest high (downtrend) / lowest low (uptrend). Fallback ke committed swing jika bar scan gagal.

### Round 11: Batch tidak pernah di-flush kalau semua posisi tutup organik
34. Kalau SEMUA posisi tracked tutup sendiri (mis. kena breakeven stop) tanpa batch/daily/session close-all pernah jalan, `CheckEntryCleanup` melipat tiap posisi ke accumulator tapi TIDAK PERNAH menulis baris CSV atau reset — batch itu diam-diam tetap terbuka, lalu bercampur dengan entry berikutnya sampai ada threshold $ yang kebetulan memicu flush. Fix: logika write-CSV-if-done dipisah dari `CloseAllAndFlushBatch` jadi `FlushBatchIfDone`, sekarang juga dipanggil dari `CheckEntryCleanup` tepat setelah `g_entries` kosong.

### Round 12: Entry nyala dari dangling origin-as-idm tepat setelah reversal
35. Tepat setelah `ReverseToUptrend`/`ReverseToDowntrend`, fallback `n==1` di `UpdateIdm` memperlakukan origin trend baru sebagai "idm" untuk keperluan bookkeeping struktur — padahal origin itu ekstrem dari leg trend LAMA (origin uptrend = lowest low dari downtrend), bukan swing terkonfirmasi dari trend baru. `CheckIdmZoneEntry`/`CheckAggressiveZoneEntry` cuma mengecek `g_idmZonePrice > 0`, jadi langsung entry dari level sisa itu — paling parah di V-reversal cepat yang belum punya bar untuk membangun struktur pasca-reversal. Fix: tambah `g_idmConfirmed`, true hanya setelah `UpdateIdm` menemukan swing yang benar-benar terkonfirmasi (punya swing tipe lawan setelahnya), dan gate kedua jalur entry dengannya. Deteksi reversal saat itu sengaja tidak disentuh — re-sweep origin masih sinyal reversal yang sah, cuma bukan pemicu entry yang sah.

### Round 13: Batch CSV tertukar antar-akun + dashboard baca folder salah
36. Nama file `WriteBatchCsv` cuma dikunci symbol+magic, sementara file-nya ada di folder Files milik terminal (bukan Common). Di setup rotasi multi-akun, satu terminal login ke akun berbeda-beda lewat `mt5.login()` — folder fisiknya sama terus — jadi setiap akun yang trading symbol+magic sama menimpa CSV yang sama, batch tercampur tanpa cara membedakan pemiliknya. Fix: nama file jadi `AjipIDM_Batches_<symbol>_<magic>_<login>.csv`.
37. `write_live_status` mengeset `files_dir` ke `common_files_dir()` (Common\Files, scope FILE_COMMON) — benar untuk handoff & heartbeat, tapi `WriteBatchCsv` sengaja TIDAK pakai FILE_COMMON, jadi batch CSV per-akun sebenarnya ada di `MQL5\Files` milik terminal. `find_batch_csv` di dashboard.py men-glob direktori yang salah, tidak menemukan apa pun, lalu diam-diam fallback ke DataFrame kosong — semua kolom PnL/win-rate/trade-count menampilkan 0 tanpa error yang menjelaskan kenapa. Fix: tambah `terminal_files_dir()` (`info.data_path + MQL5/Files`) di samping `common_files_dir()` yang sudah ada, dan arahkan `files_dir` ke yang benar.

### Round 14: Posisi yatim setelah restart + partial close mati permanen
38. `g_entries` hanya diisi lewat `AddEntry` saat `OpenTrade` baru — recompile, reattach manual, atau restart terminal saat posisi terbuka membuat posisi itu yatim: tidak kena partial-close, tidak dilindungi aggregate SL, tidak dihitung `InpMaxTotalLots`, dan hasilnya hilang dari batch CSV walaupun `CloseAllAndFlushBatch` tetap menutupnya (fungsi itu memindai posisi broker mentah, bukan `g_entries`). Fix: `RebuildTrackedPositions` di `OnInit` memindai ulang posisi terbuka untuk symbol+magic ini dan mengisi ulang `g_entries`. Posisi dari batch terputus yang sudah tutup sebelum restart tetap tidak bisa dipulihkan — tidak ada catatan trade mana milik batch mana.
39. `CheckPartialClose` mengeset `partialClosed=true` SEBELUM mencoba `PositionClosePartial`, jadi penolakan broker apa pun (requote, trade context busy, gangguan koneksi sesaat) mematikan partial-close untuk ticket itu SELAMANYA — ia jalan tanpa pernah displit sampai ada close-all yang mengambil semuanya. Fix: flag baru diset setelah split BERHASIL (atau langsung untuk kasus "volume terlalu kecil untuk displit", yang memang permanen dan tidak berubah kalau diulang). Sekalian dibuang: heuristik SL-proximity yang dipakai `RebuildTrackedPositions` untuk menebak `partialClosed` saat restart — budget `RecalculateAggregateSL` yang ketat bisa kebetulan menaruh SL posisi baru dekat entry price juga, jadi tebakan itu bisa salah menandai posisi yang belum pernah partial-close dan melewatkannya selamanya. Selalu menyemai `false` adalah arah salah yang aman: konsekuensi terburuknya cuma satu percobaan partial-close berlebih pada sisa yang sudah di BE, dan itu tidak berbahaya.

### Round 15: Reversal agresif nyala dari idm yang belum terkonfirmasi
40. `CheckAggressiveIdmTouch` tidak mengecek `g_idmConfirmed` (Round 12 hanya memasangnya di jalur ENTRY). Akibatnya, tepat setelah sebuah reversal, trend baru yang baru punya satu swing dangling bisa dibalik LAGI oleh satu wick tunggal yang menyentuh origin itu — flip-flop reversal beruntun tanpa struktur nyata di belakangnya. Terlihat di log sebagai `Reversed to UP ... swings=1` yang 110ms kemudian langsung disusul `AGGRESSIVE BUY idm touch` → `Reversed to DOWN ... swings=0`. Fix: syaratkan `g_idmConfirmed` di `CheckAggressiveIdmTouch` juga, menyamakan dengan gate yang sudah dipunyai `CheckAggressiveZoneEntry`. Origin yang masih dangling tetap bisa "taken" lewat jalur bar-close `CheckIdmTaken` yang menunggu bar close — hanya jalur per-tick yang dibatasi.
41. Logging reversal diperkaya supaya kejadian seperti ini bisa didiagnosis dari log saja: `CheckAggressiveIdmTouch` sekarang mencetak Bid + OHLC penuh bar closed terakhir DAN bar yang sedang terbentuk; `ReverseToDowntrend`/`ReverseToUptrend` mencetak window scan (`legStart`→`takenBar`) + OHLC bar taken.
