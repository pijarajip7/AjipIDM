#ifndef AJIPIDM_ENTRY_MQH
#define AJIPIDM_ENTRY_MQH

// CHECK ENTRY CLEANUP — detect positions that closed WITHOUT going through
// CloseAllAndFlushBatch (partial-close leaves the ticket open — only a full
// close removes it; e.g. a breakeven stop hit mid-batch). Folds each one's
// outcome into the current batch accumulator and removes it from tracking.
// Never writes CSV itself — the batch is only flushed by
// CloseAllAndFlushBatch (AjipIDM_Trade.mqh), which does so atomically.
//==================================================================
void CheckEntryCleanup()
  {
   int n = ArraySize(g_entries);
   for(int i = n - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         AccumulateBatchStats(g_entries[i]);
         RemoveEntry(i);
        }
     }
  }

//==================================================================
// ADD ENTRY to tracking. Also marks the start of a new batch (first entry
// since the last flush) or extends the current batch's last-entry-time —
// see g_batch* globals (AjipIDM_Globals.mqh).
//==================================================================
void AddEntry(ulong ticket, int dir)
  {
   int n = ArraySize(g_entries);
   ArrayResize(g_entries, n + 1);
   g_entries[n].ticket         = ticket;
   g_entries[n].dir            = dir;
   g_entries[n].mfe            = 0.0;
   g_entries[n].mae            = 0.0;
   g_entries[n].partialClosed  = false;

   if(PositionSelectByTicket(ticket))
     {
      g_entries[n].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_entries[n].entryTime  = (datetime)PositionGetInteger(POSITION_TIME);

      if(!g_batchActive)
        {
         g_batchActive         = true;
         g_batchFirstEntryTime = g_entries[n].entryTime;
        }
      g_batchLastEntryTime = g_entries[n].entryTime;
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
// CHECK PARTIAL CLOSE — one-time per position. Once a tracked position's
// floating profit reaches InpPartialClosePoints (price distance in points,
// favorable direction), close InpPartialClosePercent of its volume, move the
// remainder's SL to breakeven (entryPrice), and mark it done — the remainder
// then rides at BE until the daily close-all (or gets stopped out at entry).
// Called every tick, same cadence as UpdateMfeMae.
//==================================================================
void CheckPartialClose()
  {
   if(InpPartialClosePoints <= 0) return;

   int n = ArraySize(g_entries);
   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].partialClosed) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

      double entryPrice = g_entries[i].entryPrice;
      double curPrice   = (g_entries[i].dir == 1)
                           ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitPoints = (g_entries[i].dir == 1)
                             ? (curPrice - entryPrice) / g_point
                             : (entryPrice - curPrice) / g_point;

      if(profitPoints < InpPartialClosePoints) continue;

      g_entries[i].partialClosed = true; // one-shot regardless of outcome below

      double posVolume   = PositionGetDouble(POSITION_VOLUME);
      double closeVolume = posVolume * (InpPartialClosePercent / 100.0);
      closeVolume = MathFloor(closeVolume / g_volStep) * g_volStep;

      double remainder = posVolume - closeVolume;
      if(closeVolume < g_volMin || remainder < g_volMin)
        {
         if(InpEnableLog) PrintFormat("AjipIDM: Partial close skip — ticket=%I64u volume=%.2f too small to split at %.0f%%",
                     g_entries[i].ticket, posVolume, InpPartialClosePercent);
         continue;
        }

      if(!trade.PositionClosePartial(g_entries[i].ticket, closeVolume))
        {
         if(InpEnableLog) PrintFormat("AjipIDM: Partial close FAILED. Ticket=%I64u retcode=%d (%s)",
                     g_entries[i].ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
         continue;
        }

      if(InpEnableLog) PrintFormat("AjipIDM: Partial close done. Ticket=%I64u closed=%.2f remaining=%.2f (+%.0f pts)",
                  g_entries[i].ticket, closeVolume, remainder, profitPoints);

      // Move the remainder's SL to breakeven — closeVolume changed the
      // ticket's volume but not its SL/TP, so this still needs an explicit
      // PositionModify. TP stays 0 (no TP in this variant).
      if(!PositionSelectByTicket(g_entries[i].ticket))
         continue; // fully closed already (e.g. broker rounded remainder away)

      double beSl = NormalizeDouble(entryPrice, g_digits);
      if(trade.PositionModify(g_entries[i].ticket, beSl, PositionGetDouble(POSITION_TP)))
        {
         if(InpEnableLog)
            PrintFormat("AjipIDM: Breakeven SL set. Ticket=%I64u SL=%.5f", g_entries[i].ticket, beSl);
        }
      else
        {
         if(InpEnableLog)
            PrintFormat("AjipIDM: Breakeven SL FAILED. Ticket=%I64u retcode=%d (%s)",
                        g_entries[i].ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
     }
  }

//==================================================================
// CHECK DAILY CLOSE ALL — daily target/max loss now closes every open
// position outright (this variant has no per-position TP/SL). Uses
// realized (GetDailyPnL) + floating (GetFloatingPnL) so it reacts while
// positions are still running, not only after they're already closed.
// Called every tick. After close-all, DailyLimitReached() (realized-only)
// naturally blocks new entries for the rest of the day.
//==================================================================
void CheckDailyCloseAll()
  {
   double            total  = GetDailyPnL() + GetFloatingPnL();
   ENUM_LIMIT_STATUS status = ClassifyLimitStatus(total, InpDailyMaxProfit, InpDailyMaxLoss);

   if(status == LIMIT_STATUS_TARGET_HIT)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: Daily TARGET reached (%.2f >= %.2f) — closing all positions.",
                  total, InpDailyMaxProfit);
      CloseAllAndFlushBatch("DAILY_TARGET");
     }
   else if(status == LIMIT_STATUS_MAXLOSS_HIT)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: Daily MAX LOSS reached (%.2f <= -%.2f) — closing all positions.",
                  total, InpDailyMaxLoss);
      CloseAllAndFlushBatch("DAILY_MAX_LOSS");
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
// HTF ENTRY ALLOWED — gating only, no TP/SL in this variant. Entry itself
// is always fixed-lot, no SL/TP (see OpenTrade); this just decides whether
// the HTF equilibrium rule permits it.
// Requires g_htfTrend aligned with the entry direction (BUY needs HTF UP,
// SELL needs HTF DOWN) — without this, GetLastHtfSHDPrice/SLUPrice return
// a swing from the WRONG-shaped range (e.g. BUY during HTF DOWN would use
// the most recent, LOWER high as the reference, sitting below g_htfIdmPrice
// instead of above it — the equilibrium split stops being a meaningful
// discount/premium check and nearly always passes).
// Also requires the previous same-type HTF swing to be body-broken, not just
// swept (HtfPrevSwingBodyBroken) — e.g. uptrend: the SH before the current
// reference swing must have had a HTF candle CLOSE beyond it (ratcheting to
// whatever deeper wick the leg reached along the way, not just the original
// level), otherwise the leg is structurally weak (pure liquidity sweep) and
// entry is skipped.
// Reference = last HTF SH/SL swing (GetLastHtfSHDPrice/SLUPrice), used ONLY
// to compute equilibrium = midpoint of [g_htfIdmPrice, reference] — BUY only
// allowed in discount (entry price at/below midpoint), SELL only in premium
// (at/above). Same reference distance also feeds the min-points setup-quality
// filter (InpMinTpPoints). Shared by both entry paths (confirmation
// CheckIdmTaken, aggressive CheckAggressiveIdmTouch).
// Returns false (caller should skip the entry) on any rejection.
//==================================================================
bool HtfEntryAllowed(bool isBuy, double entryPrice)
  {
   string dirLabel = isBuy ? "BUY" : "SELL";

   if(g_htfTrend != (isBuy ? TREND_UP : TREND_DOWN))
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — HTF trend not aligned (HTF=%s, need %s)",
                  dirLabel, TrendString(g_htfTrend), isBuy ? "UP" : "DOWN");
      return false;
     }

   if(!HtfPrevSwingBodyBroken(isBuy))
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — HTF previous %s only swept, not body-broken",
                  dirLabel, isBuy ? "SH" : "SL");
      return false;
     }

   double reference = isBuy ? GetLastHtfSHDPrice() : GetLastHtfSLUPrice();
   if(reference <= 0.0 || (isBuy ? reference <= entryPrice : reference >= entryPrice))
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — HTF reference swing invalid (ref=%.5f, entry=%.5f)",
                  dirLabel, reference, entryPrice);
      return false;
     }

   if(g_htfIdmPrice <= 0.0)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — HTF idm not ready yet", dirLabel);
      return false;
     }

   double equilibrium = (g_htfIdmPrice + reference) / 2.0;
   bool   wrongSide    = isBuy ? (entryPrice > equilibrium) : (entryPrice < equilibrium);
   if(wrongSide)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — HTF equilibrium filter (entry=%.5f, eq=%.5f, htfIdm=%.5f, ref=%.5f)",
                  dirLabel, entryPrice, equilibrium, g_htfIdmPrice, reference);
      return false;
     }

   double refPoints = MathAbs(reference - entryPrice) / g_point;
   if(InpMinTpPoints > 0 && refPoints < InpMinTpPoints)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — reference distance %.0f pts < %d (ref=%.5f, entry=%.5f)",
                  dirLabel, refPoints, InpMinTpPoints, reference, entryPrice);
      return false;
     }

   return true;
  }

//==================================================================
// CHECK AGGRESSIVE IDM TOUCH (per-tick, bar NOT closed yet)
// InpUseAggressiveEntry mode: the instant price touches LTF idm intrabar,
// reverse the LTF structure RIGHT NOW using the last CLOSED bar as boundary
// (NOT the still-forming touch bar) — origin + retroactive structure are
// built purely from final bar data, so there's no repaint risk. Gating comes
// from HtfEntryAllowed (HTF-referenced equilibrium filter, same as
// confirmation entries) — the order itself is fixed-lot, no SL/TP, opened
// right away once gating passes.
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
   if(!InSession()) return;
   if(InNewsBlackout()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double oldIdm = g_idmPrice; // LTF level being swept — for logging only
   g_aggressiveFiredBarTime = rates[0].time;

   if(InpEnableLog) PrintFormat("AjipIDM: AGGRESSIVE %s idm touch @ %.5f — reversing early using last closed bar as boundary.",
               isBuy ? "BUY" : "SELL", oldIdm);

   // rates[1] = last CLOSED bar (NOT the forming touch bar) — keeps origin
   // scan + retroactive rebuild on final data only.
   if(isBuy)
      ReverseToDowntrend(rates[1]);
   else
      ReverseToUptrend(rates[1]);

   double entryEstimate = isBuy ? tick.ask : tick.bid;

   if(!HtfEntryAllowed(isBuy, entryEstimate)) return;

   ulong ticket = OpenTrade(isBuy, entryEstimate);
   if(ticket > 0)
      AddEntry(ticket, isBuy ? 1 : -1);
  }

//==================================================================
// CHECK IDM TAKEN (LTF entry decision — unchanged: idm taken + no body
// break → fade the sweep). Equilibrium gating now comes from
// HtfEntryAllowed (HTF-referenced) instead of LTF structure; entry itself
// is fixed-lot, no SL/TP.
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

   if(InpEnableLog) PrintFormat("AjipIDM: IDM TAKEN. Trend was %s, idm=%.5f, bar close=%.5f",
               TrendString(g_trend), g_idmPrice, bar.close);

   if(g_trend == TREND_UP)
     {
      // Trend changes to DOWN. Build downtrend from last SHU (= SHD0).
      ReverseToDowntrend(bar);

      if(alreadyAggressive)
        {
         if(InpEnableLog) PrintFormat("AjipIDM: BUY skip — already entered aggressively this bar.");
        }
      else if(doEntry && entryBuy && !g_initMode)
        {
         if(DailyLimitReached())
           {
            if(InpEnableLog) PrintFormat("AjipIDM: BUY skip — daily limit reached.");
           }
         else if(!InSession())
           {
            if(InpEnableLog) PrintFormat("AjipIDM: BUY skip — outside trading session.");
           }
         else if(InNewsBlackout())
           {
            if(InpEnableLog) PrintFormat("AjipIDM: BUY skip — news blackout.");
           }
         else if(HtfEntryAllowed(true, bar.close))
           {
            ulong ticket = OpenTrade(true, bar.close);
            if(ticket > 0)
               AddEntry(ticket, 1);
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
         if(InpEnableLog) PrintFormat("AjipIDM: SELL skip — already entered aggressively this bar.");
        }
      else if(doEntry && !entryBuy && !g_initMode)
        {
         if(DailyLimitReached())
           {
            if(InpEnableLog) PrintFormat("AjipIDM: SELL skip — daily limit reached.");
           }
         else if(!InSession())
           {
            if(InpEnableLog) PrintFormat("AjipIDM: SELL skip — outside trading session.");
           }
         else if(InNewsBlackout())
           {
            if(InpEnableLog) PrintFormat("AjipIDM: SELL skip — news blackout.");
           }
         else if(HtfEntryAllowed(false, bar.close))
           {
            ulong ticket = OpenTrade(false, bar.close);
            if(ticket > 0)
               AddEntry(ticket, -1);
           }
        }
      // Else: body break → no entry, continue uptrend
     }
  }

//==================================================================

#endif // AJIPIDM_ENTRY_MQH
