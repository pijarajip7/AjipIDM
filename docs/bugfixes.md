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
