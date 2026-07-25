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
input double          InpTargetAmount = 500.0;      // Target profit per trade (USD)
input int             InpCandlesInit = 50;          // Lookback candles for initial trend
input ulong           InpDeviation   = 10;          // Slippage (points)
input long            InpMagicNumber = 99001;       // Magic number
input bool            InpDrawLines   = true;        // Draw structure lines on chart
input int             InpMaxLines    = 500;         // Max trendline objects (cleanup)
input double          InpRR          = 0.0;         // Risk:Reward (1=1:1, 2=1:2, 0=NO SL)
input int             InpMinTpPoints = 300;           // Min TP distance in points (skip if below)
input double          InpDailyMaxProfit = 0.0;      // Daily max profit (0=disabled, stop new trades when reached)
input double          InpDailyMaxLoss   = 0.0;      // Daily max loss (0=disabled, stop new trades when reached)

//--- AjipIDM module includes (order matters: globals first, then deps) ---
#include "AjipIDM_Globals.mqh"
#include "AjipIDM_Pullback.mqh"
#include "AjipIDM_Structure.mqh"
#include "AjipIDM_Reversal.mqh"
#include "AjipIDM_Entry.mqh"
#include "AjipIDM_Trade.mqh"
#include "AjipIDM_Core.mqh"

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

