#ifndef AJIPIDM_GLOBALS_MQH
#define AJIPIDM_GLOBALS_MQH

// ENUMS & STRUCTS
//==================================================================
enum ENUM_TREND
  {
   TREND_NONE  = 0,
   TREND_UP    = 1,
   TREND_DOWN  = -1
  };

// Daily target/max-loss status — classified from realized+floating P/L
// (see ClassifyDailyStatus, AjipIDM_Trade.mqh). Shared by CheckDailyCloseAll
// (AjipIDM_Entry.mqh) and the info panel (AjipIDM_Panel.mqh).
enum ENUM_DAILY_STATUS
  {
   DAILY_STATUS_DISABLED,     // InpDailyMaxProfit and InpDailyMaxLoss both <= 0
   DAILY_STATUS_ACTIVE,       // enabled, neither threshold reached yet
   DAILY_STATUS_TARGET_HIT,   // InpDailyMaxProfit reached
   DAILY_STATUS_MAXLOSS_HIT   // InpDailyMaxLoss reached
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
string         g_objPrefix   = "AjipIDM_";
string         g_panelPrefix = "AjipIDMPanel_"; // distinct from g_objPrefix — DrawSwings() wipes everything under g_objPrefix on every redraw
string         g_htfObjPrefix = "AjipIDMHtf_";   // HTF swing/idm lines — also distinct, same reason

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

// Aggressive entry — bar time of the currently-forming bar for which an
// aggressive touch entry already fired. Guards against re-firing multiple
// times within the same forming bar; naturally "resets" once a new bar
// starts forming (its rates[0].time differs), no manual reset needed.
datetime       g_aggressiveFiredBarTime = 0;

// Entry tracking (multi-position, per-ticket) — bookkeeping for MFE/MAE,
// partial-close state, and CSV logging. No SL/TP and no per-ticket
// invalidation in this variant — positions live until partial-close and/or
// the daily target/loss close-all (see AjipIDM_Trade.mqh/AjipIDM_Entry.mqh).
struct EntryTracker
  {
   ulong    ticket;         // position ticket
   int      dir;            // 1=BUY, -1=SELL
   double   entryPrice;     // POSITION_PRICE_OPEN at the time of AddEntry
   datetime entryTime;      // POSITION_TIME at the time of AddEntry
   double   mfe;            // Max Favorable Excursion — best POSITION_PROFIT seen ($)
   double   mae;            // Max Adverse Excursion — worst POSITION_PROFIT seen ($)
   bool     partialClosed;  // true once the one-time partial close has fired
  };
EntryTracker  g_entries[];

// Batch report accumulator — one CSV row per "setup" (every position closed
// since the last flush), written once CloseAllPositions empties tracking
// (daily target/max loss/session-end). Positions closed earlier in the
// batch (e.g. breakeven stop after partial close) fold their stats in here
// silently — nothing is written to disk until the whole batch is done. See
// AccumulateBatchStats/WriteBatchCsv/ResetBatchAccumulator (AjipIDM_Trade.mqh)
// and CheckEntryCleanup (AjipIDM_Entry.mqh).
bool           g_batchActive         = false; // true once this batch's first entry has opened
datetime       g_batchFirstEntryTime = 0;
datetime       g_batchLastEntryTime  = 0;
int            g_batchCount          = 0;     // positions accounted for so far
int            g_batchWins           = 0;
int            g_batchLosses         = 0;
int            g_batchBreakEven      = 0;
double         g_batchRealizedPnl    = 0.0;
double         g_batchMfeSum         = 0.0;
double         g_batchMaeSum         = 0.0;
bool           g_batchFlushPending   = false; // set true right before a CloseAllPositions() call
string         g_batchCloseReason    = "";    // DAILY_TARGET / DAILY_MAX_LOSS / SESSION_END

// Bar tracking
datetime       g_lastBarTime = 0;  // for new-bar detection within OnTick

// HTF context — structure/idm engine, always active (drives the equilibrium
// filter for every entry; see AjipIDM_HtfContext.mqh).
ENUM_TREND     g_htfTrend          = TREND_NONE;
Swing          g_htfSwings[];
ENUM_PHASE     g_htfPhase;
BaseCandle     g_htfBase;
Swing          g_htfPbSwings[];
bool           g_htfOutsidePending = false;
BaseCandle     g_htfOutsideBar;
double         g_htfIdmPrice       = 0.0;
bool           g_htfIdmTaken       = false;
datetime       g_htfLastBarTime    = 0;

// Trading session — parsed once in OnInit from InpSessionStart/InpSessionEnd
// (server time HH:MM). g_sessionFilterEnabled=false means unrestricted
// (start==end or unparseable input) — InSession() always returns true then.
int            g_sessionStartMin      = 0;    // minutes since midnight
int            g_sessionEndMin        = 0;    // minutes since midnight
bool           g_sessionFilterEnabled = false;

// Symbol info cache
int            g_digits;
double         g_point;
double         g_volMin, g_volMax, g_volStep;

#endif // AJIPIDM_GLOBALS_MQH
