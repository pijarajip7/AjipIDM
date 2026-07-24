#ifndef AJIPIDM_REVERSAL_MQH
#define AJIPIDM_REVERSAL_MQH

// REVERSE TO DOWNTREND
// idm taken from uptrend. New origin = last SHU.
//==================================================================
void ReverseToDowntrend(MqlRates &takenBar)
  {
   // Find last SHU
   double originPrice = 0.0;
   datetime originTime = 0;
   int n = ArraySize(g_swings);

   for(int i = n - 1; i >= 0; i--)
     {
      if(g_swings[i].isHigh)
        {
         originPrice = g_swings[i].price;
         originTime  = g_swings[i].time;
         break;
        }
     }

   if(originPrice <= 0.0)
     {
      Print("AjipIDM: ReverseToDowntrend — no SHU origin found!");
      return;
     }

   // Switch trend
   g_trend = TREND_DOWN;

   // Reset structure: SHD0 = last SHU
   ResetSwings();
   ResetPbSwings();
   AddPbSwing(originPrice, originTime, true);

   // Init pullback: after SH origin, price goes DOWN
   g_phase = PHASE_DOWN;

   // Init g_base from origin bar OHLC directly (don't replay origin)
   MqlRates orgBar[];
   ArraySetAsSeries(orgBar, true);
   if(CopyRates(_Symbol, InpTimeframe, originTime, 1, orgBar) > 0)
     {
      g_base.high  = orgBar[0].high;
      g_base.low   = orgBar[0].low;
      g_base.time  = orgBar[0].time;
      g_base.valid = true;
     }
   g_outsidePending = false;

   // Reset idm taken BEFORE replay so mid-replay reverses can fire.
   // If we leave g_idmTaken=true, CheckIdmTaken inside RebuildStructure
   // returns early → mid-replay reversal events are lost → wrong structure/idm.
   g_idmTaken = false;

   // Rebuild from bars AFTER origin (origin+1 ... takenBar)
   RebuildStructure(originTime, takenBar.time);

   // Update idm for new trend
   UpdateIdm();

   PrintFormat("AjipIDM: Reversed to DOWN. Origin SHD0=%.5f@%s, swings=%d",
               originPrice, TimeToString(originTime), ArraySize(g_swings));

   if(InpDrawLines) DrawSwings();
  }

//==================================================================
// REVERSE TO UPTREND
// idm taken from downtrend. New origin = last SLD.
//==================================================================
void ReverseToUptrend(MqlRates &takenBar)
  {
   // Find last SLD
   double originPrice = 0.0;
   datetime originTime = 0;
   int n = ArraySize(g_swings);

   for(int i = n - 1; i >= 0; i--)
     {
      if(!g_swings[i].isHigh)
        {
         originPrice = g_swings[i].price;
         originTime  = g_swings[i].time;
         break;
        }
     }

   if(originPrice <= 0.0)
     {
      Print("AjipIDM: ReverseToUptrend — no SLD origin found!");
      return;
     }

   // Switch trend
   g_trend = TREND_UP;

   // Reset structure: SLU0 = last SLD
   ResetSwings();
   ResetPbSwings();
   AddPbSwing(originPrice, originTime, false);

   // Init pullback: after SL origin, price goes UP
   g_phase = PHASE_UP;

   // Init g_base from origin bar OHLC directly (don't replay origin)
   MqlRates orgBar[];
   ArraySetAsSeries(orgBar, true);
   if(CopyRates(_Symbol, InpTimeframe, originTime, 1, orgBar) > 0)
     {
      g_base.high  = orgBar[0].high;
      g_base.low   = orgBar[0].low;
      g_base.time  = orgBar[0].time;
      g_base.valid = true;
     }
   g_outsidePending = false;

   // Reset idm taken BEFORE replay so mid-replay reverses can fire.
   g_idmTaken = false;

   // Rebuild from bars AFTER origin
   RebuildStructure(originTime, takenBar.time);

   // Update idm for new trend
   UpdateIdm();

   PrintFormat("AjipIDM: Reversed to UP. Origin SLU0=%.5f@%s, swings=%d",
               originPrice, TimeToString(originTime), ArraySize(g_swings));

   if(InpDrawLines) DrawSwings();
  }

//==================================================================
// REBUILD STRUCTURE
// Fetch all bars between originTime and endTime, replay them.
//==================================================================
void RebuildStructure(datetime originTime, datetime endTime)
  {
   int originShift = iBarShift(_Symbol, InpTimeframe, originTime);
   int endShift    = iBarShift(_Symbol, InpTimeframe, endTime);

   if(originShift < 0 || endShift < 0 || originShift < endShift)
     {
      PrintFormat("AjipIDM: RebuildStructure bad shifts origin=%d end=%d",
                  originShift, endShift);
      return;
     }

   // originShift > endShift (series: 0=newest).
   // Fetch bars between origin (exclusive) and takenBar (inclusive).
   // Use start_pos=originShift (older), count bars forward toward newer.
   // CopyRates with ArraySetAsSeries(false): rates[0]=oldest, rates[last]=newest.
   // But we skip origin bar itself → start from originShift-1.
   int count = originShift - endShift; // bars from originShift-1 to endShift
   if(count <= 0) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, false); // chronological: oldest → newest
   int copied = CopyRates(_Symbol, InpTimeframe, endShift, count, rates);
   if(copied <= 0) return;

   // Verify we got the right bars: rates[0] should be oldest (near origin)
   // rates[copied-1] should be newest (= takenBar/endShift)

   // LIVE replay: process each bar fully (pullback + structure + idm + reversal).
   // CheckIdmTaken may trigger ReverseToDowntrend/Up → recursive RebuildStructure.
   // g_initMode suppresses entries during replay (structural processing only).
   // Without this, a reversal event mid-range is lost → wrong trend/idm going forward.
   bool savedInitMode = g_initMode;
   g_initMode = true;
   for(int i = 0; i < copied; i++)
     {
      DetectPullback(rates[i]);
      BuildSimpleStructure();
      UpdateIdm();
      if(g_idmPrice > 0.0)
         CheckIdmTaken(rates[i]);
     }
   // Final build + idm after all bars processed
   BuildSimpleStructure();
   UpdateIdm();
   g_initMode = savedInitMode;

   // Debug
   int npb = ArraySize(g_pbSwings);
   int nsw = ArraySize(g_swings);
   PrintFormat("AjipIDM: RebuildStructure done. pbSwings=%d, swings=%d, bars_replayed=%d",
               npb, nsw, copied);
   for(int i = 0; i < npb; i++)
      PrintFormat("  pbSwing[%d]: price=%.5f time=%s isHigh=%s",
                  i, g_pbSwings[i].price, TimeToString(g_pbSwings[i].time),
                  g_pbSwings[i].isHigh ? "true" : "false");
   for(int i = 0; i < nsw; i++)
      PrintFormat("  swing[%d]: price=%.5f time=%s isHigh=%s",
                  i, g_swings[i].price, TimeToString(g_swings[i].time),
                  g_swings[i].isHigh ? "true" : "false");
  }

#endif // AJIPIDM_REVERSAL_MQH
