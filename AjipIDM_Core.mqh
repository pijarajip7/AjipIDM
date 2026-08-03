#ifndef AJIPIDM_CORE_MQH
#define AJIPIDM_CORE_MQH

// INIT STRUCTURE — build from lookback candles
//==================================================================
bool InitStructure()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false); // oldest → newest (chronological)
   int copied = CopyRates(_Symbol, InpTimeframe, 0, InpCandlesInit, rates);
   if(copied < 10)
     {
      if(InpEnableLog) PrintFormat("AjipIDM: Not enough bars for init (%d)", copied);
      return(false);
     }

   // Find highest high and lowest low
   int highIdx = 0, lowIdx = 0;
   double highest = rates[0].high;
   double lowest  = rates[0].low;

   for(int i = 1; i < copied; i++)
     {
      if(rates[i].high > highest)
        {
         highest = rates[i].high;
         highIdx = i;
        }
      if(rates[i].low < lowest)
        {
         lowest = rates[i].low;
         lowIdx = i;
        }
     }

   // Determine trend by chronological order
   int originIdx;
   if(highIdx < lowIdx)
     {
      // High occurred BEFORE low → downtrend
      g_trend = TREND_DOWN;
      originIdx = highIdx;
      if(InpEnableLog) PrintFormat("AjipIDM: Init DOWN. HH@%s (%.5f), LL@%s (%.5f)",
                  TimeToString(rates[highIdx].time), highest,
                  TimeToString(rates[lowIdx].time), lowest);
     }
   else
     {
      // Low occurred BEFORE high → uptrend
      g_trend = TREND_UP;
      originIdx = lowIdx;
      if(InpEnableLog) PrintFormat("AjipIDM: Init UP. LL@%s (%.5f), HH@%s (%.5f)",
                  TimeToString(rates[lowIdx].time), lowest,
                  TimeToString(rates[highIdx].time), highest);
     }

   // Init pullback from origin bar
   g_initMode = true; // skip entry during historical replay
   ResetSwings();
   ResetPbSwings();

   if(g_trend == TREND_DOWN)
     {
      // Downtrend origin = highest high; zonePrice = same bar's low
      AddPbSwing(highest, rates[originIdx].low, rates[originIdx].time, true);
     }
   else
     {
      // Uptrend origin = lowest low; zonePrice = same bar's high
      AddPbSwing(lowest, rates[originIdx].high, rates[originIdx].time, false);
     }
   g_base.high  = rates[originIdx].high;
   g_base.low   = rates[originIdx].low;
   g_base.time  = rates[originIdx].time;
   g_base.valid = true;
   g_phase      = (g_trend == TREND_DOWN) ? PHASE_DOWN : PHASE_UP;
   g_outsidePending = false;

   // Build forward from origin, processing each bar:
   // pullback detect → build structure → update idm → check reversal
   for(int i = originIdx + 1; i < copied - 1; i++)
     {
      DetectPullback(rates[i]);
      BuildSimpleStructure();
      UpdateIdm();
      if(g_idmPrice > 0.0)
         CheckIdmTaken(rates[i]);
     }

   // Final structure + idm
   BuildSimpleStructure();
   UpdateIdm();
   g_idmTaken = false;
   g_initMode = false; // back to live mode

   // Last CLOSED bar = rates[copied-2] (rates[copied-1] is the forming bar)
   g_lastBarTime = rates[copied - 2].time;

   if(InpEnableLog) PrintFormat("AjipIDM: Structure built. Trend=%s, Swings=%d, idm=%.5f",
               TrendString(g_trend), ArraySize(g_swings), g_idmPrice);

   if(InpDrawLines) DrawSwings();

   return(true);
  }

//==================================================================
// UPDATE STRUCTURE — 2-stage: pullback detection + simple structure build
//
// Stage 1 (PULLBACK): base_candle tracking with outside bar handling.
//   UP phase: base = highest-high candle. Bar low < base.low → pullback DOWN,
//             record HI = base.high. Bar high > base.high → continuation.
//   DOWN phase: base = lowest-low candle. Bar high > base.high → pullback UP,
//             record LO = base.low. Bar low < base.low → continuation.
//
// Stage 2 (SIMPLE STRUCTURE): running max/min from pullback swings + merge.
//   Uptrend:   SH must be HH, SL must be HL.
//   Downtrend: SH must be LH, SL must be LL.
//==================================================================
void UpdateStructure(MqlRates &bar)
  {
   //--- Stage 1: Pullback detection ---
   DetectPullback(bar);

   //--- Stage 2: Build simple structure from pullback swings ---
   BuildSimpleStructure();

   //--- Stage 3: Recalculate idm from current structure ---
   // Without this, g_idmPrice stays stale after init/reversal.
   // New swings form but idm never updates → CheckIdmTaken checks
   // against wrong level → idm taken not detected → no reversal.
   UpdateIdm();
  }

#endif // AJIPIDM_CORE_MQH
