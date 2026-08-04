//+------------------------------------------------------------------+
//|                                                    AjipIDM.mq5   |
//|  Inducement-centric SMC strategy for MT5.                        |
//|  Simple structure (SL/SH) WITHOUT VH/VL.                         |
//|  Entry decision = LTF idm taken + no body break → fade the sweep,|
//|  gated by HTF equilibrium (discount/premium). Fixed lot, no      |
//|  SL/TP at entry — one-time partial close at InpPartialClosePoints|
//|  moves SL to breakeven on the rest, which then rides until daily |
//|  target/max loss closes ALL positions.                           |
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
input group "Strategy / Structure"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M1;   // Working timeframe
input ENUM_TIMEFRAMES InpHtfTimeframe    = PERIOD_M15;  // Higher timeframe — drives equilibrium filter for every entry
input bool             InpUseAggressiveEntry = true;    // Enter at idm level intrabar (before bar close); reverses structure early
input int              InpCandlesInit       = 50;       // Lookback candles for initial trend

input group "Entry & Trade Sizing"
input double InpFixedLot    = 0.02;   // Fixed lot size per entry (no SL/TP in this variant)
input int    InpMinTpPoints = 1000;   // Min HTF reference distance in points (setup-quality filter, skip if below)
input ulong  InpDeviation   = 10;     // Slippage (points)
input long   InpMagicNumber = 99001;  // Magic number

input group "Risk Management — Final Target"
input double InpFinalProfitTarget = 0.0;  // Overall (non-daily) profit target — once reached, close ALL positions and stop new trades PERMANENTLY (0=disabled)
input double InpStartingBalance   = 0.0;  // Baseline InpFinalProfitTarget is measured from (0 = auto-capture current balance on first run, then persisted)

input group "Risk Management — Daily"
input double InpDailyMaxProfit = 60.0;   // Daily target — close ALL positions + stop new trades for the REST OF THE DAY (0=disabled)
input double InpDailyMaxLoss   = 280.0;  // Daily max loss — close ALL positions + stop new trades for the REST OF THE DAY (0=disabled)

input group "Risk Management — Batch"
input double InpBatchMaxProfit       = 20.0;  // Batch target — close current batch only, new entries still allowed right after (0=disabled)
input double InpBatchMaxLoss         = 0.0;   // Batch max loss — close current batch only, new entries still allowed right after (0=disabled)
input int    InpBatchCooldownMinutes = 11;     // Minutes to wait after a batch goes flat before a new one can start (0=disabled, next entry allowed immediately)

input group "Partial Close"
input int    InpPartialClosePoints  = 500;   // Points profit to trigger one-time partial close (0=disabled)
input double InpPartialClosePercent = 50.0;  // % of position volume to close at partial-close threshold

input group "Session Filter"
input string InpSessionStart = "02:00";  // Session start (server time HH:MM) — entries only inside session; start==end disables filter
input string InpSessionEnd   = "20:00";  // Session end (server time HH:MM) — outside session: no new entries; if PnL > 0, close ALL positions

input group "News Filter"
input bool                           InpNewsFilterEnabled = true;                   // Block new entries around high-impact calendar news for this symbol's currencies
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum event importance to block on
input int                            InpNewsMinutesBefore = 30;                      // Minutes before a matching event to start blocking new entries
input int                            InpNewsMinutesAfter  = 30;                      // Minutes after a matching event to keep blocking new entries

input group "Chart Display"
input bool             InpDrawLines   = true;                // Draw structure lines on chart
input int              InpMaxLines    = 500;                 // Max trendline objects (cleanup)
input bool             InpShowPanel   = true;                // Show info panel (trend + P/L)
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;    // Panel corner
input int              InpPanelX      = 20;                  // Panel X offset (px)
input int              InpPanelY      = 50;                  // Panel Y offset (px)

input group "Diagnostics"
input bool InpEnableLog = true;  // Print diagnostic/debug messages to the Experts log

input group "Multi-Account Orchestrator"
input bool   InpHandoffEnabled = false;                   // Write a handoff signal file when daily target/max-loss is hit (for an external multi-account rotation orchestrator)
input string InpHandoffFile    = "AjipIDM_Handoff.csv";   // Filename written to the terminal's shared Common\Files folder (FILE_COMMON)
input string InpHeartbeatFile  = "AjipIDM_Heartbeat.csv"; // "I'm alive on THIS account" file, written every ~30s while InpHandoffEnabled — lets the orchestrator detect an account with no EA attached

//--- AjipIDM module includes (order matters: globals first, then deps) ---
#include "AjipIDM_Globals.mqh"
#include "AjipIDM_Pullback.mqh"
#include "AjipIDM_Structure.mqh"
#include "AjipIDM_Reversal.mqh"
#include "AjipIDM_Entry.mqh"
#include "AjipIDM_Trade.mqh"
#include "AjipIDM_News.mqh"
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
   g_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(g_volStep <= 0.0) g_volStep = g_volMin;

   // Session filter — parse once. start==end or unparseable → disabled
   // (InSession() always true, no restriction, no forced close-all).
   int  startMin = 0, endMin = 0;
   bool sessionParsedOk = ParseHHMM(InpSessionStart, startMin) && ParseHHMM(InpSessionEnd, endMin);
   if(!sessionParsedOk)
      if(InpEnableLog) PrintFormat("AjipIDM: Invalid InpSessionStart/InpSessionEnd (%s/%s) — session filter disabled.",
                  InpSessionStart, InpSessionEnd);

   g_sessionStartMin      = startMin;
   g_sessionEndMin        = endMin;
   g_sessionFilterEnabled = sessionParsedOk && (startMin != endMin);

   CaptureStartingBalance(); // baseline for InpFinalProfitTarget — no-op if disabled

   // Build initial structure from lookback candles
   if(!InitStructure())
     {
      if(InpEnableLog) Print("AjipIDM: InitStructure failed — will retry on first tick");
      // Not fatal; OnTick will attempt rebuild
     }

   // Build initial HTF context — always active, drives the equilibrium filter.
   if(!InitHtfStructure())
      if(InpEnableLog) Print("AjipIDM: InitHtfStructure failed — will retry on first tick");

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
   // Heartbeat — self-throttled (HEARTBEAT_INTERVAL_SECONDS), safe to call
   // every tick. Only orchestrator.py reads this; a no-op if
   // InpHandoffEnabled=false (standalone single-account run).
   WriteHeartbeat();

   // MFE/MAE — update every tick (not gated by new-bar) so intra-bar
   // excursions are captured, not just the closed-bar extreme.
   UpdateMfeMae();

   // Per-position one-time partial close + portfolio-level final/batch/
   // daily/session close-all — all react to floating P/L, so all run every
   // tick, not gated by new-bar. Final target first (most significant —
   // permanent, not just for today); batch next (most granular, doesn't
   // block entries); daily/session after (broader, daily blocks entries
   // for the rest of the day, session blocks until back in-session).
   CheckPartialClose();
   CheckFinalTargetCloseAll();
   CheckBatchCloseAll();
   CheckDailyCloseAll();
   CheckSessionCloseAll();

   // HTF context — always active, own new-bar gate, runs every tick since
   // HTF bars close less often than LTF bars (must not be gated behind the
   // LTF early-return below, or an HTF closed-bar boundary could be
   // silently skipped). Drives the equilibrium filter (HtfEntryAllowed) for
   // every entry.
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

   // Zone entry (aggressive) + aggressive reversal — own per-tick checks, run
   // every tick (not gated behind the new-bar early-return below). Zone entry
   // checked FIRST: g_idmZonePrice sits closer to price than the full
   // g_idmPrice sweep, so it's reached first as price retraces toward it —
   // entry is fully decoupled from reversal, see AjipIDM_Entry.mqh.
   CheckAggressiveZoneEntry();
   CheckAggressiveIdmTouch();

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

   // 2. Cleanup: log + untrack any position that closed (partial close
   //    doesn't remove it — only a full close, via daily/session close-all)
   CheckEntryCleanup();

   // 3. Zone entry + idm taken (reversal) on the just-closed bar — entry
   //    checked first, same reasoning as the aggressive/tick path above.
   CheckIdmZoneEntry(rates[1]);
   CheckIdmTaken(rates[1]);

   // 4. Refresh info panel (trend + P/L)
   UpdatePanel();
  }

