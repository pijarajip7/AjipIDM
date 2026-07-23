//+------------------------------------------------------------------+
//|                                                    AjipIDM.mq5   |
//|  Inducement-centric SMC strategy for MT5.                        |
//|  Simple structure (SL/SH) WITHOUT VH/VL.                         |
//|  Entry = idm taken + no body break → fade with RR 1:1.           |
//|  Running-max swing detection from 50 candles init.               |
//+------------------------------------------------------------------+
#property copyright   "AjipSMC"
#property link        ""
#property version     "1.00"
#property strict
#property description "AjipIDM — Inducement-based SMC EA"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_M15;  // Working timeframe
input double          InpTargetAmount = 100.0;      // Target profit per trade (USD)
input int             InpCandlesInit = 50;          // Lookback candles for initial trend
input ulong           InpDeviation   = 10;          // Slippage (points)
input long            InpMagicNumber = 99001;       // Magic number
input bool            InpDrawLines   = true;        // Draw structure lines on chart
input int             InpMaxLines    = 500;         // Max trendline objects (cleanup)
input double          InpRR          = 1.0;         // Risk:Reward (1=1:1, 2=1:2, 0=NO SL)
input int             InpMinTpPoints = 0;           // Min TP distance in points (skip if below)

//==================================================================
// ENUMS & STRUCTS
//==================================================================
enum ENUM_TREND
  {
   TREND_NONE  = 0,
   TREND_UP    = 1,
   TREND_DOWN  = -1
  };

// A committed swing point in simple structure
struct Swing
  {
   double   price;       // swing price (high for SH, low for SL)
   datetime time;        // bar time of the swing
   bool     isHigh;      // true = SH, false = SL
  };

//--- Pullback (Stage 1): base candle tracking ---
struct BaseCandle
  {
   double   high;
   double   low;
   datetime time;
   bool     valid;
  };

enum ENUM_PHASE
  {
   PHASE_UP,    // looking for swing HIGH (price pushing up)
   PHASE_DOWN   // looking for swing LOW (price pushing down)
  };

//==================================================================
// GLOBALS
//==================================================================
CTrade         trade;
string         g_objPrefix = "AjipIDM_";

// Active structure tracking
ENUM_TREND     g_trend          = TREND_NONE;
Swing          g_swings[];         // committed swings for current trend

// Phase-based pullback detection
ENUM_PHASE     g_phase;            // current pullback phase
BaseCandle     g_base;             // base candle for pullback tracking
Swing          g_pbSwings[];      // pullback swings (Stage 1 output)
bool           g_initMode = false; // true during init (skip entry on idm taken)

// Outside bar pending state — bar yang break both extremes, belum resolved
bool           g_outsidePending = false;
BaseCandle     g_outsideBar;       // the outside bar (both extremes)

// idm tracking
double         g_idmPrice = 0.0;   // current idm level
bool           g_idmTaken = false; // idm has been taken this cycle

// Entry invalidation tracking (multi-position, per-ticket)
struct EntryTracker
  {
   ulong    ticket;         // position ticket
   double   sweepPrice;     // sweep level (bar high/low that took idm)
   int      dir;            // 1=BUY, -1=SELL
  };
EntryTracker  g_entries[];

// Bar tracking
datetime       g_lastBarTime = 0;  // for new-bar detection within OnTick

// Symbol info cache
int            g_digits;
double         g_point;
double         g_tickValue;
double         g_tickSize;
double         g_volMin, g_volMax, g_volStep;

//==================================================================
// INIT
//==================================================================
int OnInit()
  {
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetExpertMagicNumber(InpMagicNumber);

   // Cache symbol info
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(g_volStep <= 0.0) g_volStep = g_volMin;

   // Build initial structure from lookback candles
   if(!InitStructure())
     {
      Print("AjipIDM: InitStructure failed — will retry on first tick");
      // Not fatal; OnTick will attempt rebuild
     }

   ChartRedraw();
   return(INIT_SUCCEEDED);
  }

//==================================================================
// DEINIT — cleanup chart objects
//==================================================================
void OnDeinit(const int reason)
  {
   CleanupAllObjects();
  }

//==================================================================
// ONTICK
//==================================================================
void OnTick()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpTimeframe, 0, 3, rates);
   if(copied < 3) return;

   // Per-tick: detect NEW BAR, process the just-closed bar.
   // Structure + idm taken both evaluate on CLOSED bars (entry = close price).
   // This avoids repaint from intra-bar high/low changes.
   datetime closedBarTime = rates[1].time;

   if(closedBarTime == g_lastBarTime)
      return; // same closed bar already processed — wait for new bar

   g_lastBarTime = closedBarTime;

   // 1. Update structure with the newly closed bar
   UpdateStructure(rates[1]);
   if(InpDrawLines) DrawSwings();

   // 2. Invalidate open position if body-break sweep level
   CheckEntryInvalidation(rates[1]);

   // 3. Check idm taken on the just-closed bar
   CheckIdmTaken(rates[1]);
  }

//==================================================================
// INIT STRUCTURE — build from lookback candles
//==================================================================
bool InitStructure()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false); // oldest → newest (chronological)
   int copied = CopyRates(_Symbol, InpTimeframe, 0, InpCandlesInit, rates);
   if(copied < 10)
     {
      PrintFormat("AjipIDM: Not enough bars for init (%d)", copied);
      return(false);
     }

   // Find highest high and lowest low
   int highIdx = 0, lowIdx = 0;
   double highest = rates[0].high;
   double lowest  = rates[0].low;

   for(int i = 1; i < copied; i++)
     {
      if(rates[i].high > highest)
        {
         highest = rates[i].high;
         highIdx = i;
        }
      if(rates[i].low < lowest)
        {
         lowest = rates[i].low;
         lowIdx = i;
        }
     }

   // Determine trend by chronological order
   int originIdx;
   if(highIdx < lowIdx)
     {
      // High occurred BEFORE low → downtrend
      g_trend = TREND_DOWN;
      originIdx = highIdx;
      PrintFormat("AjipIDM: Init DOWN. HH@%s (%.5f), LL@%s (%.5f)",
                  TimeToString(rates[highIdx].time), highest,
                  TimeToString(rates[lowIdx].time), lowest);
     }
   else
     {
      // Low occurred BEFORE high → uptrend
      g_trend = TREND_UP;
      originIdx = lowIdx;
      PrintFormat("AjipIDM: Init UP. LL@%s (%.5f), HH@%s (%.5f)",
                  TimeToString(rates[lowIdx].time), lowest,
                  TimeToString(rates[highIdx].time), highest);
     }

   // Init pullback from origin bar
   g_initMode = true; // skip entry during historical replay
   ResetSwings();
   ResetPbSwings();

   if(g_trend == TREND_DOWN)
     {
      // Downtrend origin = highest high
      AddPbSwing(highest, rates[originIdx].time, true);
     }
   else
     {
      // Uptrend origin = lowest low
      AddPbSwing(lowest, rates[originIdx].time, false);
     }
   g_base.high  = rates[originIdx].high;
   g_base.low   = rates[originIdx].low;
   g_base.time  = rates[originIdx].time;
   g_base.valid = true;
   g_phase      = (g_trend == TREND_DOWN) ? PHASE_DOWN : PHASE_UP;
   g_outsidePending = false;

   // Build forward from origin, processing each bar:
   // pullback detect → build structure → update idm → check reversal
   for(int i = originIdx + 1; i < copied - 1; i++)
     {
      DetectPullback(rates[i]);
      BuildSimpleStructure();
      UpdateIdm();
      if(g_idmPrice > 0.0)
         CheckIdmTaken(rates[i]);
     }

   // Final structure + idm
   BuildSimpleStructure();
   UpdateIdm();
   g_idmTaken = false;
   g_initMode = false; // back to live mode

   // Last CLOSED bar = rates[copied-2] (rates[copied-1] is the forming bar)
   g_lastBarTime = rates[copied - 2].time;

   PrintFormat("AjipIDM: Structure built. Trend=%s, Swings=%d, idm=%.5f",
               TrendString(g_trend), ArraySize(g_swings), g_idmPrice);

   if(InpDrawLines) DrawSwings();

   return(true);
  }

//==================================================================
// UPDATE STRUCTURE — 2-stage: pullback detection + simple structure build
//
// Stage 1 (PULLBACK): base_candle tracking with outside bar handling.
//   UP phase: base = highest-high candle. Bar low < base.low → pullback DOWN,
//             record HI = base.high. Bar high > base.high → continuation.
//   DOWN phase: base = lowest-low candle. Bar high > base.high → pullback UP,
//             record LO = base.low. Bar low < base.low → continuation.
//
// Stage 2 (SIMPLE STRUCTURE): running max/min from pullback swings + merge.
//   Uptrend:   SH must be HH, SL must be HL.
//   Downtrend: SH must be LH, SL must be LL.
//==================================================================
void UpdateStructure(MqlRates &bar)
  {
   //--- Stage 1: Pullback detection ---
   DetectPullback(bar);

   //--- Stage 2: Build simple structure from pullback swings ---
   BuildSimpleStructure();
  }

//==================================================================
// DETECT PULLBACK — base_candle zigzag (Stage 1)
//
// Normal mode:
//   PHASE_UP: continuation (higher high) or pullback (low breaks base low)
//   PHASE_DOWN: continuation (lower low) or pullback (high breaks base high)
//
// Outside bar mode (bar breaks BOTH base.high AND base.low):
//   - Store as g_outsideBar, set g_outsidePending = true
//   - Don't record swing yet — wait for next bar to resolve:
//     PHASE_UP:
//       next breaks outside.high → continuation UP, commit outside.low as SL
//       next breaks outside.low  → reversal DOWN, commit outside.high as SH
//     PHASE_DOWN:
//       next breaks outside.low  → continuation DOWN, commit outside.high as SH
//       next breaks outside.high → reversal UP, commit outside.low as SL
//==================================================================
void DetectPullback(MqlRates &bar)
  {
   if(!g_base.valid)
     {
      // First bar: init base
      g_base.high  = bar.high;
      g_base.low   = bar.low;
      g_base.time  = bar.time;
      g_base.valid = true;
      return;
     }

   //--- Outside bar pending resolution ---
   if(g_outsidePending)
     {
      if(g_phase == PHASE_UP)
        {
         if(bar.high > g_outsideBar.high)
           {
            // Continuation UP: commit outside.low as SL, resolving bar = new base
            AddPbSwing(g_outsideBar.low, g_outsideBar.time, false);
            g_outsidePending = false;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else if(bar.low < g_outsideBar.low)
           {
            // Reversal DOWN: commit outside.high as SH
            AddPbSwing(g_outsideBar.high, g_outsideBar.time, true);
            g_outsidePending = false;
            g_phase = PHASE_DOWN;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else
           {
            // Neither extreme broken yet → keep waiting
            // Update outside bar if new bar extends it
            if(bar.high > g_outsideBar.high || bar.low < g_outsideBar.low)
              {
               g_outsideBar.high = MathMax(g_outsideBar.high, bar.high);
               g_outsideBar.low  = MathMin(g_outsideBar.low,  bar.low);
               g_outsideBar.time = bar.time;
              }
           }
        }
      else // PHASE_DOWN
        {
         if(bar.low < g_outsideBar.low)
           {
            // Continuation DOWN: commit outside.high as SH
            AddPbSwing(g_outsideBar.high, g_outsideBar.time, true);
            g_outsidePending = false;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else if(bar.high > g_outsideBar.high)
           {
            // Reversal UP: commit outside.low as SL
            AddPbSwing(g_outsideBar.low, g_outsideBar.time, false);
            g_outsidePending = false;
            g_phase = PHASE_UP;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else
           {
            // Neither extreme broken yet → keep waiting
            if(bar.high > g_outsideBar.high || bar.low < g_outsideBar.low)
              {
               g_outsideBar.high = MathMax(g_outsideBar.high, bar.high);
               g_outsideBar.low  = MathMin(g_outsideBar.low,  bar.low);
               g_outsideBar.time = bar.time;
              }
           }
        }
      return;
     }

   //--- Check for outside bar (breaks BOTH extremes) ---
   bool isOutside = (bar.high > g_base.high && bar.low < g_base.low);

   if(isOutside)
     {
      g_outsidePending = true;
      g_outsideBar.high  = bar.high;
      g_outsideBar.low   = bar.low;
      g_outsideBar.time  = bar.time;
      g_outsideBar.valid = true;
      PrintFormat("AjipIDM: Outside bar detected. Phase=%s high=%.5f low=%.5f — pending resolution",
                  g_phase == PHASE_UP ? "UP" : "DOWN", bar.high, bar.low);
      return;
     }

   //--- Normal pullback detection (no outside bar) ---
   if(g_phase == PHASE_UP)
     {
      // Continuation: bar makes higher high → becomes new base
      if(bar.high > g_base.high)
        {
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
      // Pullback DOWN: bar low breaks base low → record HI, switch phase
      else if(bar.low < g_base.low)
        {
         AddPbSwing(g_base.high, g_base.time, true);
         g_phase = PHASE_DOWN;
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
     }
   else // PHASE_DOWN
     {
      // Continuation: bar makes lower low → becomes new base
      if(bar.low < g_base.low)
        {
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
      // Pullback UP: bar high breaks base high → record LO, switch phase
      else if(bar.high > g_base.high)
        {
         AddPbSwing(g_base.low, g_base.time, false);
         g_phase = PHASE_UP;
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
     }
  }

//==================================================================
// BUILD SIMPLE STRUCTURE — running max/min from pullback swings + merge
//==================================================================
void BuildSimpleStructure()
  {
   int npb = ArraySize(g_pbSwings);

   // Rebuild g_swings from scratch
   ResetSwings();

   if(npb == 0) return;

   // Origin = first pullback swing (always committed)
   AddSwing(g_pbSwings[0].price, g_pbSwings[0].time, g_pbSwings[0].isHigh);
   // Track last committed index per type + last committed overall
   int lastSHIdx = -1;
   int lastSLIdx = -1;
   int lastIdx   = -1;

   if(g_pbSwings[0].isHigh) { lastSHIdx = 0; }
   else                     { lastSLIdx = 0; }
   lastIdx = 0;

   // Commit each pullback swing independently if trend rule satisfied
   for(int i = 1; i < npb; i++)
     {
      double price = g_pbSwings[i].price;
      datetime tm  = g_pbSwings[i].time;
      bool isHigh  = g_pbSwings[i].isHigh;

      // If same type as last committed → might be premature update
      if(isHigh == g_swings[lastIdx].isHigh)
        {
         // Premature: new price is more extreme than last same-type
         // SH: higher = old was premature local high
         // SL: lower  = old was premature local low
         bool premature = isHigh
            ? (price > g_swings[lastSHIdx].price)
            : (price < g_swings[lastSLIdx].price);
         if(premature)
           {
            if(isHigh)
              {
               PopSwingAt(lastSHIdx);
               lastSHIdx = -1;
               int ns = ArraySize(g_swings);
               for(int j = ns - 1; j >= 0; j--)
                  if(g_swings[j].isHigh) { lastSHIdx = j; break; }
               lastIdx = lastSHIdx;
              }
            else
              {
               PopSwingAt(lastSLIdx);
               lastSLIdx = -1;
               int ns = ArraySize(g_swings);
               for(int j = ns - 1; j >= 0; j--)
                  if(!g_swings[j].isHigh) { lastSLIdx = j; break; }
               lastIdx = lastSLIdx;
              }
            // Fall through to normal commit below
           }
         else continue; // not premature, skip
        }

      if(g_trend == TREND_UP)
        {
         if(isHigh)
           {
            // SHU: commit if first SH or HH
            if(lastSHIdx < 0 || price > g_swings[lastSHIdx].price)
              {
               AddSwing(price, tm, true);
               lastSHIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSHIdx;
              }
           }
         else
           {
            // SLU: commit if first SL or HL
            if(lastSLIdx < 0 || price > g_swings[lastSLIdx].price)
              {
               AddSwing(price, tm, false);
               lastSLIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSLIdx;
              }
           }
        }
      else // TREND_DOWN
        {
         if(isHigh)
           {
            // SHD: commit if first SH or LH
            if(lastSHIdx < 0 || price < g_swings[lastSHIdx].price)
              {
               AddSwing(price, tm, true);
               lastSHIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSHIdx;
              }
           }
         else
           {
            // SLD: commit if first SL or LL
            if(lastSLIdx < 0 || price < g_swings[lastSLIdx].price)
              {
               AddSwing(price, tm, false);
               lastSLIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSLIdx;
              }
           }
        }
     }

   UpdateIdm();
  }

//==================================================================
// PULLBACK SWING ARRAY HELPERS
//==================================================================
void AddPbSwing(double price, datetime time, bool isHigh)
  {
   int n = ArraySize(g_pbSwings);
   ArrayResize(g_pbSwings, n + 1);
   g_pbSwings[n].price  = price;
   g_pbSwings[n].time   = time;
   g_pbSwings[n].isHigh = isHigh;
  }

void ResetPbSwings()
  {
   ArrayResize(g_pbSwings, 0);
  }

//==================================================================
// POP SWING AT INDEX (for g_swings)
//==================================================================
void PopSwingAt(int idx)
  {
   int n = ArraySize(g_swings);
   if(idx < 0 || idx >= n) return;

   for(int i = idx; i < n - 1; i++)
      g_swings[i] = g_swings[i + 1];
   ArrayResize(g_swings, n - 1);
  }

//==================================================================
// UPDATE IDM — set idm to last swing that HAS an opposite swing after it
// Uptrend:   idm = last SL that has a SH after it (not the dangling last SL)
// Downtrend: idm = last SH that has a SL after it (not the dangling last SH)
//==================================================================
void UpdateIdm()
  {
   int n = ArraySize(g_swings);
   if(n < 1)
     {
      g_idmPrice = 0.0;
      return;
     }
   if(n == 1)
     {
      // Origin is always the initial idm
      g_idmPrice = g_swings[0].price;
      return;
     }

   if(g_trend == TREND_UP)
     {
      // Walk backwards: find last SL that has a SH after it
      for(int i = n - 2; i >= 0; i--) // start at n-2 (second to last)
        {
         if(!g_swings[i].isHigh) // this is an SL
           {
            // Check there's a SH after it
            g_idmPrice = g_swings[i].price;
            return;
           }
        }
     }
   else if(g_trend == TREND_DOWN)
     {
      // Walk backwards: find last SH that has a SL after it
      for(int i = n - 2; i >= 0; i--)
        {
         if(g_swings[i].isHigh) // this is a SH
           {
            g_idmPrice = g_swings[i].price;
            return;
           }
        }
     }

   g_idmPrice = 0.0;
  }

//==================================================================
// CHECK ENTRY INVALIDATION (multi-position)
// For each tracked entry:
//   Phase 1: Body break check (close menembus sweep level) → TP to BE
//   Phase 2: If not body break, update sweep level if deeper
// Auto-cleanup: remove entries whose position no longer exists.
//==================================================================
void CheckEntryInvalidation(MqlRates &bar)
  {
   int n = ArraySize(g_entries);
   if(n == 0) return;

   for(int i = n - 1; i >= 0; i--)
     {
      ulong ticket = g_entries[i].ticket;

      // Check if position still exists
      if(!PositionSelectByTicket(ticket))
        {
         // Position closed (TP/SL hit) — remove from tracking
         RemoveEntry(i);
         continue;
        }

      double sweepPrice = g_entries[i].sweepPrice;
      int    dir        = g_entries[i].dir;

      //--- Phase 1: Body break check FIRST ---
      bool bodyBreak = false;
      if(dir == 1 && bar.close < sweepPrice)
         bodyBreak = true;
      else if(dir == -1 && bar.close > sweepPrice)
         bodyBreak = true;

      if(bodyBreak)
        {
         PrintFormat("AjipIDM: BODY BREAK. Ticket=%I64u Dir=%s, sweep=%.5f, close=%.5f — TP to BE",
                     ticket, dir == 1 ? "BUY" : "SELL", sweepPrice, bar.close);

         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentTP  = PositionGetDouble(POSITION_TP);
         double sl         = PositionGetDouble(POSITION_SL);

         // Only modify if TP is not already at BE
         if(MathAbs(currentTP - entryPrice) >= g_point)
           {
            if(trade.PositionModify(ticket, sl, entryPrice))
               PrintFormat("AjipIDM: TP modified to BE (%.5f) for ticket %I64u", entryPrice, ticket);
            else
               PrintFormat("AjipIDM: Failed to modify TP for %I64u. retcode=%d (%s)",
                           ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
           }

         // Remove from tracking (invalidated, don't re-check)
         RemoveEntry(i);
         continue;
        }

      //--- Phase 2: Sweep update (only if NOT body break) ---
      if(dir == 1)  // BUY
        {
         if(bar.low < sweepPrice)
           {
            g_entries[i].sweepPrice = bar.low;
            PrintFormat("AjipIDM: Sweep update (BUY) ticket=%I64u. New level=%.5f", ticket, bar.low);
           }
        }
      else if(dir == -1)  // SELL
        {
         if(bar.high > sweepPrice)
           {
            g_entries[i].sweepPrice = bar.high;
            PrintFormat("AjipIDM: Sweep update (SELL) ticket=%I64u. New level=%.5f", ticket, bar.high);
           }
        }
     }
  }

//==================================================================
// ADD ENTRY to tracking
//==================================================================
void AddEntry(ulong ticket, double sweepPrice, int dir)
  {
   int n = ArraySize(g_entries);
   ArrayResize(g_entries, n + 1);
   g_entries[n].ticket      = ticket;
   g_entries[n].sweepPrice  = sweepPrice;
   g_entries[n].dir         = dir;
  }

//==================================================================
// REMOVE ENTRY at index
//==================================================================
void RemoveEntry(int idx)
  {
   int n = ArraySize(g_entries);
   if(idx < 0 || idx >= n) return;

   for(int i = idx; i < n - 1; i++)
      g_entries[i] = g_entries[i + 1];
   ArrayResize(g_entries, n - 1);
  }

//==================================================================
// CHECK IDM TAKEN
// Uptrend: candle low < idm(SLU_last) → idm taken
// Downtrend: candle high > idm(SHD_last) → idm taken
//==================================================================
void CheckIdmTaken(MqlRates &bar)
  {
   if(g_idmTaken) return;
   if(g_idmPrice <= 0.0) return;
   // Multi-position: no HasOpenPosition() check

   bool taken    = false;
   bool doEntry  = false;
   bool entryBuy = false;

   if(g_trend == TREND_UP)
     {
      // idm = last SLU. Taken when low penetrates below it.
      if(bar.low < g_idmPrice)
        {
         taken = true;
         if(bar.close > g_idmPrice)
           {
            // No body break → BUY (fade the sweep)
            doEntry  = true;
            entryBuy = true;
           }
        }
     }
   else if(g_trend == TREND_DOWN)
     {
      // idm = last SHD. Taken when high penetrates above it.
      if(bar.high > g_idmPrice)
        {
         taken = true;
         if(bar.close < g_idmPrice)
           {
            // No body break → SELL (fade the sweep)
            doEntry  = true;
            entryBuy = false;
           }
        }
     }

   if(!taken) return;

   g_idmTaken = true;

   PrintFormat("AjipIDM: IDM TAKEN. Trend was %s, idm=%.5f, bar close=%.5f",
               TrendString(g_trend), g_idmPrice, bar.close);

   if(g_trend == TREND_UP)
     {
      // Trend changes to DOWN. Build downtrend from last SHU (= SHD0).
      ReverseToDowntrend(bar);

      if(doEntry && entryBuy && !g_initMode)
        {
         // BUY: TP = last SHD in new downtrend structure
         double tp = GetLastSHDPrice();
         if(tp > 0.0 && bar.close < tp)
           {
            double tpDistance = tp - bar.close;
            // RR=0 → no SL
            double sl = 0.0;
            if(InpRR > 0.0)
              {
               double slDistance = tpDistance / InpRR;
               sl = bar.close - slDistance;
              }

            // Min TP points filter
            double tpPoints = tpDistance / g_point;
            if(InpMinTpPoints > 0 && tpPoints < InpMinTpPoints)
              {
               PrintFormat("AjipIDM: BUY skip — TP points %.0f < %d (tp=%.5f, close=%.5f)",
                           tpPoints, InpMinTpPoints, tp, bar.close);
              }
            else
              {
               ulong ticket = OpenTrade(true, bar.close, sl, tp);
               if(ticket > 0)
                  AddEntry(ticket, bar.low, 1); // BUY, sweep = bar low
              }
           }
         else
            PrintFormat("AjipIDM: BUY skip — TP invalid (tp=%.5f, close=%.5f)", tp, bar.close);
        }
      // Else: body break or init mode → no entry, continue downtrend
     }
   else if(g_trend == TREND_DOWN)
     {
      // Trend changes to UP. Build uptrend from last SLD (= SLU0).
      ReverseToUptrend(bar);

      if(doEntry && !entryBuy && !g_initMode)
        {
         // SELL: TP = last SLU in new uptrend structure
         double tp = GetLastSLUPrice();
         if(tp > 0.0 && bar.close > tp)
           {
            double tpDistance = bar.close - tp;
            // RR=0 → no SL
            double sl = 0.0;
            if(InpRR > 0.0)
              {
               double slDistance = tpDistance / InpRR;
               sl = bar.close + slDistance;
              }

            // Min TP points filter
            double tpPoints = tpDistance / g_point;
            if(InpMinTpPoints > 0 && tpPoints < InpMinTpPoints)
              {
               PrintFormat("AjipIDM: SELL skip — TP points %.0f < %d (tp=%.5f, close=%.5f)",
                           tpPoints, InpMinTpPoints, tp, bar.close);
              }
            else
              {
               ulong ticket = OpenTrade(false, bar.close, sl, tp);
               if(ticket > 0)
                  AddEntry(ticket, bar.high, -1); // SELL, sweep = bar high
              }
           }
         else
            PrintFormat("AjipIDM: SELL skip — TP invalid (tp=%.5f, close=%.5f)", tp, bar.close);
        }
      // Else: body break → no entry, continue uptrend
     }
  }

//==================================================================
// REVERSE TO DOWNTREND
// idm taken from uptrend. New origin = last SHU.
//==================================================================
void ReverseToDowntrend(MqlRates &takenBar)
  {
   // Find last SHU
   double originPrice = 0.0;
   datetime originTime = 0;
   int n = ArraySize(g_swings);

   for(int i = n - 1; i >= 0; i--)
     {
      if(g_swings[i].isHigh)
        {
         originPrice = g_swings[i].price;
         originTime  = g_swings[i].time;
         break;
        }
     }

   if(originPrice <= 0.0)
     {
      Print("AjipIDM: ReverseToDowntrend — no SHU origin found!");
      return;
     }

   // Switch trend
   g_trend = TREND_DOWN;

   // Reset structure: SHD0 = last SHU
   ResetSwings();
   ResetPbSwings();
   AddPbSwing(originPrice, originTime, true);

   // Init pullback: after SH origin, price goes DOWN
   g_phase = PHASE_DOWN;

   // Init g_base from origin bar OHLC directly (don't replay origin)
   MqlRates orgBar[];
   ArraySetAsSeries(orgBar, true);
   if(CopyRates(_Symbol, InpTimeframe, originTime, 1, orgBar) > 0)
     {
      g_base.high  = orgBar[0].high;
      g_base.low   = orgBar[0].low;
      g_base.time  = orgBar[0].time;
      g_base.valid = true;
     }
   g_outsidePending = false;

   // Rebuild from bars AFTER origin (origin+1 ... takenBar)
   RebuildStructure(originTime, takenBar.time);

   // Update idm for new trend
   UpdateIdm();
   g_idmTaken = false;

   PrintFormat("AjipIDM: Reversed to DOWN. Origin SHD0=%.5f@%s, swings=%d",
               originPrice, TimeToString(originTime), ArraySize(g_swings));

   if(InpDrawLines) DrawSwings();
  }

//==================================================================
// REVERSE TO UPTREND
// idm taken from downtrend. New origin = last SLD.
//==================================================================
void ReverseToUptrend(MqlRates &takenBar)
  {
   // Find last SLD
   double originPrice = 0.0;
   datetime originTime = 0;
   int n = ArraySize(g_swings);

   for(int i = n - 1; i >= 0; i--)
     {
      if(!g_swings[i].isHigh)
        {
         originPrice = g_swings[i].price;
         originTime  = g_swings[i].time;
         break;
        }
     }

   if(originPrice <= 0.0)
     {
      Print("AjipIDM: ReverseToUptrend — no SLD origin found!");
      return;
     }

   // Switch trend
   g_trend = TREND_UP;

   // Reset structure: SLU0 = last SLD
   ResetSwings();
   ResetPbSwings();
   AddPbSwing(originPrice, originTime, false);

   // Init pullback: after SL origin, price goes UP
   g_phase = PHASE_UP;

   // Init g_base from origin bar OHLC directly (don't replay origin)
   MqlRates orgBar[];
   ArraySetAsSeries(orgBar, true);
   if(CopyRates(_Symbol, InpTimeframe, originTime, 1, orgBar) > 0)
     {
      g_base.high  = orgBar[0].high;
      g_base.low   = orgBar[0].low;
      g_base.time  = orgBar[0].time;
      g_base.valid = true;
     }
   g_outsidePending = false;

   // Rebuild from bars AFTER origin
   RebuildStructure(originTime, takenBar.time);

   // Update idm for new trend
   UpdateIdm();
   g_idmTaken = false;

   PrintFormat("AjipIDM: Reversed to UP. Origin SLU0=%.5f@%s, swings=%d",
               originPrice, TimeToString(originTime), ArraySize(g_swings));

   if(InpDrawLines) DrawSwings();
  }

//==================================================================
// REBUILD STRUCTURE
// Fetch all bars between originTime and endTime, replay them.
//==================================================================
void RebuildStructure(datetime originTime, datetime endTime)
  {
   int originShift = iBarShift(_Symbol, InpTimeframe, originTime);
   int endShift    = iBarShift(_Symbol, InpTimeframe, endTime);

   if(originShift < 0 || endShift < 0 || originShift < endShift)
     {
      PrintFormat("AjipIDM: RebuildStructure bad shifts origin=%d end=%d",
                  originShift, endShift);
      return;
     }

   // originShift > endShift (series: 0=newest).
   // Fetch bars between origin (exclusive) and takenBar (inclusive).
   // Use start_pos=originShift (older), count bars forward toward newer.
   // CopyRates with ArraySetAsSeries(false): rates[0]=oldest, rates[last]=newest.
   // But we skip origin bar itself → start from originShift-1.
   int count = originShift - endShift; // bars from originShift-1 to endShift
   if(count <= 0) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, false); // chronological: oldest → newest
   int copied = CopyRates(_Symbol, InpTimeframe, endShift, count, rates);
   if(copied <= 0) return;

   // Verify we got the right bars: rates[0] should be oldest (near origin)
   // rates[copied-1] should be newest (= takenBar/endShift)

   // Feed each bar to DetectPullback only (NOT full UpdateStructure)
   // BuildSimpleStructure called once at end to avoid mid-replay state issues
   for(int i = 0; i < copied; i++)
     {
      DetectPullback(rates[i]);
     }

   // Build final structure from all pullback swings
   BuildSimpleStructure();

   // Debug
   int npb = ArraySize(g_pbSwings);
   int nsw = ArraySize(g_swings);
   PrintFormat("AjipIDM: RebuildStructure done. pbSwings=%d, swings=%d, bars_replayed=%d",
               npb, nsw, copied);
   for(int i = 0; i < npb; i++)
      PrintFormat("  pbSwing[%d]: price=%.5f time=%s isHigh=%s",
                  i, g_pbSwings[i].price, TimeToString(g_pbSwings[i].time),
                  g_pbSwings[i].isHigh ? "true" : "false");
   for(int i = 0; i < nsw; i++)
      PrintFormat("  swing[%d]: price=%.5f time=%s isHigh=%s",
                  i, g_swings[i].price, TimeToString(g_swings[i].time),
                  g_swings[i].isHigh ? "true" : "false");
  }

//==================================================================
// HELPER: Get last SHD price (for BUY TP)
//==================================================================
double GetLastSHDPrice()
  {
   int n = ArraySize(g_swings);
   for(int i = n - 1; i >= 0; i--)
     {
      if(g_swings[i].isHigh)
         return(g_swings[i].price);
     }
   return(0.0);
  }

//==================================================================
// HELPER: Get last SLU price (for SELL TP)
//==================================================================
double GetLastSLUPrice()
  {
   int n = ArraySize(g_swings);
   for(int i = n - 1; i >= 0; i--)
     {
      if(!g_swings[i].isHigh)
         return(g_swings[i].price);
     }
   return(0.0);
  }

//==================================================================
// OPEN TRADE — returns ticket (0 = failed)
//==================================================================
ulong OpenTrade(bool isBuy, double entry, double slRaw, double tpRaw)
  {
   // Normalize prices
   tpRaw = NormalizeDouble(tpRaw, g_digits);

   // SL=0 means no SL (InpRR=0)
   bool   hasSL = (slRaw > 0.0);
   double slNorm = 0.0;
   if(hasSL)
      slNorm = NormalizeDouble(slRaw, g_digits);

   // Validate TP direction
   if(isBuy && tpRaw <= entry)
     {
      PrintFormat("AjipIDM: BUY skip — TP %.5f <= entry %.5f", tpRaw, entry);
      return(0);
     }
   if(!isBuy && tpRaw >= entry)
     {
      PrintFormat("AjipIDM: SELL skip — TP %.5f >= entry %.5f", tpRaw, entry);
      return(0);
     }

   // Calculate lot size from target amount and TP distance
   double tpDistance = MathAbs(tpRaw - entry);
   if(tpDistance <= 0.0)
     {
      Print("AjipIDM: TP distance is zero — cannot calculate lot");
      return(0);
     }

   double lot = CalcLot(tpDistance);
   if(lot <= 0.0)
     {
      PrintFormat("AjipIDM: Lot calculation failed for tpDistance=%.5f", tpDistance);
      return(0);
     }

   // Get current price for market order
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return(0);

   bool ok;
   if(isBuy)
     {
      ok = trade.Buy(lot, _Symbol, tick.ask, slNorm, tpRaw, "AjipIDM BUY");
     }
   else
     {
      ok = trade.Sell(lot, _Symbol, tick.bid, slNorm, tpRaw, "AjipIDM SELL");
     }

   if(ok)
     {
      ulong ticket = trade.ResultOrder();
      PrintFormat("AjipIDM: %s opened. Ticket=%I64u, Lot=%.2f, Entry=%.5f, SL=%s, TP=%.5f",
                  isBuy ? "BUY" : "SELL", ticket, lot, entry,
                  hasSL ? DoubleToString(slNorm, g_digits) : "NONE", tpRaw);
      return(ticket);
     }

   PrintFormat("AjipIDM: Order failed. retcode=%d (%s)",
               trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return(0);
  }

//==================================================================
// CALC LOT — from target profit and TP distance
// gainPerLot = (tpDistance / tickSize) * tickValue
// lot = targetAmount / gainPerLot
//==================================================================
double CalcLot(double tpDistance)
  {
   if(g_tickSize <= 0.0 || g_tickValue <= 0.0) return(0.0);

   double gainPerLot = (tpDistance / g_tickSize) * g_tickValue;
   if(gainPerLot <= 0.0) return(0.0);

   double lot = InpTargetAmount / gainPerLot;

   // Normalize to volume step
   lot = MathFloor(lot / g_volStep) * g_volStep;
   if(lot < g_volMin) return(0.0);
   if(lot > g_volMax) lot = g_volMax;

   return(NormalizeDouble(lot, 8));
  }

//==================================================================
// SWING ARRAY HELPERS
//==================================================================
void ResetSwings()
  {
   ArrayResize(g_swings, 0);
  }

void AddSwing(double price, datetime time, bool isHigh)
  {
   int n = ArraySize(g_swings);
   ArrayResize(g_swings, n + 1);
   g_swings[n].price  = price;
   g_swings[n].time   = time;
   g_swings[n].isHigh = isHigh;
  }

string TrendString(ENUM_TREND t)
  {
   switch(t)
     {
      case TREND_UP:   return("UP");
      case TREND_DOWN: return("DOWN");
      default:         return("NONE");
     }
  }

//==================================================================
// CHART DRAWING
//==================================================================
void DrawSwings()
  {
   if(!InpDrawLines) return;

   // Cleanup ALL AjipIDM objects first (swing lines + idm line)
   ObjectsDeleteAll(0, g_objPrefix);

   int n = ArraySize(g_swings);
   if(n < 2) return;

   // Draw zigzag from origin to last swing
   for(int i = 0; i < n; i++)
     {
      string name = g_objPrefix + "SW_" + IntegerToString(i);
      datetime t1 = g_swings[i].time;
      double  p1  = g_swings[i].price;

      // Connect to next swing, or extend to current time for last swing
      datetime t2;
      double  p2;
      if(i < n - 1)
        {
         t2 = g_swings[i + 1].time;
         p2 = g_swings[i + 1].price;
        }
      else
        {
         // Last swing: extend to current bar time
         t2 = TimeCurrent();
         p2 = p1;
        }

      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_COLOR,
                       g_swings[i].isHigh ? clrDodgerBlue : clrOrangeRed);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
     }

   // Draw idm line (only if valid)
   if(g_idmPrice > 0.0)
     {
      string idmName = g_objPrefix + "IDM";
      ObjectCreate(0, idmName, OBJ_HLINE, 0, 0, g_idmPrice);
      ObjectSetInteger(0, idmName, OBJPROP_COLOR, clrBlack);
      ObjectSetInteger(0, idmName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, idmName, OBJPROP_STYLE, STYLE_DASH);
     }

   ChartRedraw();
  }

void CleanupAllObjects()
  {
   ObjectsDeleteAll(0, g_objPrefix);
  }

//+------------------------------------------------------------------+
