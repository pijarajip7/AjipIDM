#ifndef AJIPIDM_ENTRY_MQH
#define AJIPIDM_ENTRY_MQH

// CHECK ENTRY CLEANUP — detect positions that closed WITHOUT going through
// CloseAllAndFlushBatch (partial-close leaves the ticket open — only a full
// close removes it; e.g. a breakeven stop hit mid-batch). Folds each one's
// outcome into the current batch accumulator and removes it from tracking.
// If that was the LAST tracked position (every open position stopped out
// organically, with no batch/daily/session close-all ever firing),
// FlushBatchIfDone (AjipIDM_Trade.mqh) writes the CSV row right here instead
// of leaving the batch open indefinitely waiting for some later trigger.
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

   FlushBatchIfDone("ALL_CLOSED");
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
// REBUILD TRACKED POSITIONS — called once from OnInit. Repopulates
// g_entries from whatever's already open for this symbol+magic when the EA
// (re)starts — recompile, manual reattach, chart timeframe change, terminal
// restart. Without this, positions opened by an EARLIER run stay open at
// the broker but the EA has no memory of them: CheckPartialClose never
// fires for them, RecalculateAggregateSL never protects them,
// MaxTotalLotsReached doesn't count their volume, and if a close-all later
// closes them, their outcome silently never reaches the batch CSV (nothing
// in g_entries for CloseAllAndFlushBatch to fold into AccumulateBatchStats).
//
// partialClosed is always seeded false, even for a position whose SL
// happens to already sit at its entry price. That SL could be a genuine
// breakeven from CheckPartialClose — or it could just as easily be
// RecalculateAggregateSL landing there by coincidence (a tight risk budget
// relative to volume can put the aggregate SL arbitrarily close to entry on
// a position that was NEVER partial-closed). There is no reliable way to
// tell those apart from the position's state alone, and the two wrong
// guesses are not symmetric: seeding true on a guess risks skipping
// CheckPartialClose for that ticket forever (silently — it just never fires
// again), whereas seeding false in the rare case where it truly was already
// breakeven only risks one redundant partial-close attempt on the
// remainder, which does no harm. Always false is the safe direction to be
// wrong in.
//
// Only rebuilds tracking for what's still open RIGHT NOW — any positions
// from the same interrupted batch that already fully closed before this
// restart are unrecoverable (their P&L was never accumulated and there's no
// record of which trades belonged to which batch), so batch stats picked
// back up from here reflect only what survived the restart, not the whole
// original batch.
//==================================================================
void RebuildTrackedPositions()
  {
   datetime firstTime = 0;
   datetime lastTime  = 0;
   int      recovered = 0;

   int n = PositionsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      int      dir        = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double   entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime entryTime  = (datetime)PositionGetInteger(POSITION_TIME);

      int idx = ArraySize(g_entries);
      ArrayResize(g_entries, idx + 1);
      g_entries[idx].ticket        = ticket;
      g_entries[idx].dir           = dir;
      g_entries[idx].entryPrice    = entryPrice;
      g_entries[idx].entryTime     = entryTime;
      g_entries[idx].mfe           = PositionGetDouble(POSITION_PROFIT);
      g_entries[idx].mae           = PositionGetDouble(POSITION_PROFIT);
      g_entries[idx].partialClosed = false;

      if(firstTime == 0 || entryTime < firstTime) firstTime = entryTime;
      if(entryTime > lastTime) lastTime = entryTime;
      recovered++;
     }

   if(recovered == 0) return;

   g_batchActive         = true;
   g_batchFirstEntryTime = firstTime;
   g_batchLastEntryTime  = lastTime;

   if(InpEnableLog) PrintFormat("AjipIDM: Rebuilt tracking for %d pre-existing position(s) on restart.", recovered);
  }

//==================================================================
// GET TRACKED OPEN VOLUME — sum of POSITION_VOLUME across tracked positions
// matching dirFilter (1=BUY, -1=SELL). Partial closes already shrink this
// naturally, since they reduce POSITION_VOLUME on the same ticket.
//==================================================================
double GetTrackedOpenVolume(int dirFilter)
  {
   double total = 0.0;
   int    n     = ArraySize(g_entries);
   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].dir != dirFilter) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
      total += PositionGetDouble(POSITION_VOLUME);
     }
   return(total);
  }

//==================================================================
// MAX TOTAL LOTS REACHED — blocks a new InpFixedLot entry in direction `dir`
// if it would push that DIRECTION's tracked open volume above
// InpMaxTotalLots. Capped per-direction, independently — a full BUY side and
// a full SELL side can coexist, each up to InpMaxTotalLots on its own.
// Position COUNT is intentionally uncapped (this strategy can legitimately
// stack same-direction positions across reversal cycles) — volume is what
// determines actual $ exposure, so that's what gets capped.
//==================================================================
bool MaxTotalLotsReached(int dir)
  {
   if(InpMaxTotalLots <= 0.0) return(false);
   return(GetTrackedOpenVolume(dir) + InpFixedLot > InpMaxTotalLots + 0.0000001);
  }

//==================================================================
// HEDGE BLOCKED — with InpAllowHedging=false, refuses a new entry in
// direction `dir` (1=BUY, -1=SELL) while ANY tracked position on the
// OPPOSITE side is still open, so BUY and SELL never coexist.
//
// Needed for prop firms that list hedging as a forbidden strategy. Without
// it, overlap is routine rather than exceptional: this EA flips trend on
// every idm sweep and never closes the old side on reversal (exits run
// purely off partial close / batch / daily / session targets), so the new
// trend's entries land while the previous direction is still open.
//
// Deliberately BLOCKS the new entry instead of closing the opposite side —
// force-closing would realize a loss the strategy never chose to take. The
// old side still exits on its own terms; the new direction just waits.
//==================================================================
bool HedgeBlocked(int dir)
  {
   if(InpAllowHedging) return(false);
   return(GetTrackedOpenVolume(-dir) > 0.0);
  }

//==================================================================
// APPLY AGGREGATE SL FOR DIRECTION — helper for RecalculateAggregateSL.
// Sums volume of tracked, non-BE positions on ONE side (dir), then sizes a
// uniform points-distance from each of their own entry prices so that if
// every one of THEM gapped through its stop at once, their combined loss
// equals `budget`. See RecalculateAggregateSL for why each direction gets
// the FULL budget independently rather than splitting it.
//==================================================================
void ApplyAggregateSLForDirection(int dir, double budget, double valuePerPointPerLot)
  {
   int    n           = ArraySize(g_entries);
   double totalVolume = 0.0;
   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].dir != dir) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
      // partialClosed only means the VOLUME SPLIT succeeded — CheckPartialClose
      // sets it before attempting the breakeven PositionModify, so a broker
      // rejection on THAT step (bad tick reverting before the modify lands,
      // invalid stops, etc.) leaves partialClosed=true with SL still at 0.
      // Skip only positions that actually HAVE a protective stop right now;
      // anything still at 0 stays eligible for the budget-derived SL below,
      // regardless of how partialClosed reads.
      if(g_entries[i].partialClosed && PositionGetDouble(POSITION_SL) != 0.0) continue;
      totalVolume += PositionGetDouble(POSITION_VOLUME);
     }
   if(totalVolume <= 0.0) return;

   double slPoints = budget / (totalVolume * valuePerPointPerLot);
   if(slPoints <= 0.0) return;

   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].dir != dir) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
      if(g_entries[i].partialClosed && PositionGetDouble(POSITION_SL) != 0.0) continue;

      double entryPrice = g_entries[i].entryPrice;
      double newSl = (dir == 1)
                     ? NormalizeDouble(entryPrice - slPoints * g_point, g_digits)
                     : NormalizeDouble(entryPrice + slPoints * g_point, g_digits);

      double curSl = PositionGetDouble(POSITION_SL);
      if(MathAbs(curSl - newSl) < g_point * 0.5) continue; // already set

      if(!trade.PositionModify(g_entries[i].ticket, newSl, PositionGetDouble(POSITION_TP)))
        {
         if(InpEnableLog) PrintFormat("AjipIDM: Aggregate SL modify FAILED. Ticket=%I64u target SL=%.5f retcode=%d (%s)",
                     g_entries[i].ticket, newSl, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
     }
  }

//==================================================================
// RECALCULATE AGGREGATE SL — every tick (called from OnTick), distributes a
// shared risk budget across every tracked position that doesn't already
// have its own protective stop. Positions with partialClosed==true already
// sit at breakeven (see CheckPartialClose) — that's always at least as safe
// as any budget-derived SL, so they're left alone.
//
// Budget = the SMALLEST of InpBatchMaxLoss/InpDailyMaxLoss/InpFinalMaxLoss
// that's actually enabled (>0). Picking the smallest means the aggregate SL
// never sits looser than whichever circuit breaker is tightest.
//
// Calculated SEPARATELY per direction (BUY pool and SELL pool each get the
// FULL budget, not half each) — deliberately NOT netted together. A single
// price move can only hurt one side at a time: if price drops, only the BUY
// pool is at risk (SELL is floating into profit, not loss) and vice versa.
// Since the two sides' worst cases are mutually exclusive events, giving
// each side the full budget independently is the correct sizing for "worst
// loss from one directional move" — pooling both sides together (as an
// earlier version of this did) would double-count the hedge and make stops
// needlessly tight whenever BUY and SELL are open at the same time.
//
// This does NOT bound total loss across a whipsaw (SELL stopped out on an
// up-move, then a new BUY later stopped out on a down-move) — that's a
// sequential, not simultaneous, scenario, and stays covered by the netted,
// direction-agnostic CheckBatchCloseAll/CheckDailyCloseAll/
// CheckFinalMaxLossCloseAll (which run BEFORE this every tick — see OnTick).
//
// Note: `budget` itself is a static config comparison (min of the three
// input amounts), not netted against PnL already realized today/this batch
// — same caveat as before, and same reason those three checks remain the
// authoritative circuit breakers. This is a broker-side safety net for when
// they can't react in time (disconnect, gap, slippage on the close-all
// itself), not a replacement for them.
//==================================================================
void RecalculateAggregateSL()
  {
   double budget = GetTightestMaxLossBudget(); // AjipIDM_Trade.mqh — shared with RefreshTickSanity's PnL guard
   if(budget <= 0.0) return; // nothing configured — no budget to distribute, no SL applied

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return;

   double valuePerPointPerLot = (tickValue / tickSize) * g_point;
   if(valuePerPointPerLot <= 0.0) return;

   ApplyAggregateSLForDirection(1,  budget, valuePerPointPerLot);  // BUY pool
   ApplyAggregateSLForDirection(-1, budget, valuePerPointPerLot);  // SELL pool
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
//
// Gated on InNewsBlackout() — this locks in profit, so it's paused during
// the news window like every other profit-side action (see AjipIDM_News.mqh).
// Deliberately NOT gated on session/daily-limit — those aren't news-related.
//==================================================================
void CheckPartialClose()
  {
   if(InpPartialClosePoints <= 0) return;
   if(InNewsBlackout()) return;

   int n = ArraySize(g_entries);
   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].partialClosed) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

      double entryPrice = g_entries[i].entryPrice;
      // Sanitized (spike-guarded) Bid/Ask — see RefreshTickSanity, AjipIDM_Trade.mqh.
      // A single corrupt tick here is exactly what triggered a false partial
      // close on a live demo account (139874 "points" of phantom profit).
      double curPrice   = (g_entries[i].dir == 1) ? g_saneBid : g_saneAsk;

      double profitPoints = (g_entries[i].dir == 1)
                             ? (curPrice - entryPrice) / g_point
                             : (entryPrice - curPrice) / g_point;

      if(profitPoints < InpPartialClosePoints) continue;

      double posVolume   = PositionGetDouble(POSITION_VOLUME);
      double closeVolume = posVolume * (InpPartialClosePercent / 100.0);
      closeVolume = MathFloor(closeVolume / g_volStep) * g_volStep;

      double remainder = posVolume - closeVolume;
      if(closeVolume < g_volMin || remainder < g_volMin)
        {
         // Deterministic — posVolume won't grow on its own, so this will
         // never succeed later either. Safe to give up permanently here.
         g_entries[i].partialClosed = true;
         if(InpEnableLog) PrintFormat("AjipIDM: Partial close skip — ticket=%I64u volume=%.2f too small to split at %.0f%%",
                     g_entries[i].ticket, posVolume, InpPartialClosePercent);
         continue;
        }

      if(!trade.PositionClosePartial(g_entries[i].ticket, closeVolume))
        {
         // NOT marked done — broker rejection (requote, trade context busy,
         // temporary connectivity) is often transient. Leaving partialClosed
         // false lets this retry next tick instead of riding un-split
         // forever off one failed attempt.
         if(InpEnableLog) PrintFormat("AjipIDM: Partial close FAILED, will retry. Ticket=%I64u retcode=%d (%s)",
                     g_entries[i].ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
         continue;
        }

      g_entries[i].partialClosed = true; // now genuinely done — the split succeeded

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
//
// Once hit, status stays HIT for the rest of the day (realized PnL doesn't
// un-cross the threshold), so this keeps firing every tick — CloseAllAndFlushBatch
// itself is already idempotent once flat (see FlushBatchIfDone). The handoff
// signal (InpHandoffEnabled) needs its OWN one-shot guard on top of that,
// keyed per day, so it's written exactly once per day, not spammed every
// tick for the rest of the day.
//==================================================================
void CheckDailyCloseAll()
  {
   double            total  = GetDailyPnL() + GetFloatingPnL();
   ENUM_LIMIT_STATUS status = ClassifyLimitStatus(total, InpDailyMaxProfit, InpDailyMaxLoss);

   if(status == LIMIT_STATUS_TARGET_HIT)
     {
      // Profit side only — paused during news like every other profit-taking
      // action. LIMIT_STATUS_MAXLOSS_HIT below is the kill switch and stays
      // active regardless; the two are mutually exclusive so returning here
      // never skips a loss check that would otherwise have fired this tick.
      if(InNewsBlackout()) return;

      if(InpEnableLog) PrintFormat("AjipIDM: Daily TARGET reached (%.2f >= %.2f) — closing all positions.",
                  total, InpDailyMaxProfit);
      CloseAllAndFlushBatch("DAILY_TARGET");

      static datetime lastHandoffDayProfit = 0;
      datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
      if(lastHandoffDayProfit != today)
        {
         lastHandoffDayProfit = today;
         WriteHandoffSignal("DAILY_TARGET", total);
        }
     }
   else if(status == LIMIT_STATUS_MAXLOSS_HIT)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: Daily MAX LOSS reached (%.2f <= -%.2f) — closing all positions.",
                  total, InpDailyMaxLoss);
      CloseAllAndFlushBatch("DAILY_MAX_LOSS");

      static datetime lastHandoffDayLoss = 0;
      datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
      if(lastHandoffDayLoss != today)
        {
         lastHandoffDayLoss = today;
         WriteHandoffSignal("DAILY_MAX_LOSS", total);
        }
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

   // HtfPrevSwingBodyBroken logs its own verdict (prev/cur swing + watchLevel
   // detail) on both outcomes — no need to duplicate a generic line here.
   if(!HtfPrevSwingBodyBroken(isBuy))
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — HTF previous %s only swept, not body-broken (see check above)",
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

   // Same value drawn on the chart — see GetHtfEquilibrium (AjipIDM_HtfContext.mqh).
   // It derives `reference` from g_htfTrend, which the first check above already
   // pinned to match isBuy, so this is identical to the inline formula it replaced.
   double equilibrium = GetHtfEquilibrium();
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
// CHECK AGGRESSIVE IDM TOUCH (per-tick, bar NOT closed yet) — REVERSAL ONLY.
// InpUseAggressiveEntry mode: the instant price touches/sweeps the FULL LTF
// idm level intrabar, reverse the LTF structure RIGHT NOW using the last
// CLOSED bar as boundary (NOT the still-forming touch bar) — origin +
// retroactive structure are built purely from final bar data, so there's no
// repaint risk.
//
// Entry is fully decoupled from this reversal — see CheckAggressiveZoneEntry
// below, which fires off the looser g_idmZonePrice boundary independently
// and doesn't need this reversal to have happened yet (it's usually reached
// LATER, as price continues past the zone toward the full sweep).
//
// The still-forming touch bar itself is untouched here; once it actually
// closes, it flows through the normal UpdateStructure() path in OnTick
// like any other bar, extending the LTF structure further.
//
// Guarded by g_aggressiveFiredBarTime so only ONE early reversal fires per
// forming bar, even if price oscillates around idm multiple times.
//==================================================================
void CheckAggressiveIdmTouch()
  {
   if(!InpUseAggressiveEntry) return;
   if(g_idmTaken) return;
   if(g_idmPrice <= 0.0) return;
   if(g_initMode) return;
   // Require a CONFIRMED idm (opposite swing after it) before allowing an
   // aggressive structural reversal. A dangling single-swing origin (just
   // after a reversal, g_idmConfirmed=false) can get re-swept by a single
   // wick with zero real structure behind it, causing immediate flip-flop
   // reversals. CheckAggressiveZoneEntry already requires this for entries;
   // mirror it here for reversals too.
   if(!g_idmConfirmed) return;

   // Touch uses Bid — matches the Bid-based OHLC series g_idmPrice is derived
   // from. Sanitized (spike-guarded), see RefreshTickSanity (AjipIDM_Trade.mqh)
   // — this is a structural REVERSAL trigger, a false fire off a bad tick
   // would corrupt g_trend/g_swings, not just close one position.
   double bid = g_saneBid;
   bool touchBuy  = (g_trend == TREND_UP   && bid < g_idmPrice);
   bool touchSell = (g_trend == TREND_DOWN && bid > g_idmPrice);
   if(!touchBuy && !touchSell) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpTimeframe, 0, 2, rates) < 2) return;

   if(rates[0].time == g_aggressiveFiredBarTime) return; // already fired for this forming bar

   double oldIdm = g_idmPrice; // LTF level being swept — for logging only
   g_aggressiveFiredBarTime = rates[0].time;

   // Detailed diagnostic: bid + full OHLC of both the last CLOSED bar (the
   // reversal boundary) and the still-FORMING bar (where the sweep tick
   // happened) — enough to reconstruct the exact price path without needing
   // to cross-reference chart candles by hand.
   if(InpEnableLog) PrintFormat("AjipIDM: AGGRESSIVE %s idm touch @ %.5f (bid=%.5f) — reversing early. "
               "LastClosed[%s O=%.5f H=%.5f L=%.5f C=%.5f] Forming[%s O=%.5f H=%.5f L=%.5f so-far]",
               touchBuy ? "BUY" : "SELL", oldIdm, bid,
               TimeToString(rates[1].time), rates[1].open, rates[1].high, rates[1].low, rates[1].close,
               TimeToString(rates[0].time), rates[0].open, rates[0].high, rates[0].low);

   // rates[1] = last CLOSED bar (NOT the forming touch bar) — keeps origin
   // scan + retroactive rebuild on final data only.
   if(touchBuy)
      ReverseToDowntrend(rates[1]);
   else
      ReverseToUptrend(rates[1]);
  }

//==================================================================
// CHECK AGGRESSIVE ZONE ENTRY (per-tick) — ENTRY, decoupled from reversal.
// Fires the instant price touches the idm bar's OPPOSITE extreme
// (g_idmZonePrice) — a looser boundary than the full idm sweep
// (g_idmPrice), reached FIRST as price retraces toward it. Independent of
// CheckAggressiveIdmTouch/CheckIdmTaken — may fire before, after, or
// without that reversal ever happening for this level. One-shot per idm
// level (keyed on g_idmTime), shared with CheckIdmZoneEntry so only ONE
// entry fires per level regardless of which path catches it first.
//==================================================================
void CheckAggressiveZoneEntry()
  {
   if(!InpUseAggressiveEntry) return;
   if(g_idmZonePrice <= 0.0) return;
   if(!g_idmConfirmed) return; // dangling origin right after a reversal — not a real idm yet
   if(g_initMode) return;
   if(g_idmZoneEntryFiredTime == g_idmTime) return; // already entered for this idm level

   // Touch uses Bid — same convention as CheckAggressiveIdmTouch. Sanitized
   // (spike-guarded), see RefreshTickSanity (AjipIDM_Trade.mqh).
   double bid = g_saneBid;
   bool touchBuy  = (g_trend == TREND_UP   && bid <= g_idmZonePrice);
   bool touchSell = (g_trend == TREND_DOWN && bid >= g_idmZonePrice);
   if(!touchBuy && !touchSell) return;

   if(FinalTargetReached()) return;
   if(FinalMaxLossReached()) return;
   if(DailyLimitReached()) return;
   if(MaxTotalLotsReached(touchBuy ? 1 : -1)) return;
   if(HedgeBlocked(touchBuy ? 1 : -1)) return; // silent: per-tick path, would spam
   if(BatchCooldownActive()) return;
   if(!InSession()) return;
   if(InNewsBlackout()) return;

   // Sanitized Ask/Bid — same cached reading the touch check above just used,
   // not a fresh SymbolInfoTick call. Feeds HtfEntryAllowed's equilibrium
   // math and OpenTrade's logged "Signal=" price; the actual order still gets
   // its own fresh broker tick at execution (CTrade internals) either way.
   bool   isBuy         = touchBuy;
   double entryEstimate = isBuy ? g_saneAsk : g_saneBid;

   if(!HtfEntryAllowed(isBuy, entryEstimate)) return;

   g_idmZoneEntryFiredTime = g_idmTime; // one-shot, set before OpenTrade

   if(InpEnableLog) PrintFormat("AjipIDM: AGGRESSIVE ZONE %s touch @ %.5f (idm zone=%.5f) — entering.",
               isBuy ? "BUY" : "SELL", bid, g_idmZonePrice);

   ulong ticket = OpenTrade(isBuy, entryEstimate);
   if(ticket > 0)
      AddEntry(ticket, isBuy ? 1 : -1);
  }

//==================================================================
// CHECK IDM TAKEN (bar-close) — REVERSAL ONLY. Fires unconditionally
// whenever the FULL idm level is swept intrabar (bar.low/bar.high crosses
// g_idmPrice), regardless of where the bar closes — exactly as before.
// Entry is fully decoupled now — see CheckIdmZoneEntry below, which fires
// independently off the looser g_idmZonePrice boundary and doesn't need
// this reversal to have happened yet.
// Uptrend: candle low < idm(SLU_last) → idm taken
// Downtrend: candle high > idm(SHD_last) → idm taken
//==================================================================
void CheckIdmTaken(MqlRates &bar)
  {
   if(g_idmTaken) return;
   if(g_idmPrice <= 0.0) return;

   bool taken = false;

   if(g_trend == TREND_UP)
     {
      // idm = last SLU. Taken when low penetrates below it.
      if(bar.low < g_idmPrice) taken = true;
     }
   else if(g_trend == TREND_DOWN)
     {
      // idm = last SHD. Taken when high penetrates above it.
      if(bar.high > g_idmPrice) taken = true;
     }

   if(!taken) return;

   g_idmTaken = true;

   if(InpEnableLog) PrintFormat("AjipIDM: IDM TAKEN. Trend was %s, idm=%.5f, bar close=%.5f",
               TrendString(g_trend), g_idmPrice, bar.close);

   if(g_trend == TREND_UP)
      // Trend changes to DOWN. Build downtrend from last SHU (= SHD0).
      ReverseToDowntrend(bar);
   else if(g_trend == TREND_DOWN)
      // Trend changes to UP. Build uptrend from last SLD (= SLU0).
      ReverseToUptrend(bar);
  }

//==================================================================
// CHECK IDM ZONE ENTRY (bar-close) — ENTRY, decoupled from reversal.
// Mirrors CheckAggressiveZoneEntry but evaluated once per closed bar using
// bar.low/bar.high instead of a live tick. Looser than the old sweep-based
// trigger: only needs bar.low/bar.high to reach the idm bar's OPPOSITE
// extreme (g_idmZonePrice), not the full idm level — but still requires the
// close to hold on the favorable side of the full idm level (g_idmPrice),
// same invalidation as the old "no body break" check. One-shot per idm
// level (keyed on g_idmTime), shared with CheckAggressiveZoneEntry.
// Uptrend:   bar.low  < idm-bar.high  AND bar.close > idm.low  → BUY
// Downtrend: bar.high > idm-bar.low   AND bar.close < idm.high → SELL
//==================================================================
void CheckIdmZoneEntry(MqlRates &bar)
  {
   if(g_idmZonePrice <= 0.0) return;
   if(!g_idmConfirmed) return; // dangling origin right after a reversal — not a real idm yet
   if(g_initMode) return;
   if(g_idmZoneEntryFiredTime == g_idmTime) return; // already entered for this idm level

   bool doEntry  = false;
   bool entryBuy = false;

   if(g_trend == TREND_UP)
     {
      if(bar.low < g_idmZonePrice && bar.close > g_idmPrice)
        {
         doEntry  = true;
         entryBuy = true;
        }
     }
   else if(g_trend == TREND_DOWN)
     {
      if(bar.high > g_idmZonePrice && bar.close < g_idmPrice)
        {
         doEntry  = true;
         entryBuy = false;
        }
     }

   if(!doEntry) return;

   if(FinalTargetReached())
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — final profit target reached.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(FinalMaxLossReached())
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — final max loss reached.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(DailyLimitReached())
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — daily limit reached.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(MaxTotalLotsReached(entryBuy ? 1 : -1))
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — max total lots reached.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(HedgeBlocked(entryBuy ? 1 : -1))
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — hedging disabled, %.2f lots still open on the opposite side.",
                  entryBuy ? "BUY" : "SELL", GetTrackedOpenVolume(entryBuy ? -1 : 1));
      return;
     }
   if(BatchCooldownActive())
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — batch cooldown active.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(!InSession())
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — outside trading session.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(InNewsBlackout())
     {
      if(InpEnableLog) PrintFormat("AjipIDM: %s skip — news blackout.", entryBuy ? "BUY" : "SELL");
      return;
     }
   if(!HtfEntryAllowed(entryBuy, bar.close)) return;

   g_idmZoneEntryFiredTime = g_idmTime;

   ulong ticket = OpenTrade(entryBuy, bar.close);
   if(ticket > 0)
      AddEntry(ticket, entryBuy ? 1 : -1);
  }

//==================================================================

#endif // AJIPIDM_ENTRY_MQH
