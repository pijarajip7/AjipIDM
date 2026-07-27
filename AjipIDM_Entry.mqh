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
         // Position closed (TP/SL hit) — log MFE/MAE to CSV, remove from tracking
         WriteTradeCsv(g_entries[i]);
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
   g_entries[n].mfe         = 0.0;
   g_entries[n].mae         = 0.0;

   if(PositionSelectByTicket(ticket))
     {
      g_entries[n].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_entries[n].entryTime  = (datetime)PositionGetInteger(POSITION_TIME);
     }
  }

//==================================================================
// UPDATE MFE/MAE — track best/worst floating P/L ($) for every tracked
// open position. Called every tick (not gated by new-bar) so intra-bar
// excursions are captured, not just closed-bar extremes.
//==================================================================
void UpdateMfeMae()
  {
   int n = ArraySize(g_entries);
   for(int i = 0; i < n; i++)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      g_entries[i].mfe = MathMax(g_entries[i].mfe, profit);
      g_entries[i].mae = MathMin(g_entries[i].mae, profit);
     }
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
// CHECK AGGRESSIVE IDM TOUCH (per-tick, bar NOT closed yet)
// InpUseAggressiveEntry mode: the instant price touches idm intrabar,
// reverse the structure RIGHT NOW using the last CLOSED bar as boundary
// (NOT the still-forming touch bar) — origin + retroactive structure are
// built purely from final bar data, so there's no repaint risk. This makes
// the real structural TP available immediately, so SL/TP are set on the
// entry order right away, same formula as a confirmation entry — no naked
// window at all.
//
// The still-forming touch bar itself is untouched here; once it actually
// closes, it flows through the normal UpdateStructure()/CheckEntryInvalidation()
// path in OnTick like any other bar — extending this same structure further
// and (via sweepPrice = old idm) naturally resolving sweep-confirmed vs
// body-break through the existing invalidation logic. No special-casing
// needed for that — see CheckEntryInvalidation.
//
// Guarded by g_aggressiveFiredBarTime so only ONE aggressive entry fires
// per forming bar, even if price oscillates around idm multiple times.
//==================================================================
void CheckAggressiveIdmTouch()
  {
   if(!InpUseAggressiveEntry) return;
   if(g_idmTaken) return;
   if(g_idmPrice <= 0.0) return;
   if(g_initMode) return;

   // Touch uses Bid — matches the Bid-based OHLC series g_idmPrice is derived from.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool touchBuy  = (g_trend == TREND_UP   && bid < g_idmPrice);
   bool touchSell = (g_trend == TREND_DOWN && bid > g_idmPrice);
   if(!touchBuy && !touchSell) return;

   bool isBuy = touchBuy;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpTimeframe, 0, 2, rates) < 2) return;

   if(rates[0].time == g_aggressiveFiredBarTime) return; // already fired for this forming bar

   // Same gating as confirmation-mode entry: HTF filter + daily limit.
   if(InpUseHtfFilter && g_htfTrend != (isBuy ? TREND_UP : TREND_DOWN)) return;
   if(DailyLimitReached()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double oldIdm = g_idmPrice; // level being swept — becomes this entry's sweepPrice
   g_aggressiveFiredBarTime = rates[0].time;

   PrintFormat("AjipIDM: AGGRESSIVE %s idm touch @ %.5f — reversing early using last closed bar as boundary.",
               isBuy ? "BUY" : "SELL", oldIdm);

   // rates[1] = last CLOSED bar (NOT the forming touch bar) — keeps origin
   // scan + retroactive rebuild on final data only.
   if(isBuy)
      ReverseToDowntrend(rates[1]);
   else
      ReverseToUptrend(rates[1]);

   double tp            = isBuy ? GetLastSHDPrice() : GetLastSLUPrice();
   double entryEstimate = isBuy ? tick.ask : tick.bid;

   if(tp <= 0.0 || (isBuy ? tp <= entryEstimate : tp >= entryEstimate))
     {
      PrintFormat("AjipIDM: Aggressive %s skip — TP invalid after early reverse (tp=%.5f, entry~%.5f)",
                  isBuy ? "BUY" : "SELL", tp, entryEstimate);
      return;
     }

   double tpDistance = MathAbs(tp - entryEstimate);
   double tpPoints    = tpDistance / g_point;
   if(InpMinTpPoints > 0 && tpPoints < InpMinTpPoints)
     {
      PrintFormat("AjipIDM: Aggressive %s skip — TP points %.0f < %d (tp=%.5f, entry~%.5f)",
                  isBuy ? "BUY" : "SELL", tpPoints, InpMinTpPoints, tp, entryEstimate);
      return;
     }

   double sl = 0.0;
   if(InpRR > 0.0)
     {
      double slDistance = tpDistance / InpRR;
      sl = isBuy ? entryEstimate - slDistance : entryEstimate + slDistance;
     }

   ulong ticket = OpenTrade(isBuy, entryEstimate, sl, tp);
   if(ticket > 0)
      AddEntry(ticket, oldIdm, isBuy ? 1 : -1); // sweepPrice=oldIdm; refined to bar low/high by CheckEntryInvalidation once this bar closes
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
