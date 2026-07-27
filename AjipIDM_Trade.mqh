#ifndef AJIPIDM_TRADE_MQH
#define AJIPIDM_TRADE_MQH

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
         PrintFormat("AjipIDM: Daily MAX PROFIT reached. PnL=%.2f >= %.2f. No new trades.",
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
         PrintFormat("AjipIDM: Daily MAX LOSS reached. PnL=%.2f <= -%.2f. No new trades.",
                     pnl, InpDailyMaxLoss);
         lastLossLog = today;
        }
      return(true);
     }

   return(false);
  }

//==================================================================
// WRITE TRADE CSV — append one closed-trade row (entry + exit + MFE/MAE)
// to MQL5/Files/AjipIDM_Trades_<symbol>_<magic>.csv. Called once per
// position from CheckEntryCleanup right when the position is
// detected closed (TP/SL/BE hit).
//==================================================================
void WriteTradeCsv(const EntryTracker &e)
  {
   double   exitPrice   = 0.0;
   datetime exitTime    = 0;
   string   reason      = "UNKNOWN";
   double   realizedPnl = 0.0;

   if(HistorySelectByPosition(e.ticket))
     {
      int ndeals = HistoryDealsTotal();
      for(int i = 0; i < ndeals; i++)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;

         long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY) continue;

         exitPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         exitTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         realizedPnl += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                      + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                      + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

         long dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
         if(dealReason == DEAL_REASON_TP)      reason = "TP";
         else if(dealReason == DEAL_REASON_SL) reason = "SL";
         else if(dealReason == DEAL_REASON_SO) reason = "STOPOUT";
         else                                  reason = "OTHER";
        }
     }

   string fname  = "AjipIDM_Trades_" + _Symbol + "_" + IntegerToString(InpMagicNumber) + ".csv";
   bool   exists = FileIsExist(fname);
   int    handle = FileOpen(fname, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("AjipIDM: WriteTradeCsv — failed to open %s, error=%d", fname, GetLastError());
      return;
     }

   FileSeek(handle, 0, SEEK_END);
   if(!exists)
      FileWriteString(handle, "Ticket,Dir,EntryTime,EntryPrice,ExitTime,ExitPrice,CloseReason,RealizedPnL,MFE,MAE\r\n");

   string line = StringFormat("%I64u,%s,%s,%.5f,%s,%.5f,%s,%.2f,%.2f,%.2f\r\n",
                               e.ticket, e.dir == 1 ? "BUY" : "SELL",
                               TimeToString(e.entryTime, TIME_DATE | TIME_MINUTES), e.entryPrice,
                               TimeToString(exitTime, TIME_DATE | TIME_MINUTES), exitPrice,
                               reason, realizedPnl, e.mfe, e.mae);
   FileWriteString(handle, line);
   FileClose(handle);
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
