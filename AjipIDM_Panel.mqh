#ifndef AJIPIDM_PANEL_MQH
#define AJIPIDM_PANEL_MQH

// INFO PANEL — on-chart dashboard: current trend, HTF trend,
// today/this-week/this-month realized P/L, daily target/max-loss status
// (ClassifyDailyStatus, same realized+floating total CheckDailyCloseAll
// acts on), session status (InSession(), same gate used for new entries and
// CheckSessionCloseAll — AjipIDM_Trade.mqh/AjipIDM_Entry.mqh), and live open
// MFE/MAE (summed across tracked open positions — updated every tick via
// UpdateMfeMae() in AjipIDM_Entry.mqh). The panel itself still refreshes
// once per closed LTF bar (same cadence as everything else in this EA —
// not a timer, so behavior is identical live and in Strategy Tester). Uses
// g_panelPrefix, distinct from g_objPrefix so DrawSwings()'s
// ObjectsDeleteAll doesn't wipe it out.
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

string DailyStatusText(ENUM_DAILY_STATUS s)
  {
   switch(s)
     {
      case DAILY_STATUS_TARGET_HIT:  return("TARGET HIT");
      case DAILY_STATUS_MAXLOSS_HIT: return("MAX LOSS HIT");
      case DAILY_STATUS_DISABLED:    return("disabled");
      default:                       return("active");
     }
  }

color DailyStatusColor(ENUM_DAILY_STATUS s)
  {
   if(s == DAILY_STATUS_TARGET_HIT)  return(clrLimeGreen);
   if(s == DAILY_STATUS_MAXLOSS_HIT) return(clrTomato);
   return(clrSilver);
  }

string SessionStatusText()
  {
   if(!g_sessionFilterEnabled) return("all day");
   return(InSession() ? "OPEN" : "CLOSED");
  }

color SessionStatusColor()
  {
   if(!g_sessionFilterEnabled) return(clrSilver);
   return(InSession() ? clrLimeGreen : clrTomato);
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
   const int lines = 10;
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

   PanelLabel(g_panelPrefix + "HtfTrend", y, "HTF Trend: " + TrendString(g_htfTrend), TrendColor(g_htfTrend));
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

   // Daily target/max-loss status — realized (todayPnl, already computed
   // above) + floating, same total CheckDailyCloseAll acts on.
   ENUM_DAILY_STATUS dailyStatus = ClassifyDailyStatus(todayPnl + GetFloatingPnL());
   PanelLabel(g_panelPrefix + "DailyStatus", y, "Daily:     " + DailyStatusText(dailyStatus), DailyStatusColor(dailyStatus));
   y += lineH;

   PanelLabel(g_panelPrefix + "Session", y, "Session:   " + SessionStatusText(), SessionStatusColor());
   y += lineH;

   // Open MFE/MAE — summed across all currently tracked open positions
   double openMfe = 0.0, openMae = 0.0;
   int    nOpen   = ArraySize(g_entries);
   for(int i = 0; i < nOpen; i++)
     {
      openMfe += g_entries[i].mfe;
      openMae += g_entries[i].mae;
     }

   PanelLabel(g_panelPrefix + "Mfe", y, StringFormat("Open MFE:  %.2f", openMfe), PnlColor(openMfe));
   y += lineH;
   PanelLabel(g_panelPrefix + "Mae", y, StringFormat("Open MAE:  %.2f", openMae), PnlColor(openMae));
   y += lineH;

   ChartRedraw();
  }

#endif // AJIPIDM_PANEL_MQH
