#ifndef AJIPIDM_PANEL_MQH
#define AJIPIDM_PANEL_MQH

// INFO PANEL — on-chart dashboard: current trend, HTF trend,
// today/this-week/this-month realized P/L, daily target/max-loss status AND
// batch target/max-loss status (both via ClassifyLimitStatus — daily blocks
// new entries when hit, batch doesn't, see AjipIDM_Trade.mqh/
// AjipIDM_Entry.mqh), session status (InSession(), same gate used for new
// entries and CheckSessionCloseAll), news blackout status (InNewsBlackout(),
// AjipIDM_News.mqh — same gate used for new entries), and live open MFE/MAE (summed across
// tracked open positions — updated every tick via UpdateMfeMae() in
// AjipIDM_Entry.mqh). The panel itself still refreshes once per closed LTF
// bar (same cadence as everything else in this EA — not a timer, so
// behavior is identical live and in Strategy Tester). Uses g_panelPrefix,
// distinct from g_objPrefix so DrawSwings()'s ObjectsDeleteAll doesn't wipe
// it out.
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

string LimitStatusText(ENUM_LIMIT_STATUS s)
  {
   switch(s)
     {
      case LIMIT_STATUS_TARGET_HIT:  return("TARGET HIT");
      case LIMIT_STATUS_MAXLOSS_HIT: return("MAX LOSS HIT");
      case LIMIT_STATUS_DISABLED:    return("disabled");
      default:                       return("active");
     }
  }

color LimitStatusColor(ENUM_LIMIT_STATUS s)
  {
   if(s == LIMIT_STATUS_TARGET_HIT)  return(clrLimeGreen);
   if(s == LIMIT_STATUS_MAXLOSS_HIT) return(clrTomato);
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

string NewsStatusText()
  {
   if(!InpNewsFilterEnabled) return("disabled");
   return(InNewsBlackout() ? "BLOCKED" : "clear");
  }

color NewsStatusColor()
  {
   if(!InpNewsFilterEnabled) return(clrSilver);
   return(InNewsBlackout() ? clrTomato : clrLimeGreen);
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
   const int lines = 12;
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

   double floatingPnl = GetFloatingPnL();

   // Daily target/max-loss status — realized (todayPnl, already computed
   // above) + floating, same total CheckDailyCloseAll acts on. Hitting this
   // blocks new entries for the rest of the day.
   ENUM_LIMIT_STATUS dailyStatus = ClassifyLimitStatus(todayPnl + floatingPnl, InpDailyMaxProfit, InpDailyMaxLoss);
   PanelLabel(g_panelPrefix + "DailyStatus", y, "Daily:     " + LimitStatusText(dailyStatus), LimitStatusColor(dailyStatus));
   y += lineH;

   // Batch target/max-loss status — g_batchRealizedPnl (closed so far this
   // batch) + floating, same total CheckBatchCloseAll acts on. Hitting this
   // closes only the current batch — new entries are still allowed right after.
   ENUM_LIMIT_STATUS batchStatus = ClassifyLimitStatus(g_batchRealizedPnl + floatingPnl, InpBatchMaxProfit, InpBatchMaxLoss);
   PanelLabel(g_panelPrefix + "BatchStatus", y, "Batch:     " + LimitStatusText(batchStatus), LimitStatusColor(batchStatus));
   y += lineH;

   PanelLabel(g_panelPrefix + "Session", y, "Session:   " + SessionStatusText(), SessionStatusColor());
   y += lineH;

   PanelLabel(g_panelPrefix + "News", y, "News:      " + NewsStatusText(), NewsStatusColor());
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
