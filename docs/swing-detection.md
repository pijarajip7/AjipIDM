# AjipIDM — Swing Detection: 2-Stage Algorithm

## Stage 1: Pullback (base_candle tracking)

Reference: `perception-alignment.md` Stage 1.

Menggunakan satu running reference candle (`base_candle`):

| Phase | Reference | Trigger switch | Hasil |
|-------|-----------|---------------|-------|
| UP | base_up (highest-high candle) | Bar low < base_up.low → pullback_down | Record HI = base_up.high. Switch DOWN. |
| UP | base_up | Bar high > base_up.high → continuation up | Bar jadi base_up baru |
| DOWN | base_down (lowest-low candle) | Bar high > base_down.high → pullback_up | Record LO = base_down.low. Switch UP. |
| DOWN | base_down | Bar low < base_down.low → continuation down | Bar jadi base_down baru |

Aturan:
- Comparison STRICT (`>` / `<`), bukan `>=` / `<=`
- Tidak ada minimum swing deviation
- Pakai full candle high/low (termasuk wick)
- HI dan LO tidak pernah di bar yang sama
- Output: alternating HI → LO → HI → LO → ...

Catatan: Outside bar ditangani via pending resolution (lihat bagian di bawah).

## Outside Bar Handling (pending resolution)

Outside bar = bar yang break BOTH base.high AND base.low. Implementasi di `DetectPullback`:

1. Simpan outside bar sebagai `g_outsideBar`, set `g_outsidePending = true`
2. Jangan record swing dulu — tunggu bar berikutnya resolve:
   - **PHASE_UP:**
     - Next breaks outside.high → continuation UP, commit outside.low sebagai SL
     - Next breaks outside.low → reversal DOWN, commit outside.high sebagai SH
   - **PHASE_DOWN:**
     - Next breaks outside.low → continuation DOWN, commit outside.high sebagai SH
     - Next breaks outside.high → reversal UP, commit outside.low sebagai SL
3. Outside bar bisa extend jika bar berikutnya lebih extreme sebelum resolve
4. Reset di InitStructure, ReverseToDowntrend, ReverseToUptrend

## Stage 2: Simple Structure (filter dengan trend rules)

Reference: `perception-alignment.md` Stage 2.2.

Dari pullback swings, commit ke simple structure hanya jika memenuhi trend rules:

**Filter approach (bukan merge):**
1. Origin = first pullback swing → always committed
2. Setiap pullback swing berikutnya:
   - Must be opposite type to last committed (alternation)
   - Must satisfy trend rule vs last committed of same type
3. Kalau violate trend rule → SKIP swing tersebut

**Premature update handling:**
Jika pullback swing baru same type dengan last committed dan lebih extreme:
- SH baru lebih tinggi dari SH lama → POP swing lama, commit yang baru
- SL baru lebih rendah dari SL lama → POP swing lama, commit yang baru
- Setelah pop, backtrack lastIdx ke swing terakhir yang tersisa

**Trend rules:**
- Uptrend: SH must be HH, SL must be HL
- Downtrend: SH must be LH, SL must be LL

**Contoh (downtrend):**
```
Pullback: SH(origin) → SL(4132) → SH(4138.92) → SL(4132.92) → SH(4137.17)

Filter:
1. SH(origin) → committed
2. SL(4132) → first SL → committed
3. SH(4138.92) → LH vs origin → committed
4. SL(4132.92) → LL check: 4132.92 < 4132? TIDAK → SKIP
5. SH(4137.17) → same type as last committed (4138.92) → SKIP

Hasil: [SH(origin), SL(4132), SH(4138.92)]
```
