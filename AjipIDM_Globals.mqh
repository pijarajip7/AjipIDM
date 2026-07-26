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

// Entry invalidation tracking (multi-position, per-ticket)
struct EntryTracker
  {
   ulong    ticket;         // position ticket
   double   sweepPrice;     // sweep level (bar high/low that took idm)
   int      dir;            // 1=BUY, -1=SELL
   double   entryPrice;     // POSITION_PRICE_OPEN at the time of AddEntry
   datetime entryTime;      // POSITION_TIME at the time of AddEntry
   double   mfe;            // Max Favorable Excursion — best POSITION_PROFIT seen ($)
   double   mae;            // Max Adverse Excursion — worst POSITION_PROFIT seen ($)
  };
EntryTracker  g_entries[];

// Bar tracking
datetime       g_lastBarTime = 0;  // for new-bar detection within OnTick

// HTF context — structure/idm tracking only (never trades, never draws)
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

// Symbol info cache
int            g_digits;
double         g_point;
double         g_tickValue;
double         g_tickSize;
double         g_volMin, g_volMax, g_volStep;

#endif // AJIPIDM_GLOBALS_MQH
