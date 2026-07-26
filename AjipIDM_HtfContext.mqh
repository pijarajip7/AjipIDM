#ifndef AJIPIDM_HTFCONTEXT_MQH
#define AJIPIDM_HTFCONTEXT_MQH

// HTF CONTEXT — trimmed structure/idm engine for the higher timeframe.
// Ported from AjipIDM_Pullback/Structure/Reversal/Entry/Core.mqh, same
// rules, operating on g_htf* globals + InpHtfTimeframe. Structure/idm
// tracking only — never places trades, never invalidates, never checks
// daily limits. It does draw its own swing/idm lines (DrawHtfSwings, own
// object prefix) for visualization.
//==================================================================

// HTF DETECT PULLBACK — port of DetectPullback (AjipIDM_Pullback.mqh)
//==================================================================
void HtfDetectPullback(MqlRates &bar)
  {
   if(!g_htfBase.valid)
     {
      g_htfBase.high  = bar.high;
      g_htfBase.low   = bar.low;
      g_htfBase.time  = bar.time;
      g_htfBase.valid = true;
      return;
     }

   //--- Outside bar pending resolution ---
   if(g_htfOutsidePending)
     {
      if(g_htfPhase == PHASE_UP)
        {
         if(bar.high > g_htfOutsideBar.high)
           {
            HtfAddPbSwing(g_htfOutsideBar.low, g_htfOutsideBar.time, false);
            g_htfOutsidePending = false;
            g_htfBase.high = bar.high;
            g_htfBase.low  = bar.low;
            g_htfBase.time = bar.time;
           }
         else if(bar.low < g_htfOutsideBar.low)
           {
            HtfAddPbSwing(g_htfOutsideBar.high, g_htfOutsideBar.time, true);
            g_htfOutsidePending = false;
            g_htfPhase = PHASE_DOWN;
            g_htfBase.high = bar.high;
            g_htfBase.low  = bar.low;
            g_htfBase.time = bar.time;
           }
         else
           {
            if(bar.high > g_htfOutsideBar.high || bar.low < g_htfOutsideBar.low)
              {
               g_htfOutsideBar.high = MathMax(g_htfOutsideBar.high, bar.high);
               g_htfOutsideBar.low  = MathMin(g_htfOutsideBar.low,  bar.low);
               g_htfOutsideBar.time = bar.time;
              }
           }
        }
      else // PHASE_DOWN
        {
         if(bar.low < g_htfOutsideBar.low)
           {
            HtfAddPbSwing(g_htfOutsideBar.high, g_htfOutsideBar.time, true);
            g_htfOutsidePending = false;
            g_htfBase.high = bar.high;
            g_htfBase.low  = bar.low;
            g_htfBase.time = bar.time;
           }
         else if(bar.high > g_htfOutsideBar.high)
           {
            HtfAddPbSwing(g_htfOutsideBar.low, g_htfOutsideBar.time, false);
            g_htfOutsidePending = false;
            g_htfPhase = PHASE_UP;
            g_htfBase.high = bar.high;
            g_htfBase.low  = bar.low;
            g_htfBase.time = bar.time;
           }
         else
           {
            if(bar.high > g_htfOutsideBar.high || bar.low < g_htfOutsideBar.low)
              {
               g_htfOutsideBar.high = MathMax(g_htfOutsideBar.high, bar.high);
               g_htfOutsideBar.low  = MathMin(g_htfOutsideBar.low,  bar.low);
               g_htfOutsideBar.time = bar.time;
              }
           }
        }
      return;
     }

   //--- Check for outside bar (breaks BOTH extremes) ---
   bool isOutside = (bar.high > g_htfBase.high && bar.low < g_htfBase.low);

   if(isOutside)
     {
      g_htfOutsidePending = true;
      g_htfOutsideBar.high  = bar.high;
      g_htfOutsideBar.low   = bar.low;
      g_htfOutsideBar.time  = bar.time;
      g_htfOutsideBar.valid = true;
      return;
     }

   //--- Normal pullback detection (no outside bar) ---
   if(g_htfPhase == PHASE_UP)
     {
      if(bar.high > g_htfBase.high)
        {
         g_htfBase.high = bar.high;
         g_htfBase.low  = bar.low;
         g_htfBase.time = bar.time;
        }
      else if(bar.low < g_htfBase.low)
        {
         HtfAddPbSwing(g_htfBase.high, g_htfBase.time, true);
         g_htfPhase = PHASE_DOWN;
         g_htfBase.high = bar.high;
         g_htfBase.low  = bar.low;
         g_htfBase.time = bar.time;
        }
     }
   else // PHASE_DOWN
     {
      if(bar.low < g_htfBase.low)
        {
         g_htfBase.high = bar.high;
         g_htfBase.low  = bar.low;
         g_htfBase.time = bar.time;
        }
      else if(bar.high > g_htfBase.high)
        {
         HtfAddPbSwing(g_htfBase.low, g_htfBase.time, false);
         g_htfPhase = PHASE_UP;
         g_htfBase.high = bar.high;
         g_htfBase.low  = bar.low;
         g_htfBase.time = bar.time;
        }
     }
  }

//==================================================================
// HTF PULLBACK SWING ARRAY HELPERS
//==================================================================
void HtfAddPbSwing(double price, datetime time, bool isHigh)
  {
   int n = ArraySize(g_htfPbSwings);
   ArrayResize(g_htfPbSwings, n + 1);
   g_htfPbSwings[n].price  = price;
   g_htfPbSwings[n].time   = time;
   g_htfPbSwings[n].isHigh = isHigh;
  }

void HtfResetPbSwings()
  {
   ArrayResize(g_htfPbSwings, 0);
  }

//==================================================================
// HTF SWING ARRAY HELPERS
//==================================================================
void HtfResetSwings()
  {
   ArrayResize(g_htfSwings, 0);
  }

void HtfAddSwing(double price, datetime time, bool isHigh)
  {
   int n = ArraySize(g_htfSwings);
   ArrayResize(g_htfSwings, n + 1);
   g_htfSwings[n].price  = price;
   g_htfSwings[n].time   = time;
   g_htfSwings[n].isHigh = isHigh;
  }

void HtfPopSwingAt(int idx)
  {
   int n = ArraySize(g_htfSwings);
   if(idx < 0 || idx >= n) return;

   for(int i = idx; i < n - 1; i++)
      g_htfSwings[i] = g_htfSwings[i + 1];
   ArrayResize(g_htfSwings, n - 1);
  }

//==================================================================
// HTF BUILD SIMPLE STRUCTURE — port of BuildSimpleStructure
//==================================================================
void HtfBuildSimpleStructure()
  {
   int npb = ArraySize(g_htfPbSwings);

   HtfResetSwings();

   if(npb == 0) return;

   HtfAddSwing(g_htfPbSwings[0].price, g_htfPbSwings[0].time, g_htfPbSwings[0].isHigh);
   int lastSHIdx = -1;
   int lastSLIdx = -1;
   int lastIdx   = -1;

   if(g_htfPbSwings[0].isHigh) { lastSHIdx = 0; }
   else                        { lastSLIdx = 0; }
   lastIdx = 0;

   for(int i = 1; i < npb; i++)
     {
      double price = g_htfPbSwings[i].price;
      datetime tm  = g_htfPbSwings[i].time;
      bool isHigh  = g_htfPbSwings[i].isHigh;

      if(isHigh == g_htfSwings[lastIdx].isHigh)
        {
         bool premature = isHigh
            ? (price > g_htfSwings[lastSHIdx].price)
            : (price < g_htfSwings[lastSLIdx].price);
         if(premature)
           {
            // PopSwingAt shifts elements left, invalidating index positions
            // for BOTH swing types — recompute all three pointers.
            if(isHigh) HtfPopSwingAt(lastSHIdx);
            else       HtfPopSwingAt(lastSLIdx);

            lastSHIdx = -1;
            lastSLIdx = -1;
            lastIdx   = -1;
            int ns = ArraySize(g_htfSwings);
            for(int j = ns - 1; j >= 0; j--)
              {
               if(g_htfSwings[j].isHigh) { if(lastSHIdx < 0) lastSHIdx = j; }
               else                       { if(lastSLIdx < 0) lastSLIdx = j; }
               if(lastIdx < 0) lastIdx = j;
              }
           }
         else continue;
        }

      if(g_htfTrend == TREND_UP)
        {
         if(isHigh)
           {
            if(lastSHIdx < 0 || price > g_htfSwings[lastSHIdx].price)
              {
               HtfAddSwing(price, tm, true);
               lastSHIdx = ArraySize(g_htfSwings) - 1;
               lastIdx   = lastSHIdx;
              }
           }
         else
           {
            if(lastSLIdx < 0 || price > g_htfSwings[lastSLIdx].price)
              {
               HtfAddSwing(price, tm, false);
               lastSLIdx = ArraySize(g_htfSwings) - 1;
               lastIdx   = lastSLIdx;
              }
           }
        }
      else // TREND_DOWN
        {
         if(isHigh)
           {
            if(lastSHIdx < 0 || price < g_htfSwings[lastSHIdx].price)
              {
               HtfAddSwing(price, tm, true);
               lastSHIdx = ArraySize(g_htfSwings) - 1;
               lastIdx   = lastSHIdx;
              }
           }
         else
           {
            if(lastSLIdx < 0 || price < g_htfSwings[lastSLIdx].price)
              {
               HtfAddSwing(price, tm, false);
               lastSLIdx = ArraySize(g_htfSwings) - 1;
               lastIdx   = lastSLIdx;
              }
           }
        }
     }

   HtfUpdateIdm();
  }

//==================================================================
// HTF UPDATE IDM — port of UpdateIdm
//==================================================================
void HtfUpdateIdm()
  {
   int n = ArraySize(g_htfSwings);
   if(n < 1)
     {
      g_htfIdmPrice = 0.0;
      return;
     }
   if(n == 1)
     {
      g_htfIdmPrice = g_htfSwings[0].price;
      return;
     }

   // Walk from n-2 (skip last element which is always dangling/unconfirmed).
   if(g_htfTrend == TREND_UP)
     {
      for(int i = n - 2; i >= 0; i--)
        {
         if(!g_htfSwings[i].isHigh)
           {
            g_htfIdmPrice = g_htfSwings[i].price;
            return;
           }
        }
     }
   else if(g_htfTrend == TREND_DOWN)
     {
      for(int i = n - 2; i >= 0; i--)
        {
         if(g_htfSwings[i].isHigh)
           {
            g_htfIdmPrice = g_htfSwings[i].price;
            return;
           }
        }
     }

   g_htfIdmPrice = 0.0;
  }

//==================================================================
// HTF UPDATE STRUCTURE — port of UpdateStructure
//==================================================================
void UpdateHtfStructure(MqlRates &bar)
  {
   HtfDetectPullback(bar);
   HtfBuildSimpleStructure();
   HtfUpdateIdm();
  }

//==================================================================
// HTF REVERSE TO DOWNTREND — port of ReverseToDowntrend
//==================================================================
void HtfReverseToDowntrend(MqlRates &takenBar)
  {
   double originPrice = 0.0;
   datetime originTime = 0;

   int npb = ArraySize(g_htfPbSwings);
   if(npb > 0)
     {
      datetime legStart = g_htfPbSwings[0].time;
      int legStartShift = iBarShift(_Symbol, InpHtfTimeframe, legStart);
      int takenShift    = iBarShift(_Symbol, InpHtfTimeframe, takenBar.time);
      if(legStartShift >= 0 && takenShift >= 0 && legStartShift >= takenShift)
        {
         int count = legStartShift - takenShift + 1;
         MqlRates legBars[];
         ArraySetAsSeries(legBars, true);
         if(CopyRates(_Symbol, InpHtfTimeframe, takenShift, count, legBars) > 0)
           {
            double hh = -DBL_MAX;
            datetime hhTime = 0;
            for(int i = 0; i < ArraySize(legBars); i++)
              {
               if(legBars[i].high > hh)
                 {
                  hh = legBars[i].high;
                  hhTime = legBars[i].time;
                 }
              }
            if(hh > -DBL_MAX)
              {
               originPrice = hh;
               originTime  = hhTime;
              }
           }
        }
     }

   if(originPrice <= 0.0)
     {
      int n = ArraySize(g_htfSwings);
      for(int i = n - 1; i >= 0; i--)
        {
         if(g_htfSwings[i].isHigh)
           {
            originPrice = g_htfSwings[i].price;
            originTime  = g_htfSwings[i].time;
            break;
           }
        }
     }

   if(originPrice <= 0.0)
     {
      Print("AjipIDM: HtfReverseToDowntrend — no origin found!");
      return;
     }

   g_htfTrend = TREND_DOWN;

   HtfResetSwings();
   HtfResetPbSwings();
   HtfAddPbSwing(originPrice, originTime, true);

   g_htfPhase = PHASE_DOWN;

   MqlRates orgBar[];
   ArraySetAsSeries(orgBar, true);
   if(CopyRates(_Symbol, InpHtfTimeframe, originTime, 1, orgBar) > 0)
     {
      g_htfBase.high  = orgBar[0].high;
      g_htfBase.low   = orgBar[0].low;
      g_htfBase.time  = orgBar[0].time;
      g_htfBase.valid = true;
     }
   g_htfOutsidePending = false;

   // Reset idm taken BEFORE replay so mid-replay reverses can fire.
   g_htfIdmTaken = false;

   HtfRebuildStructure(originTime, takenBar.time);

   HtfUpdateIdm();

   PrintFormat("AjipIDM: HTF Reversed to DOWN. Origin=%.5f@%s, swings=%d",
               originPrice, TimeToString(originTime), ArraySize(g_htfSwings));

   DrawHtfSwings();
  }

//==================================================================
// HTF REVERSE TO UPTREND — port of ReverseToUptrend
//==================================================================
void HtfReverseToUptrend(MqlRates &takenBar)
  {
   double originPrice = 0.0;
   datetime originTime = 0;

   int npb = ArraySize(g_htfPbSwings);
   if(npb > 0)
     {
      datetime legStart = g_htfPbSwings[0].time;
      int legStartShift = iBarShift(_Symbol, InpHtfTimeframe, legStart);
      int takenShift    = iBarShift(_Symbol, InpHtfTimeframe, takenBar.time);
      if(legStartShift >= 0 && takenShift >= 0 && legStartShift >= takenShift)
        {
         int count = legStartShift - takenShift + 1;
         MqlRates legBars[];
         ArraySetAsSeries(legBars, true);
         if(CopyRates(_Symbol, InpHtfTimeframe, takenShift, count, legBars) > 0)
           {
            double ll = DBL_MAX;
            datetime llTime = 0;
            for(int i = 0; i < ArraySize(legBars); i++)
              {
               if(legBars[i].low < ll)
                 {
                  ll = legBars[i].low;
                  llTime = legBars[i].time;
                 }
              }
            if(ll < DBL_MAX)
              {
               originPrice = ll;
               originTime  = llTime;
              }
           }
        }
     }

   if(originPrice <= 0.0)
     {
      int n = ArraySize(g_htfSwings);
      for(int i = n - 1; i >= 0; i--)
        {
         if(!g_htfSwings[i].isHigh)
           {
            originPrice = g_htfSwings[i].price;
            originTime  = g_htfSwings[i].time;
            break;
           }
        }
     }

   if(originPrice <= 0.0)
     {
      Print("AjipIDM: HtfReverseToUptrend — no origin found!");
      return;
     }

   g_htfTrend = TREND_UP;

   HtfResetSwings();
   HtfResetPbSwings();
   HtfAddPbSwing(originPrice, originTime, false);

   g_htfPhase = PHASE_UP;

   MqlRates orgBar[];
   ArraySetAsSeries(orgBar, true);
   if(CopyRates(_Symbol, InpHtfTimeframe, originTime, 1, orgBar) > 0)
     {
      g_htfBase.high  = orgBar[0].high;
      g_htfBase.low   = orgBar[0].low;
      g_htfBase.time  = orgBar[0].time;
      g_htfBase.valid = true;
     }
   g_htfOutsidePending = false;

   g_htfIdmTaken = false;

   HtfRebuildStructure(originTime, takenBar.time);

   HtfUpdateIdm();

   PrintFormat("AjipIDM: HTF Reversed to UP. Origin=%.5f@%s, swings=%d",
               originPrice, TimeToString(originTime), ArraySize(g_htfSwings));

   DrawHtfSwings();
  }

//==================================================================
// HTF REBUILD STRUCTURE — port of RebuildStructure (structure-only,
// no g_initMode: HTF never places entries so nothing needs suppressing)
//==================================================================
void HtfRebuildStructure(datetime originTime, datetime endTime)
  {
   int originShift = iBarShift(_Symbol, InpHtfTimeframe, originTime);
   int endShift    = iBarShift(_Symbol, InpHtfTimeframe, endTime);

   if(originShift < 0 || endShift < 0 || originShift < endShift)
     {
      PrintFormat("AjipIDM: HtfRebuildStructure bad shifts origin=%d end=%d",
                  originShift, endShift);
      return;
     }

   int count = originShift - endShift;
   if(count <= 0) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, InpHtfTimeframe, endShift, count, rates);
   if(copied <= 0) return;

   for(int i = 0; i < copied; i++)
     {
      HtfDetectPullback(rates[i]);
      HtfBuildSimpleStructure();
      HtfUpdateIdm();
      if(g_htfIdmPrice > 0.0)
         HtfCheckIdmTaken(rates[i]);
     }

   HtfBuildSimpleStructure();
   HtfUpdateIdm();
  }

//==================================================================
// HTF CHECK IDM TAKEN — structure-only port of the taken/trend-flip half
// of CheckIdmTaken. No entry placement: HTF is context-only, never trades.
//==================================================================
void HtfCheckIdmTaken(MqlRates &bar)
  {
   if(g_htfIdmTaken) return;
   if(g_htfIdmPrice <= 0.0) return;

   bool taken = false;

   if(g_htfTrend == TREND_UP)
     {
      if(bar.low < g_htfIdmPrice)
         taken = true;
     }
   else if(g_htfTrend == TREND_DOWN)
     {
      if(bar.high > g_htfIdmPrice)
         taken = true;
     }

   if(!taken) return;

   g_htfIdmTaken = true;

   PrintFormat("AjipIDM: HTF IDM TAKEN. Trend was %s, idm=%.5f, bar close=%.5f",
               TrendString(g_htfTrend), g_htfIdmPrice, bar.close);

   if(g_htfTrend == TREND_UP)
      HtfReverseToDowntrend(bar);
   else if(g_htfTrend == TREND_DOWN)
      HtfReverseToUptrend(bar);
  }

//==================================================================
// INIT HTF STRUCTURE — port of InitStructure
//==================================================================
bool InitHtfStructure()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, InpHtfTimeframe, 0, InpCandlesInit, rates);
   if(copied < 10)
     {
      PrintFormat("AjipIDM: Not enough HTF bars for init (%d)", copied);
      return(false);
     }

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

   int originIdx;
   if(highIdx < lowIdx)
     {
      g_htfTrend = TREND_DOWN;
      originIdx = highIdx;
     }
   else
     {
      g_htfTrend = TREND_UP;
      originIdx = lowIdx;
     }

   HtfResetSwings();
   HtfResetPbSwings();

   if(g_htfTrend == TREND_DOWN)
      HtfAddPbSwing(highest, rates[originIdx].time, true);
   else
      HtfAddPbSwing(lowest, rates[originIdx].time, false);

   g_htfBase.high  = rates[originIdx].high;
   g_htfBase.low   = rates[originIdx].low;
   g_htfBase.time  = rates[originIdx].time;
   g_htfBase.valid = true;
   g_htfPhase      = (g_htfTrend == TREND_DOWN) ? PHASE_DOWN : PHASE_UP;
   g_htfOutsidePending = false;

   for(int i = originIdx + 1; i < copied - 1; i++)
     {
      HtfDetectPullback(rates[i]);
      HtfBuildSimpleStructure();
      HtfUpdateIdm();
      if(g_htfIdmPrice > 0.0)
         HtfCheckIdmTaken(rates[i]);
     }

   HtfBuildSimpleStructure();
   HtfUpdateIdm();
   g_htfIdmTaken = false;

   g_htfLastBarTime = rates[copied - 2].time;

   PrintFormat("AjipIDM: HTF structure built. Trend=%s, Swings=%d, idm=%.5f",
               TrendString(g_htfTrend), ArraySize(g_htfSwings), g_htfIdmPrice);

   DrawHtfSwings();

   return(true);
  }

//==================================================================
// DRAW HTF SWINGS — HTF structure zigzag + idm line. Port of DrawSwings,
// distinct object prefix (g_htfObjPrefix) and dotted/distinct colors so
// HTF lines are visually distinguishable from LTF ones and never wiped
// by DrawSwings()'s ObjectsDeleteAll(0, g_objPrefix).
//==================================================================
void DrawHtfSwings()
  {
   if(!InpDrawLines || !InpUseHtfFilter) return;

   ObjectsDeleteAll(0, g_htfObjPrefix);

   int n = ArraySize(g_htfSwings);
   if(n < 2) return;

   for(int i = 0; i < n; i++)
     {
      string name = g_htfObjPrefix + "SW_" + IntegerToString(i);
      datetime t1 = g_htfSwings[i].time;
      double  p1  = g_htfSwings[i].price;

      datetime t2;
      double  p2;
      if(i < n - 1)
        {
         t2 = g_htfSwings[i + 1].time;
         p2 = g_htfSwings[i + 1].price;
        }
      else
        {
         t2 = TimeCurrent();
         p2 = p1;
        }

      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_COLOR,
                       g_htfSwings[i].isHigh ? clrMediumPurple : clrGoldenrod);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }

   // idm line (only if valid)
   if(g_htfIdmPrice > 0.0)
     {
      string idmName = g_htfObjPrefix + "IDM";
      ObjectCreate(0, idmName, OBJ_HLINE, 0, 0, g_htfIdmPrice);
      ObjectSetInteger(0, idmName, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, idmName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, idmName, OBJPROP_STYLE, STYLE_DASHDOT);
      ObjectSetInteger(0, idmName, OBJPROP_SELECTABLE, false);
     }

   ChartRedraw();
  }

#endif // AJIPIDM_HTFCONTEXT_MQH
