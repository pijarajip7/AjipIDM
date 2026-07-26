#ifndef AJIPIDM_PANEL_MQH
#define AJIPIDM_PANEL_MQH

// INFO PANEL — on-chart dashboard: current trend, HTF trend, and
// today/this-week/this-month realized P/L. Refreshed once per closed LTF
// bar (same cadence as everything else in this EA — not a timer, so
// behavior is identical live and in Strategy Tester). Uses g_panelPrefix,
// distinct from g_objPrefix so DrawSwings()'s ObjectsDeleteAll doesn't
// wipe it out.
//==================================================================

color TrendColor(ENUM_TREND t)
  {
   if(t == TREND_UP)   return(clrLimeGreen);
   if(t == TREND_DOWN) return(clrTomato);
   return(clrSilver);
  }

color PnlColor(double v)
  {
   if(v > 0.0) return(clrLimeGreen);
   if(v < 0.0) return(clrTomato);
   return(clrSilver);
  }

void PanelLabel(string name, int yOffset, string text, color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY + yOffset);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void UpdatePanel()
  {
   if(!InpShowPanel) return;

   const int lineH = 16;
   const int lines = 6;
   int y = 0;

   // Background box sized to fit the content
   string bg = g_panelPrefix + "BG";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, InpPanelCorner);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX - 6);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 210);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, lineH * lines + 12);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, clrBlack);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY - 6);

   PanelLabel(g_panelPrefix + "Title", y, "AjipIDM", clrWhite);
   y += lineH;

   PanelLabel(g_panelPrefix + "Trend", y, "Trend:     " + TrendString(g_trend), TrendColor(g_trend));
   y += lineH;

   string htfText = InpUseHtfFilter ? TrendString(g_htfTrend) : "OFF";
   color  htfClr  = InpUseHtfFilter ? TrendColor(g_htfTrend) : clrSilver;
   PanelLabel(g_panelPrefix + "HtfTrend", y, "HTF Trend: " + htfText, htfClr);
   y += lineH;

   double todayPnl = GetDailyPnL();
   double weekPnl  = GetWeekPnL();
   double monthPnl = GetMonthPnL();

   PanelLabel(g_panelPrefix + "Today", y, StringFormat("Today P/L: %.2f", todayPnl), PnlColor(todayPnl));
   y += lineH;
   PanelLabel(g_panelPrefix + "Week", y, StringFormat("Week P/L:  %.2f", weekPnl), PnlColor(weekPnl));
   y += lineH;
   PanelLabel(g_panelPrefix + "Month", y, StringFormat("Month P/L: %.2f", monthPnl), PnlColor(monthPnl));
   y += lineH;

   ChartRedraw();
  }

#endif // AJIPIDM_PANEL_MQH
