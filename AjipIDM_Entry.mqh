#ifndef AJIPIDM_ENTRY_MQH
#define AJIPIDM_ENTRY_MQH

// CHECK ENTRY CLEANUP — detect positions that closed (TP/SL hit), log
// MFE/MAE to CSV, remove from tracking. Invalidation itself no longer
// happens here — it's HTF-driven and portfolio-level now, see
// CheckHtfInvalidation below.
//==================================================================
void CheckEntryCleanup()
  {
   int n = ArraySize(g_entries);
   for(int i = n - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         WriteTradeCsv(g_entries[i]);
         RemoveEntry(i);
        }
     }
  }

//==================================================================
// ADD ENTRY to tracking
//==================================================================
void AddEntry(ulong ticket, int dir)
  {
   int n = ArraySize(g_entries);
   ArrayResize(g_entries, n + 1);
   g_entries[n].ticket = ticket;
   g_entries[n].dir    = dir;
   g_entries[n].mfe    = 0.0;
   g_entries[n].mae    = 0.0;

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
// COMPUTE HTF-REFERENCED ENTRY LEVELS
// Requires g_htfTrend aligned with the entry direction (BUY needs HTF UP,
// SELL needs HTF DOWN) — without this, GetLastHtfSHDPrice/SLUPrice return
// a swing from the WRONG-shaped range (e.g. BUY during HTF DOWN would use
// the most recent, LOWER high as TP, sitting below g_htfIdmPrice instead
// of above it — the equilibrium split stops being a meaningful discount/
// premium check and nearly always passes).
// TP = last HTF SH/SL swing (GetLastHtfSHDPrice/SLUPrice). Equilibrium =
// midpoint of [g_htfIdmPrice, tp] — BUY only allowed in discount (entry
// price at/below midpoint), SELL only in premium (at/above). SL from RR.
// Shared by both entry paths (confirmation CheckIdmTaken, aggressive
// CheckAggressiveIdmTouch) so TP/equilibrium logic lives in one place.
// Returns false (caller should skip the entry) on any rejection.
//==================================================================
bool ComputeHtfEntryLevels(bool isBuy, double entryPrice, double &outTp, double &outSl)
  {
   string dirLabel = isBuy ? "BUY" : "SELL";

   if(g_htfTrend != (isBuy ? TREND_UP : TREND_DOWN))
     {
      PrintFormat("AjipIDM: %s skip — HTF trend not aligned (HTF=%s, need %s)",
                  dirLabel, TrendString(g_htfTrend), isBuy ? "UP" : "DOWN");
      return false;
     }

   double tp = isBuy ? GetLastHtfSHDPrice() : GetLastHtfSLUPrice();
   if(tp <= 0.0 || (isBuy ? tp <= entryPrice : tp >= entryPrice))
     {
      PrintFormat("AjipIDM: %s skip — HTF TP invalid (tp=%.5f, entry=%.5f)", dirLabel, tp, entryPrice);
      return false;
     }

   if(g_htfIdmPrice <= 0.0)
     {
      PrintFormat("AjipIDM: %s skip — HTF idm not ready yet", dirLabel);
      return false;
     }

   double equilibrium = (g_htfIdmPrice + tp) / 2.0;
   bool   wrongSide    = isBuy ? (entryPrice > equilibrium) : (entryPrice < equilibrium);
   if(wrongSide)
     {
      PrintFormat("AjipIDM: %s skip — HTF equilibrium filter (entry=%.5f, eq=%.5f, htfIdm=%.5f, tp=%.5f)",
                  dirLabel, entryPrice, equilibrium, g_htfIdmPrice, tp);
      return false;
     }

   double tpDistance = MathAbs(tp - entryPrice);
   double tpPoints    = tpDistance / g_point;
   if(InpMinTpPoints > 0 && tpPoints < InpMinTpPoints)
     {
      PrintFormat("AjipIDM: %s skip — TP points %.0f < %d (tp=%.5f, entry=%.5f)",
                  dirLabel, tpPoints, InpMinTpPoints, tp, entryPrice);
      return false;
     }

   double sl = 0.0;
   if(InpRR > 0.0)
     {
      double slDistance = tpDistance / InpRR;
      sl = isBuy ? entryPrice - slDistance : entryPrice + slDistance;
     }

   outTp = tp;
   outSl = sl;
   return true;
  }

//==================================================================
// CHECK AGGRESSIVE IDM TOUCH (per-tick, bar NOT closed yet)
// InpUseAggressiveEntry mode: the instant price touches LTF idm intrabar,
// reverse the LTF structure RIGHT NOW using the last CLOSED bar as boundary
// (NOT the still-forming touch bar) — origin + retroactive structure are
// built purely from final bar data, so there's no repaint risk. TP/SL come
// from ComputeHtfEntryLevels (HTF-referenced, same as confirmation entries)
// and are set on the order right away — no naked window.
//
// The still-forming touch bar itself is untouched here; once it actually
// closes, it flows through the normal UpdateStructure() path in OnTick
// like any other bar, extending the LTF structure further.
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
   if(DailyLimitReached()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double oldIdm = g_idmPrice; // LTF level being swept — for logging only
   g_aggressiveFiredBarTime = rates[0].time;

   PrintFormat("AjipIDM: AGGRESSIVE %s idm touch @ %.5f — reversing early using last closed bar as boundary.",
               isBuy ? "BUY" : "SELL", oldIdm);

   // rates[1] = last CLOSED bar (NOT the forming touch bar) — keeps origin
   // scan + retroactive rebuild on final data only.
   if(isBuy)
      ReverseToDowntrend(rates[1]);
   else
      ReverseToUptrend(rates[1]);

   double entryEstimate = isBuy ? tick.ask : tick.bid;

   double tp, sl;
   if(!ComputeHtfEntryLevels(isBuy, entryEstimate, tp, sl)) return;

   ulong ticket = OpenTrade(isBuy, entryEstimate, sl, tp);
   if(ticket > 0)
      AddEntry(ticket, isBuy ? 1 : -1);
  }

//==================================================================
// CHECK IDM TAKEN (LTF entry decision — unchanged: idm taken + no body
// break → fade the sweep). TP/SL/equilibrium now come from
// ComputeHtfEntryLevels (HTF-referenced) instead of LTF structure.
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

   // This bar already had an aggressive touch entry (CheckAggressiveIdmTouch
   // reverses the trend intrabar using the SAME bar-to-be-closed as boundary
   // context) — without this guard, this closed-bar pass can independently
   // find "taken" on the freshly-reversed trend and open a SECOND entry for
   // what is effectively the same event. Structure/reversal still proceeds
   // normally below; only the entry itself is suppressed for this bar.
   bool alreadyAggressive = InpUseAggressiveEntry && (bar.time == g_aggressiveFiredBarTime);

   PrintFormat("AjipIDM: IDM TAKEN. Trend was %s, idm=%.5f, bar close=%.5f",
               TrendString(g_trend), g_idmPrice, bar.close);

   if(g_trend == TREND_UP)
     {
      // Trend changes to DOWN. Build downtrend from last SHU (= SHD0).
      ReverseToDowntrend(bar);

      if(alreadyAggressive)
        {
         PrintFormat("AjipIDM: BUY skip — already entered aggressively this bar.");
        }
      else if(doEntry && entryBuy && !g_initMode)
        {
         if(DailyLimitReached())
           {
            PrintFormat("AjipIDM: BUY skip — daily limit reached.");
           }
         else
           {
            double tp, sl;
            if(ComputeHtfEntryLevels(true, bar.close, tp, sl))
              {
               ulong ticket = OpenTrade(true, bar.close, sl, tp);
               if(ticket > 0)
                  AddEntry(ticket, 1);
              }
           }
        }
      // Else: body break or init mode → no entry, continue downtrend
     }
   else if(g_trend == TREND_DOWN)
     {
      // Trend changes to UP. Build uptrend from last SLD (= SLU0).
      ReverseToUptrend(bar);

      if(alreadyAggressive)
        {
         PrintFormat("AjipIDM: SELL skip — already entered aggressively this bar.");
        }
      else if(doEntry && !entryBuy && !g_initMode)
        {
         if(DailyLimitReached())
           {
            PrintFormat("AjipIDM: SELL skip — daily limit reached.");
           }
         else
           {
            double tp, sl;
            if(ComputeHtfEntryLevels(false, bar.close, tp, sl))
              {
               ulong ticket = OpenTrade(false, bar.close, sl, tp);
               if(ticket > 0)
                  AddEntry(ticket, -1);
              }
           }
        }
      // Else: body break → no entry, continue uptrend
     }
  }

//==================================================================
// CHECK HTF INVALIDATION (called on every HTF bar close)
// The HTF-level, portfolio-wide invalidation mechanism: once
// HtfCheckIdmTaken flags a level being swept (g_htfSweepPrice/g_htfSweepDir,
// set in AjipIDM_HtfContext.mqh), watch it here.
//   Phase 1: body break (HTF close fails to reclaim) → apply
//            InpInvalidationMode to every open position matching
//            g_htfSweepDir, using their AVERAGE entry price.
//   Phase 2: if not broken, deepen the watched level if this bar pushes
//            further (mirrors the old per-ticket sweep-update logic).
//==================================================================
void CheckHtfInvalidation(MqlRates &bar)
  {
   if(g_htfSweepDir == 0) return;

   bool bodyBreak = (g_htfSweepDir == 1  && bar.close < g_htfSweepPrice) ||
                    (g_htfSweepDir == -1 && bar.close > g_htfSweepPrice);

   if(bodyBreak)
     {
      PrintFormat("AjipIDM: HTF BODY BREAK. Dir=%s, sweep=%.5f, close=%.5f",
                  g_htfSweepDir == 1 ? "BUY" : "SELL", g_htfSweepPrice, bar.close);
      ApplyHtfInvalidation(g_htfSweepDir);
      g_htfSweepDir = 0; // resolved — stop watching until the next HTF idm-taken event
      return;
     }

   // Phase 2: deepen the watched level if this bar pushes further without breaking body.
   if(g_htfSweepDir == 1 && bar.low < g_htfSweepPrice)
      g_htfSweepPrice = bar.low;
   else if(g_htfSweepDir == -1 && bar.high > g_htfSweepPrice)
      g_htfSweepPrice = bar.high;
  }

//==================================================================
// APPLY HTF INVALIDATION — InpInvalidationMode, portfolio-level: modifies
// every open position matching dir, using their average entry price for
// FIXED_TP. Matches are removed from tracking afterward (don't re-check),
// same semantics as the old per-ticket LTF invalidation.
//==================================================================
void ApplyHtfInvalidation(int dir)
  {
   int n = ArraySize(g_entries);

   double sumEntry = 0.0;
   int    count    = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].dir != dir) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
      sumEntry += PositionGetDouble(POSITION_PRICE_OPEN);
      count++;
     }

   if(count == 0) return;

   double avgEntry = sumEntry / count;

   PrintFormat("AjipIDM: HTF INVALIDATION applied. Dir=%s, avgEntry=%.5f, positions=%d, mode=%s",
               dir == 1 ? "BUY" : "SELL", avgEntry, count,
               InpInvalidationMode == INVALIDATION_FIXED_TP ? "FIXED_TP" : "DO_NOTHING");

   if(InpInvalidationMode == INVALIDATION_FIXED_TP)
     {
      double tpDistance = InpInvalidationTpPoints * g_point;
      double newTp      = (dir == 1) ? avgEntry + tpDistance : avgEntry - tpDistance;

      for(int i = 0; i < n; i++)
        {
         if(g_entries[i].dir != dir) continue;
         ulong ticket = g_entries[i].ticket;
         if(!PositionSelectByTicket(ticket)) continue;

         double sl = PositionGetDouble(POSITION_SL);
         if(trade.PositionModify(ticket, sl, NormalizeDouble(newTp, g_digits)))
            PrintFormat("AjipIDM: HTF invalidation TP modified. Ticket=%I64u newTP=%.5f", ticket, newTp);
         else
            PrintFormat("AjipIDM: HTF invalidation TP modify FAILED. Ticket=%I64u retcode=%d (%s)",
                        ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
     }
   // else INVALIDATION_DO_NOTHING: leave TP/SL as is

   // Stop tracking these — invalidated, don't re-check.
   for(int i = n - 1; i >= 0; i--)
     {
      if(g_entries[i].dir == dir)
         RemoveEntry(i);
     }
  }

//==================================================================

#endif // AJIPIDM_ENTRY_MQH
