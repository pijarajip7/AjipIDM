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

// Target/max-loss status — classified from a total vs a (maxProfit, maxLoss)
// pair by the generic ClassifyLimitStatus (AjipIDM_Trade.mqh). Reused for
// BOTH the daily-scoped check (InpDailyMaxProfit/Loss, blocks new entries —
// CheckDailyCloseAll) and the batch-scoped check (InpBatchMaxProfit/Loss,
// does NOT block entries — CheckBatchCloseAll), plus the info panel
// (AjipIDM_Panel.mqh) for both.
enum ENUM_LIMIT_STATUS
  {
   LIMIT_STATUS_DISABLED,     // both maxProfit/maxLoss <= 0
   LIMIT_STATUS_ACTIVE,       // enabled, neither threshold reached yet
   LIMIT_STATUS_TARGET_HIT,   // maxProfit reached
   LIMIT_STATUS_MAXLOSS_HIT   // maxLoss reached
  };

// A committed swing point in simple structure
struct Swing
  {
   double   price;       // swing price (high for SH, low for SL)
   double   zonePrice;   // OPPOSITE extreme of the SAME bar (low for SH, high for SL) —
                          // looser entry-trigger boundary, see g_idmZonePrice below
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
double         g_idmPrice     = 0.0; // current idm level — gates structural reversal (CheckIdmTaken/CheckAggressiveIdmTouch)
double         g_idmZonePrice = 0.0; // opposite extreme of the idm bar — looser entry-trigger boundary (CheckIdmZoneEntry/CheckAggressiveZoneEntry)
datetime       g_idmTime      = 0;   // bar time g_idmPrice/g_idmZonePrice refer to — identifies "which idm level", used as the one-shot entry key (g_idmZoneEntryFiredTime)
bool           g_idmTaken = false; // idm has been taken this cycle
// True only when g_idmPrice/g_idmZonePrice come from an actual confirmed swing
// (a SL/SH that already has an opposite-type swing after it — see UpdateIdm).
// Right after a reversal there's only the origin swing (n==1): UpdateIdm still
// reports it as g_idmPrice for structural bookkeeping, but it has no opposite
// swing after it yet — it's the tail end of the OLD trend, not a confirmed
// idm for the NEW one. Entry (CheckIdmZoneEntry/CheckAggressiveZoneEntry) must
// wait for g_idmConfirmed before trading it; reversal detection (CheckIdmTaken)
// doesn't need to.
bool           g_idmConfirmed = false;

// One-shot entry guard — decoupled from reversal (g_idmTaken above). Once an
// entry fires (via CheckAggressiveZoneEntry or CheckIdmZoneEntry) for a given
// idm level, this is set to that level's g_idmTime so neither path fires
// again for the SAME level. A new idm level (new g_idmTime from UpdateIdm,
// whether from a fresh reversal or further structure) naturally re-arms it.
datetime       g_idmZoneEntryFiredTime = 0;

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
// since the last flush). Positions closed earlier in the batch (e.g.
// breakeven stop after partial close) fold their stats in here silently —
// nothing is written to disk until CloseAllAndFlushBatch (AjipIDM_Trade.mqh)
// closes/accounts for everything and flushes ATOMICALLY (close + accumulate
// + write + reset in one call, no next-bar delay) — called by
// CheckBatchCloseAll/CheckDailyCloseAll/CheckSessionCloseAll. Positions that
// close WITHOUT a close-all (e.g. breakeven stop) are folded in by
// CheckEntryCleanup (AjipIDM_Entry.mqh) but don't trigger a flush by
// themselves.
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

// Set the moment a batch actually flushes (FlushBatchIfDone, AjipIDM_Trade.mqh
// — only when g_batchCount > 0, i.e. a real batch just went flat), gates
// BatchCooldownActive() against InpBatchCooldownMinutes. Stays 0 until the
// first batch of the run finishes, so cooldown never blocks the very first
// entry.
datetime       g_lastBatchEndTime = 0;

// Bar tracking
datetime       g_lastBarTime = 0;  // for new-bar detection within OnTick

// Heartbeat — throttle for WriteHeartbeat (AjipIDM_Trade.mqh), called every
// tick but only actually writes once per HEARTBEAT_INTERVAL_SECONDS.
const int      HEARTBEAT_INTERVAL_SECONDS = 30;
datetime       g_lastHeartbeatTime = 0;

// Baseline InpFinalProfitTarget is measured from — resolved once in OnInit
// by CaptureStartingBalance (AjipIDM_Trade.mqh). Either InpStartingBalance
// directly, or auto-captured from the current balance and persisted via
// GlobalVariable so a later EA/terminal restart re-reads the SAME baseline
// instead of re-capturing (which would silently erase already-realized
// profit from the target calculation).
double         g_startingBalance = 0.0;

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

// Tick sanity guard — see RefreshTickSanity (AjipIDM_Trade.mqh), called once
// at the very top of OnTick before anything else reads price/PnL. A single
// corrupt/spiked tick (bad feed data — has happened on this EA's live demo
// account) can otherwise trigger CheckPartialClose or a close-all off a
// price/PnL reading that never really existed. Every per-tick consumer
// reads the sanitized g_saneBid/g_saneAsk/g_saneFloatingPnl below instead of
// raw SymbolInfoDouble/GetRawFloatingPnL, so one fix point protects all of
// them. Each quantity tracks: the last ACCEPTED reading (doubles as "this
// tick's serving value" — see SanitizeReading), a pending candidate while a
// jump is unconfirmed, a consecutive-rejection streak, and whether it's
// been initialized yet (0.0 is a legitimate PnL reading, so "unset" can't
// be inferred from the value alone the way it can for price).
// consecutive-hold counters + MAX_CONSECUTIVE_HOLDS: a hard ceiling on how
// long a held value may be served. Without it the guard can fossilize — its
// only way out of a hold is two CONSECUTIVE raw readings landing within
// maxJump of each other, so any symbol whose normal tick-to-tick movement
// exceeds maxJump (e.g. 3-digit XAUUSD, where the 3000-point default is only
// $3.00) never confirms, and lastSane freezes at whatever it held when the
// market first outran the threshold. That fossil then feeds EVERY consumer:
// a stale Bid drives structure touches and entry prices, a stale Ask made
// every SELL read as instantly +133530 points of profit. Ten ticks is far
// beyond the single-tick spike this guard exists for; past that, the market
// is right and the guard is wrong.
const int      MAX_CONSECUTIVE_HOLDS = 10;

double         g_saneBid            = 0.0;
double         g_saneAsk            = 0.0;
double         g_bidPending         = 0.0;
double         g_askPending         = 0.0;
int            g_bidRejectStreak    = 0;
int            g_askRejectStreak    = 0;
int            g_bidHoldCount       = 0;
int            g_askHoldCount       = 0;
bool           g_bidInit            = false;
bool           g_askInit            = false;

double         g_saneFloatingPnl    = 0.0;
double         g_pnlPending         = 0.0;
int            g_pnlRejectStreak    = 0;
int            g_pnlHoldCount       = 0;
bool           g_pnlInit            = false;

#endif // AJIPIDM_GLOBALS_MQH
