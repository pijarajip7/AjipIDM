#ifndef AJIPIDM_PULLBACK_MQH
#define AJIPIDM_PULLBACK_MQH

// DETECT PULLBACK — base_candle zigzag (Stage 1)
//
// Normal mode:
//   PHASE_UP: continuation (higher high) or pullback (low breaks base low)
//   PHASE_DOWN: continuation (lower low) or pullback (high breaks base high)
//
// Outside bar mode (bar breaks BOTH base.high AND base.low):
//   - Store as g_outsideBar, set g_outsidePending = true
//   - Don't record swing yet — wait for next bar to resolve:
//     PHASE_UP:
//       next breaks outside.high → continuation UP, commit outside.low as SL
//       next breaks outside.low  → reversal DOWN, commit outside.high as SH
//     PHASE_DOWN:
//       next breaks outside.low  → continuation DOWN, commit outside.high as SH
//       next breaks outside.high → reversal UP, commit outside.low as SL
//==================================================================
void DetectPullback(MqlRates &bar)
  {
   if(!g_base.valid)
     {
      // First bar: init base
      g_base.high  = bar.high;
      g_base.low   = bar.low;
      g_base.time  = bar.time;
      g_base.valid = true;
      return;
     }

   //--- Outside bar pending resolution ---
   if(g_outsidePending)
     {
      if(g_phase == PHASE_UP)
        {
         if(bar.high > g_outsideBar.high)
           {
            // Continuation UP: commit outside.low as SL, resolving bar = new base
            AddPbSwing(g_outsideBar.low, g_outsideBar.time, false);
            g_outsidePending = false;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else if(bar.low < g_outsideBar.low)
           {
            // Reversal DOWN: commit outside.high as SH
            AddPbSwing(g_outsideBar.high, g_outsideBar.time, true);
            g_outsidePending = false;
            g_phase = PHASE_DOWN;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else
           {
            // Neither extreme broken yet → keep waiting
            // Update outside bar if new bar extends it
            if(bar.high > g_outsideBar.high || bar.low < g_outsideBar.low)
              {
               g_outsideBar.high = MathMax(g_outsideBar.high, bar.high);
               g_outsideBar.low  = MathMin(g_outsideBar.low,  bar.low);
               g_outsideBar.time = bar.time;
              }
           }
        }
      else // PHASE_DOWN
        {
         if(bar.low < g_outsideBar.low)
           {
            // Continuation DOWN: commit outside.high as SH
            AddPbSwing(g_outsideBar.high, g_outsideBar.time, true);
            g_outsidePending = false;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else if(bar.high > g_outsideBar.high)
           {
            // Reversal UP: commit outside.low as SL
            AddPbSwing(g_outsideBar.low, g_outsideBar.time, false);
            g_outsidePending = false;
            g_phase = PHASE_UP;
            g_base.high = bar.high;
            g_base.low  = bar.low;
            g_base.time = bar.time;
           }
         else
           {
            // Neither extreme broken yet → keep waiting
            if(bar.high > g_outsideBar.high || bar.low < g_outsideBar.low)
              {
               g_outsideBar.high = MathMax(g_outsideBar.high, bar.high);
               g_outsideBar.low  = MathMin(g_outsideBar.low,  bar.low);
               g_outsideBar.time = bar.time;
              }
           }
        }
      return;
     }

   //--- Check for outside bar (breaks BOTH extremes) ---
   bool isOutside = (bar.high > g_base.high && bar.low < g_base.low);

   if(isOutside)
     {
      g_outsidePending = true;
      g_outsideBar.high  = bar.high;
      g_outsideBar.low   = bar.low;
      g_outsideBar.time  = bar.time;
      g_outsideBar.valid = true;
      PrintFormat("AjipIDM: Outside bar detected. Phase=%s high=%.5f low=%.5f — pending resolution",
                  g_phase == PHASE_UP ? "UP" : "DOWN", bar.high, bar.low);
      return;
     }

   //--- Normal pullback detection (no outside bar) ---
   if(g_phase == PHASE_UP)
     {
      // Continuation: bar makes higher high → becomes new base
      if(bar.high > g_base.high)
        {
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
      // Pullback DOWN: bar low breaks base low → record HI, switch phase
      else if(bar.low < g_base.low)
        {
         AddPbSwing(g_base.high, g_base.time, true);
         g_phase = PHASE_DOWN;
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
     }
   else // PHASE_DOWN
     {
      // Continuation: bar makes lower low → becomes new base
      if(bar.low < g_base.low)
        {
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
      // Pullback UP: bar high breaks base high → record LO, switch phase
      else if(bar.high > g_base.high)
        {
         AddPbSwing(g_base.low, g_base.time, false);
         g_phase = PHASE_UP;
         g_base.high = bar.high;
         g_base.low  = bar.low;
         g_base.time = bar.time;
        }
     }
  }

#endif // AJIPIDM_PULLBACK_MQH
