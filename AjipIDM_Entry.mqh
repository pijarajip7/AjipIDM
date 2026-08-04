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
      if(g_entries[i].partialClosed) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
      totalVolume += PositionGetDouble(POSITION_VOLUME);
     }
   if(totalVolume <= 0.0) return;

   double slPoints = budget / (totalVolume * valuePerPointPerLot);
   if(slPoints <= 0.0) return;

   for(int i = 0; i < n; i++)
     {
      if(g_entries[i].dir != dir) continue;
      if(g_entries[i].partialClosed) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

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
   double budget = -1.0;
   if(InpBatchMaxLoss > 0.0) budget = InpBatchMaxLoss;
   if(InpDailyMaxLoss > 0.0) budget = (budget < 0.0) ? InpDailyMaxLoss : MathMin(budget, InpDailyMaxLoss);
   if(InpFinalMaxLoss > 0.0) budget = (budget < 0.0) ? InpFinalMaxLoss : MathMin(budget, InpFinalMaxLoss);
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

   // Touch uses Bid — matches the Bid-based OHLC series g_idmPrice is derived from.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool touchBuy  = (g_trend == TREND_UP   && bid < g_idmPrice);
   bool touchSell = (g_trend == TREND_DOWN && bid > g_idmPrice);
   if(!touchBuy && !touchSell) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpTimeframe, 0, 2, rates) < 2) return;

   if(rates[0].time == g_aggressiveFiredBarTime) return; // already fired for this forming bar

   double oldIdm = g_idmPrice; // LTF level being swept — for logging only
   g_aggressiveFiredBarTime = rates[0].time;

   if(InpEnableLog) PrintFormat("AjipIDM: AGGRESSIVE %s idm touch @ %.5f — reversing early using last closed bar as boundary.",
               touchBuy ? "BUY" : "SELL", oldIdm);

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

   // Touch uses Bid — same convention as CheckAggressiveIdmTouch.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool touchBuy  = (g_trend == TREND_UP   && bid <= g_idmZonePrice);
   bool touchSell = (g_trend == TREND_DOWN && bid >= g_idmZonePrice);
   if(!touchBuy && !touchSell) return;

   if(FinalTargetReached()) return;
   if(FinalMaxLossReached()) return;
   if(DailyLimitReached()) return;
   if(MaxTotalLotsReached(touchBuy ? 1 : -1)) return;
   if(BatchCooldownActive()) return;
   if(!InSession()) return;
   if(InNewsBlackout()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   bool   isBuy         = touchBuy;
   double entryEstimate = isBuy ? tick.ask : tick.bid;

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
