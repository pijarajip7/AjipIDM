#ifndef AJIPIDM_TRADE_MQH
#define AJIPIDM_TRADE_MQH

// OPEN TRADE — fixed lot (InpFixedLot), no SL/TP. Returns ticket (0 = failed)
//==================================================================
ulong OpenTrade(bool isBuy, double entry)
  {
   double lot = NormalizeDouble(InpFixedLot, 8);
   if(lot < g_volMin || lot > g_volMax)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — InpFixedLot %.2f outside broker range [%.2f, %.2f]",
                  isBuy ? "BUY" : "SELL", lot, g_volMin, g_volMax);
      return(0);
     }

   // Get current price for market order
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return(0);

   bool ok;
   if(isBuy)
     {
      ok = trade.Buy(lot, _Symbol, tick.ask, 0.0, 0.0, "AjipIDM BUY");
     }
   else
     {
      ok = trade.Sell(lot, _Symbol, tick.bid, 0.0, 0.0, "AjipIDM SELL");
     }

   if(ok)
     {
      ulong ticket = trade.ResultOrder();
      if(InpEnableLog) PrintFormat("AjipIDM: %s opened. Ticket=%I64u, Lot=%.2f, Entry=%.5f, SL=NONE, TP=NONE",
                  isBuy ? "BUY" : "SELL", ticket, lot, entry);
      return(ticket);
     }

   if(InpEnableLog) PrintFormat("AjipIDM: Order failed. retcode=%d (%s)",
               trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return(0);
  }

//==================================================================
// GET PERIOD PNL — sum realized profit of closed deals (this symbol + magic)
// in [from, to]. Shared by GetDailyPnL/GetWeekPnL/GetMonthPnL.
//==================================================================
double GetPeriodPnL(datetime from, datetime to)
  {
   if(!HistorySelect(from, to)) return(0.0);

   double total = 0.0;
   int    ndeals = HistoryDealsTotal();
   for(int i = 0; i < ndeals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      // Filter by symbol
      string dealSymbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(dealSymbol != _Symbol) continue;

      // Filter by magic number
      long dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(dealMagic != InpMagicNumber) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      total += profit;
     }

   return(total);
  }

//==================================================================
// GET DAILY PNL — sum profit of all closed deals today (this symbol + magic)
// Returns total realized P/L for the current trading day.
//==================================================================
double GetDailyPnL()
  {
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   datetime dayEnd   = dayStart + 86400;
   return(GetPeriodPnL(dayStart, dayEnd));
  }

//==================================================================
// GET WEEK PNL — realized P/L from this week's Monday 00:00 to now
//==================================================================
double GetWeekPnL()
  {
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int dow = dt.day_of_week; // 0=Sunday..6=Saturday
   int daysSinceMonday = (dow == 0) ? 6 : (dow - 1);

   datetime weekStart = dayStart - daysSinceMonday * 86400;
   return(GetPeriodPnL(weekStart, TimeCurrent()));
  }

//==================================================================
// GET MONTH PNL — realized P/L from the 1st of this month 00:00 to now
//==================================================================
double GetMonthPnL()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.day  = 1;
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   datetime monthStart = StructToTime(dt);
   return(GetPeriodPnL(monthStart, TimeCurrent()));
  }

//==================================================================
// DAILY LIMIT REACHED — check if daily max profit or max loss hit
// Returns true if no new trades should be opened today.
//==================================================================
bool DailyLimitReached()
  {
   if(InpDailyMaxProfit <= 0.0 && InpDailyMaxLoss <= 0.0) return(false);

   double pnl = GetDailyPnL();

   if(InpDailyMaxProfit > 0.0 && pnl >= InpDailyMaxProfit)
     {
      static datetime lastProfitLog = 0;
      datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
      if(lastProfitLog != today)
        {
         if(InpEnableLog) PrintFormat("AjipIDM: Daily MAX PROFIT reached. PnL=%.2f >= %.2f. No new trades.",
                     pnl, InpDailyMaxProfit);
         lastProfitLog = today;
        }
      return(true);
     }

   if(InpDailyMaxLoss > 0.0 && pnl <= -InpDailyMaxLoss)
     {
      static datetime lastLossLog = 0;
      datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
      if(lastLossLog != today)
        {
         if(InpEnableLog) PrintFormat("AjipIDM: Daily MAX LOSS reached. PnL=%.2f <= -%.2f. No new trades.",
                     pnl, InpDailyMaxLoss);
         lastLossLog = today;
        }
      return(true);
     }

   return(false);
  }

//==================================================================
// GET FLOATING PNL — sum unrealized profit+swap of all OPEN positions
// (this symbol + magic). Since CloseAllAndFlushBatch always closes/accounts
// for EVERY tracked position before resetting, every currently-open
// position belongs to the CURRENT (unflushed) batch — so this is also
// exactly "the current batch's floating PnL", used by both
// CheckDailyCloseAll (+ GetDailyPnL) and CheckBatchCloseAll
// (+ g_batchRealizedPnl).
//==================================================================
double GetFloatingPnL()
  {
   double total = 0.0;
   int    n     = PositionsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return(total);
  }

//==================================================================
// CLASSIFY LIMIT STATUS — given a total and a (maxProfit, maxLoss) pair,
// decide where it sits. Generic: used for the daily-scoped check
// (InpDailyMaxProfit/Loss, CheckDailyCloseAll — blocks new entries via
// DailyLimitReached) AND the batch-scoped check (InpBatchMaxProfit/Loss,
// CheckBatchCloseAll — does NOT block entries), plus UpdatePanel
// (AjipIDM_Panel.mqh) for both.
//==================================================================
ENUM_LIMIT_STATUS ClassifyLimitStatus(double total, double maxProfit, double maxLoss)
  {
   if(maxProfit <= 0.0 && maxLoss <= 0.0) return(LIMIT_STATUS_DISABLED);
   if(maxProfit > 0.0 && total >= maxProfit) return(LIMIT_STATUS_TARGET_HIT);
   if(maxLoss   > 0.0 && total <= -maxLoss)  return(LIMIT_STATUS_MAXLOSS_HIT);
   return(LIMIT_STATUS_ACTIVE);
  }

//==================================================================
// PARSE HH:MM — used once in OnInit to parse InpSessionStart/InpSessionEnd
// into minutes-since-midnight. Returns false (outMinutes untouched) on any
// malformed input.
//==================================================================
bool ParseHHMM(const string hhmm, int &outMinutes)
  {
   string parts[];
   if(StringSplit(hhmm, ':', parts) != 2) return(false);

   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return(false);

   outMinutes = h * 60 + m;
   return(true);
  }

//==================================================================
// IN SESSION — is the current SERVER time (TimeCurrent(), same clock as
// GetDailyPnL/daily reset) inside [g_sessionStartMin, g_sessionEndMin)?
// g_sessionFilterEnabled=false (start==end or unparseable input, set in
// OnInit) means unrestricted — always true. Handles sessions that wrap
// midnight (e.g. 22:00-06:00) via start > end.
//==================================================================
bool InSession()
  {
   if(!g_sessionFilterEnabled) return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;

   if(g_sessionStartMin <= g_sessionEndMin)
      return(nowMin >= g_sessionStartMin && nowMin < g_sessionEndMin);

   return(nowMin >= g_sessionStartMin || nowMin < g_sessionEndMin); // wraps midnight
  }

//==================================================================
// CHECK SESSION CLOSE ALL — outside the configured session with the book
// in profit (realized+floating > 0): close everything so profit isn't
// given back outside trading hours, even if InpDailyMaxProfit hasn't been
// reached. Called every tick. No-op if the session filter is disabled.
//==================================================================
void CheckSessionCloseAll()
  {
   if(!g_sessionFilterEnabled) return;
   if(InSession()) return;

   double total = GetDailyPnL() + GetFloatingPnL();
   if(total <= 0.0) return;

   if(InpEnableLog) PrintFormat("AjipIDM: Outside session (%02d:%02d-%02d:%02d), PnL=%.2f > 0 — closing all positions.",
               g_sessionStartMin / 60, g_sessionStartMin % 60,
               g_sessionEndMin / 60, g_sessionEndMin % 60, total);
   CloseAllAndFlushBatch("SESSION_END");
  }

//==================================================================
// CHECK BATCH CLOSE ALL — separate from CheckDailyCloseAll: this checks the
// CURRENT BATCH's own total (g_batchRealizedPnl — positions already closed
// this batch — + GetFloatingPnL(), which always belongs to the current
// batch only, see GetFloatingPnL comment) against InpBatchMaxProfit/
// InpBatchMaxLoss. Unlike the daily check, hitting this does NOT block new
// entries — DailyLimitReached() is untouched, so a fresh batch can start
// again right away (CloseAllAndFlushBatch resets synchronously, no race
// with an entry opening on the same or a later tick). Called every tick.
//==================================================================
void CheckBatchCloseAll()
  {
   double            total  = g_batchRealizedPnl + GetFloatingPnL();
   ENUM_LIMIT_STATUS status = ClassifyLimitStatus(total, InpBatchMaxProfit, InpBatchMaxLoss);

   if(status == LIMIT_STATUS_TARGET_HIT)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: Batch TARGET reached (%.2f >= %.2f) — closing current batch.",
                  total, InpBatchMaxProfit);
      CloseAllAndFlushBatch("BATCH_TARGET");
     }
   else if(status == LIMIT_STATUS_MAXLOSS_HIT)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: Batch MAX LOSS reached (%.2f <= -%.2f) — closing current batch.",
                  total, InpBatchMaxLoss);
      CloseAllAndFlushBatch("BATCH_MAX_LOSS");
     }
  }

//==================================================================
// ACCUMULATE BATCH STATS — fold one fully-closed position's outcome into
// the current batch accumulator (realized PnL, win/loss/breakeven count,
// MFE/MAE sums). Nothing is written to disk here. Called from
// CheckEntryCleanup (AjipIDM_Entry.mqh, stragglers like a breakeven stop)
// and from CloseAllAndFlushBatch below (positions it just closed).
//==================================================================
void AccumulateBatchStats(const EntryTracker &e)
  {
   double realizedPnl = 0.0;

   if(HistorySelectByPosition(e.ticket))
     {
      int ndeals = HistoryDealsTotal();
      for(int i = 0; i < ndeals; i++)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;

         long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY) continue;

         realizedPnl += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                      + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                      + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
        }
     }

   g_batchCount++;
   g_batchRealizedPnl += realizedPnl;
   g_batchMfeSum       += e.mfe;
   g_batchMaeSum       += e.mae;

   if(realizedPnl > 0.0)      g_batchWins++;
   else if(realizedPnl < 0.0) g_batchLosses++;
   else                       g_batchBreakEven++;
  }

//==================================================================
// WRITE BATCH CSV — append ONE row summarizing the just-completed batch to
// MQL5/Files/AjipIDM_Batches_<symbol>_<magic>.csv. Called only from
// CloseAllAndFlushBatch, only when g_batchCount > 0 (never an empty row).
//==================================================================
void WriteBatchCsv(const string reason)
  {
   string fname  = "AjipIDM_Batches_" + _Symbol + "_" + IntegerToString(InpMagicNumber) + ".csv";
   bool   exists = FileIsExist(fname);
   int    handle = FileOpen(fname, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: WriteBatchCsv — failed to open %s, error=%d", fname, GetLastError());
      return;
     }

   FileSeek(handle, 0, SEEK_END);
   if(!exists)
      FileWriteString(handle, "CloseTime,CloseReason,PositionCount,Wins,Losses,BreakEven,TotalRealizedPnL,SumMFE,SumMAE,FirstEntryTime,LastEntryTime\r\n");

   string line = StringFormat("%s,%s,%d,%d,%d,%d,%.2f,%.2f,%.2f,%s,%s\r\n",
                               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
                               reason,
                               g_batchCount, g_batchWins, g_batchLosses, g_batchBreakEven,
                               g_batchRealizedPnl, g_batchMfeSum, g_batchMaeSum,
                               TimeToString(g_batchFirstEntryTime, TIME_DATE | TIME_MINUTES),
                               TimeToString(g_batchLastEntryTime, TIME_DATE | TIME_MINUTES));
   FileWriteString(handle, line);
   FileClose(handle);

   if(InpEnableLog) PrintFormat("AjipIDM: Batch CSV written. Reason=%s Positions=%d Wins=%d Losses=%d BE=%d TotalPnL=%.2f",
               reason, g_batchCount, g_batchWins, g_batchLosses, g_batchBreakEven, g_batchRealizedPnl);
  }

//==================================================================
// RESET BATCH ACCUMULATOR — clear every per-batch counter after a flush,
// ready for the next batch.
//==================================================================
void ResetBatchAccumulator()
  {
   g_batchActive         = false;
   g_batchFirstEntryTime = 0;
   g_batchLastEntryTime  = 0;
   g_batchCount          = 0;
   g_batchWins           = 0;
   g_batchLosses         = 0;
   g_batchBreakEven      = 0;
   g_batchRealizedPnl    = 0.0;
   g_batchMfeSum         = 0.0;
   g_batchMaeSum         = 0.0;
  }

//==================================================================
// FLUSH BATCH IF DONE — writes the batch CSV row (skipped if
// g_batchCount==0 — nothing was ever open) and resets the accumulator, but
// ONLY if g_entries is empty (every tracked position accounted for). No-op
// otherwise (stragglers still open — retried whichever trigger fires next).
// Shared by CloseAllAndFlushBatch (deliberate close-all: daily/batch
// target/loss, session end) and CheckEntryCleanup (AjipIDM_Entry.mqh —
// organic close, e.g. every remaining position stopped out at breakeven
// with no close-all ever firing) so a batch gets flushed to CSV as soon as
// it's actually finished, regardless of WHY it emptied out.
//==================================================================
void FlushBatchIfDone(const string reason)
  {
   if(ArraySize(g_entries) > 0)
      return; // one or more stragglers still open — don't flush yet

   if(g_batchCount > 0)
      WriteBatchCsv(reason);
   ResetBatchAccumulator();
  }

//==================================================================
// CLOSE ALL AND FLUSH BATCH — this symbol + magic. Closes every open
// position, then ATOMICALLY (no next-bar delay) folds each tracked entry's
// outcome into the batch accumulator and removes it from tracking, then
// flushes via FlushBatchIfDone. If one or more closes FAILED (still open at
// broker), those stay tracked and nothing is flushed yet — retried whichever
// trigger fires next. Doing this synchronously (not deferred to
// CheckEntryCleanup on the next closed bar) matters specifically for
// CheckBatchCloseAll: unlike daily/session, a batch-limit hit does NOT block
// new entries, so without this a new entry could open (AddEntry) on the same
// or a later tick BEFORE the old batch's tracking was ever cleared/flushed —
// corrupting the boundary between the old and new batch.
//==================================================================
void CloseAllAndFlushBatch(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      if(!trade.PositionClose(ticket))
         if(InpEnableLog) PrintFormat("AjipIDM: CloseAllAndFlushBatch — failed to close ticket=%I64u, retcode=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   int n = ArraySize(g_entries);
   for(int i = n - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(g_entries[i].ticket))
         continue; // close failed above — stays tracked, retried next trigger

      AccumulateBatchStats(g_entries[i]);
      RemoveEntry(i);
     }

   FlushBatchIfDone(reason);
  }

//==================================================================
// SWING ARRAY HELPERS
//==================================================================
void ResetSwings()
  {
   ArrayResize(g_swings, 0);
  }

void AddSwing(double price, double zonePrice, datetime time, bool isHigh)
  {
   int n = ArraySize(g_swings);
   ArrayResize(g_swings, n + 1);
   g_swings[n].price     = price;
   g_swings[n].zonePrice = zonePrice;
   g_swings[n].time      = time;
   g_swings[n].isHigh    = isHigh;
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
                       g_trend == TREND_UP ? clrDodgerBlue : clrOrangeRed);
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
   ObjectsDeleteAll(0, g_panelPrefix);
   ObjectsDeleteAll(0, g_htfObjPrefix);
  }

//+------------------------------------------------------------------+

#endif // AJIPIDM_TRADE_MQH
