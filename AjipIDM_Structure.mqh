#ifndef AJIPIDM_STRUCTURE_MQH
#define AJIPIDM_STRUCTURE_MQH

// BUILD SIMPLE STRUCTURE — running max/min from pullback swings + merge
//==================================================================
void BuildSimpleStructure()
  {
   int npb = ArraySize(g_pbSwings);

   // Rebuild g_swings from scratch
   ResetSwings();

   if(npb == 0) return;

   // Origin = first pullback swing (always committed)
   AddSwing(g_pbSwings[0].price, g_pbSwings[0].time, g_pbSwings[0].isHigh);
   // Track last committed index per type + last committed overall
   int lastSHIdx = -1;
   int lastSLIdx = -1;
   int lastIdx   = -1;

   if(g_pbSwings[0].isHigh) { lastSHIdx = 0; }
   else                     { lastSLIdx = 0; }
   lastIdx = 0;

   // Commit each pullback swing independently if trend rule satisfied
   for(int i = 1; i < npb; i++)
     {
      double price = g_pbSwings[i].price;
      datetime tm  = g_pbSwings[i].time;
      bool isHigh  = g_pbSwings[i].isHigh;

      // If same type as last committed → might be premature update
      if(isHigh == g_swings[lastIdx].isHigh)
        {
         // Premature: new price is more extreme than last same-type
         // SH: higher = old was premature local high
         // SL: lower  = old was premature local low
         bool premature = isHigh
            ? (price > g_swings[lastSHIdx].price)
            : (price < g_swings[lastSLIdx].price);
         if(premature)
           {
            // Pop the stale same-type swing. PopSwingAt shifts elements
            // left, which invalidates index positions for BOTH swing types
            // — not just the one popped. Recompute all three pointers.
            if(isHigh) PopSwingAt(lastSHIdx);
            else       PopSwingAt(lastSLIdx);

            lastSHIdx = -1;
            lastSLIdx = -1;
            lastIdx   = -1;
            int ns = ArraySize(g_swings);
            for(int j = ns - 1; j >= 0; j--)
              {
               if(g_swings[j].isHigh)  { if(lastSHIdx < 0) lastSHIdx = j; }
               else                     { if(lastSLIdx < 0) lastSLIdx = j; }
               if(lastIdx < 0) lastIdx = j; // last committed overall
              }
            // Fall through to normal commit below
           }
         else continue; // not premature, skip
        }

      if(g_trend == TREND_UP)
        {
         if(isHigh)
           {
            // SHU: commit if first SH or HH
            if(lastSHIdx < 0 || price > g_swings[lastSHIdx].price)
              {
               AddSwing(price, tm, true);
               lastSHIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSHIdx;
              }
           }
         else
           {
            // SLU: commit if first SL or HL
            if(lastSLIdx < 0 || price > g_swings[lastSLIdx].price)
              {
               AddSwing(price, tm, false);
               lastSLIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSLIdx;
              }
           }
        }
      else // TREND_DOWN
        {
         if(isHigh)
           {
            // SHD: commit if first SH or LH
            if(lastSHIdx < 0 || price < g_swings[lastSHIdx].price)
              {
               AddSwing(price, tm, true);
               lastSHIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSHIdx;
              }
           }
         else
           {
            // SLD: commit if first SL or LL
            if(lastSLIdx < 0 || price < g_swings[lastSLIdx].price)
              {
               AddSwing(price, tm, false);
               lastSLIdx = ArraySize(g_swings) - 1;
               lastIdx   = lastSLIdx;
              }
           }
        }
     }

   UpdateIdm();
  }

//==================================================================
// PULLBACK SWING ARRAY HELPERS
//==================================================================
void AddPbSwing(double price, datetime time, bool isHigh)
  {
   int n = ArraySize(g_pbSwings);
   ArrayResize(g_pbSwings, n + 1);
   g_pbSwings[n].price  = price;
   g_pbSwings[n].time   = time;
   g_pbSwings[n].isHigh = isHigh;
  }

void ResetPbSwings()
  {
   ArrayResize(g_pbSwings, 0);
  }

//==================================================================
// POP SWING AT INDEX (for g_swings)
//==================================================================
void PopSwingAt(int idx)
  {
   int n = ArraySize(g_swings);
   if(idx < 0 || idx >= n) return;

   for(int i = idx; i < n - 1; i++)
      g_swings[i] = g_swings[i + 1];
   ArrayResize(g_swings, n - 1);
  }

//==================================================================
// UPDATE IDM — set idm to last swing that HAS an opposite swing after it
// Uptrend:   idm = last SL that has a SH after it (not the dangling last SL)
// Downtrend: idm = last SH that has a SL after it (not the dangling last SH)
//==================================================================
void UpdateIdm()
  {
   int n = ArraySize(g_swings);
   if(n < 1)
     {
      g_idmPrice = 0.0;
      return;
     }
   if(n == 1)
     {
      // Origin is always the initial idm
      g_idmPrice = g_swings[0].price;
      return;
     }

   if(g_trend == TREND_UP)
     {
      // Walk backwards: find last SL that has a SH after it
      for(int i = n - 2; i >= 0; i--) // start at n-2 (second to last)
        {
         if(!g_swings[i].isHigh) // this is an SL
           {
            // Check there's a SH after it
            g_idmPrice = g_swings[i].price;
            return;
           }
        }
     }
   else if(g_trend == TREND_DOWN)
     {
      // Walk backwards: find last SH that has a SL after it
      for(int i = n - 2; i >= 0; i--)
        {
         if(g_swings[i].isHigh) // this is a SH
           {
            g_idmPrice = g_swings[i].price;
            return;
           }
        }
     }

   g_idmPrice = 0.0;
  }

#endif // AJIPIDM_STRUCTURE_MQH
