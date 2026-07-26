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
enum ENUM_INVALIDATION_MODE
  {
   INVALIDATION_DO_NOTHING, // Do nothing — leave TP/SL as is
   INVALIDATION_FIXED_TP    // Move TP to entry + fixed TP points
  };

input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_M1;  // Working timeframe
input double          InpTargetAmount = 1000.0;      // Target profit per trade (USD)
input double          InpRR          = 0.05;         // Risk:Reward (1=1:1, 2=1:2, 0=NO SL)
input int             InpMinTpPoints = 300;           // Min TP distance in points (skip if below)
input double          InpDailyMaxProfit = 10000.0;      // Daily max profit (0=disabled, stop new trades when reached)
input double          InpDailyMaxLoss   = 10000.0;      // Daily max loss (0=disabled, stop new trades when reached)
input ENUM_INVALIDATION_MODE InpInvalidationMode = INVALIDATION_FIXED_TP; // Invalidation TP action on body break
input int             InpInvalidationTpPoints = 50; // Fixed TP points (used when mode=FIXED_TP)
input bool             InpUseHtfFilter = false;      // Enable HTF trend filter on entries
input ENUM_TIMEFRAMES  InpHtfTimeframe = PERIOD_M5;  // Higher timeframe for trend filter
input bool             InpUseEquilibriumFilter = false; // Skip entry if close beyond equilibrium (sweep→TP midpoint)
input int             InpCandlesInit = 50;          // Lookback candles for initial trend
input ulong           InpDeviation   = 10;          // Slippage (points)
input long            InpMagicNumber = 99001;       // Magic number
input bool            InpDrawLines   = true;        // Draw structure lines on chart
input int             InpMaxLines    = 500;         // Max trendline objects (cleanup)
input bool             InpShowPanel   = true;             // Show info panel (trend + P/L)
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER; // Panel corner
input int              InpPanelX      = 10;               // Panel X offset (px)
input int              InpPanelY      = 20;               // Panel Y offset (px)

//--- AjipIDM module includes (order matters: globals first, then deps) ---
#include "AjipIDM_Globals.mqh"
#include "AjipIDM_Pullback.mqh"
#include "AjipIDM_Structure.mqh"
#include "AjipIDM_Reversal.mqh"
#include "AjipIDM_Entry.mqh"
#include "AjipIDM_Trade.mqh"
#include "AjipIDM_Core.mqh"
#include "AjipIDM_HtfContext.mqh"
#include "AjipIDM_Panel.mqh"

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

   // Build initial HTF context (structure/idm only, never trades)
   if(InpUseHtfFilter && !InitHtfStructure())
      Print("AjipIDM: InitHtfStructure failed — will retry on first tick");

   UpdatePanel();

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
   // MFE/MAE — update every tick (not gated by new-bar) so intra-bar
   // excursions are captured, not just the closed-bar extreme.
   UpdateMfeMae();

   // HTF context — own new-bar gate, runs every tick since HTF bars close
   // less often than LTF bars (must not be gated behind the LTF early-return
   // below, or an HTF closed-bar boundary could be silently skipped).
   if(InpUseHtfFilter)
     {
      MqlRates htfRates[];
      ArraySetAsSeries(htfRates, true);
      if(CopyRates(_Symbol, InpHtfTimeframe, 0, 3, htfRates) >= 3
         && htfRates[1].time != g_htfLastBarTime)
        {
         g_htfLastBarTime = htfRates[1].time;
         UpdateHtfStructure(htfRates[1]);
         DrawHtfSwings();
         if(g_htfIdmPrice > 0.0)
            HtfCheckIdmTaken(htfRates[1]);
        }
     }

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

   // 4. Refresh info panel (trend + P/L)
   UpdatePanel();
  }

