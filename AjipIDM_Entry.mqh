#ifndef AJIPIDM_ENTRY_MQH
#define AJIPIDM_ENTRY_MQH

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
         PrintFormat("AjipIDM: BODY BREAK. Ticket=%I64u Dir=%s, sweep=%.5f, close=%.5f",
                     ticket, dir == 1 ? "BUY" : "SELL", sweepPrice, bar.close);

         if(InpInvalidationMode == INVALIDATION_FIXED_TP)
           {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl         = PositionGetDouble(POSITION_SL);
            double tpDistance = InpInvalidationTpPoints * g_point;
            double newTP      = (dir == 1) ? entryPrice + tpDistance : entryPrice - tpDistance;

            if(trade.PositionModify(ticket, sl, newTP))
               PrintFormat("AjipIDM: TP modified to fixed %d points (%.5f) for ticket %I64u",
                           InpInvalidationTpPoints, newTP, ticket);
            else
               PrintFormat("AjipIDM: Failed to modify TP for %I64u. retcode=%d (%s)",
                           ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
           }
         // else INVALIDATION_DO_NOTHING: leave TP/SL as is

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
         // HTF trend filter
         if(InpUseHtfFilter && g_htfTrend != TREND_UP)
           {
            PrintFormat("AjipIDM: BUY skip — HTF filter (HTF trend=%s, need UP).", TrendString(g_htfTrend));
           }
         // Daily limit check
         else if(DailyLimitReached())
           {
            PrintFormat("AjipIDM: BUY skip — daily limit reached.");
           }
         else
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
               // Equilibrium filter: midpoint of sweep low → TP. BUY should be
               // in discount (close <= midpoint); close above it = too little
               // room left to TP relative to the sweep → skip.
               double equilibrium = (bar.low + tp) / 2.0;

               if(InpMinTpPoints > 0 && tpPoints < InpMinTpPoints)
                 {
                  PrintFormat("AjipIDM: BUY skip — TP points %.0f < %d (tp=%.5f, close=%.5f)",
                              tpPoints, InpMinTpPoints, tp, bar.close);
                 }
               else if(InpUseEquilibriumFilter && bar.close > equilibrium)
                 {
                  PrintFormat("AjipIDM: BUY skip — equilibrium filter (close=%.5f > eq=%.5f, sweepLow=%.5f, tp=%.5f)",
                              bar.close, equilibrium, bar.low, tp);
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
        }
      // Else: body break or init mode → no entry, continue downtrend
     }
   else if(g_trend == TREND_DOWN)
     {
      // Trend changes to UP. Build uptrend from last SLD (= SLU0).
      ReverseToUptrend(bar);

      if(doEntry && !entryBuy && !g_initMode)
        {
         // HTF trend filter
         if(InpUseHtfFilter && g_htfTrend != TREND_DOWN)
           {
            PrintFormat("AjipIDM: SELL skip — HTF filter (HTF trend=%s, need DOWN).", TrendString(g_htfTrend));
           }
         // Daily limit check
         else if(DailyLimitReached())
           {
            PrintFormat("AjipIDM: SELL skip — daily limit reached.");
           }
         else
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
               // Equilibrium filter: midpoint of TP → sweep high. SELL should
               // be in premium (close >= midpoint); close below it = too
               // little room left to TP relative to the sweep → skip.
               double equilibrium = (tp + bar.high) / 2.0;

               if(InpMinTpPoints > 0 && tpPoints < InpMinTpPoints)
                 {
                  PrintFormat("AjipIDM: SELL skip — TP points %.0f < %d (tp=%.5f, close=%.5f)",
                              tpPoints, InpMinTpPoints, tp, bar.close);
                 }
               else if(InpUseEquilibriumFilter && bar.close < equilibrium)
                 {
                  PrintFormat("AjipIDM: SELL skip — equilibrium filter (close=%.5f < eq=%.5f, sweepHigh=%.5f, tp=%.5f)",
                              bar.close, equilibrium, bar.high, tp);
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
        }
      // Else: body break → no entry, continue uptrend
     }
  }

//==================================================================

#endif // AJIPIDM_ENTRY_MQH
