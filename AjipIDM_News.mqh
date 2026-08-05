#ifndef AJIPIDM_NEWS_MQH
#define AJIPIDM_NEWS_MQH

//==================================================================
// NEWS BLACKOUT — blocks new entries around high-impact economic
// calendar events matching this symbol's base/profit currency (e.g.
// XAUUSD checks XAU + USD events). Uses MT5's built-in Calendar API,
// which relies on the terminal's own calendar cache — if it's
// unavailable (e.g. Strategy Tester without cached data), the query
// simply returns no events and this stays non-blocking, same fallback
// as the session filter on unparseable input.
// Result is cached for NEWS_CACHE_SECONDS so it isn't recomputed every
// tick — the blackout window is minutes wide, a short cache lag is
// immaterial. Only used to gate new entries (CheckIdmZoneEntry/
// CheckAggressiveZoneEntry, AjipIDM_Entry.mqh); does not close existing
// positions.
//==================================================================
bool InNewsBlackout()
  {
   if(!InpNewsFilterEnabled) return(false);

   const int       NEWS_CACHE_SECONDS = 15;
   static datetime lastCheck  = 0;
   static bool     cached     = false;
   static bool     wasBlocked = false;

   datetime now = TimeCurrent();
   if(lastCheck != 0 && now - lastCheck < NEWS_CACHE_SECONDS)
      return(cached);
   lastCheck = now;

   string baseCcy   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profitCcy = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   datetime from = now - InpNewsMinutesAfter  * 60;
   datetime to   = now + InpNewsMinutesBefore * 60;

   bool   blocked      = false;
   string blockedEvent = "";

   MqlCalendarValue values[];
   if(CalendarValueHistory(values, from, to, "", ""))
     {
      int n = ArraySize(values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent evt;
         if(!CalendarEventById(values[i].event_id, evt)) continue;
         if(evt.importance < InpNewsMinImportance) continue;

         MqlCalendarCountry country;
         if(!CalendarCountryById(evt.country_id, country)) continue;
         if(country.currency != baseCcy && country.currency != profitCcy) continue;

         blocked      = true;
         blockedEvent = StringFormat("%s (%s) @ %s", evt.name, country.currency,
                                      TimeToString(values[i].time, TIME_DATE | TIME_MINUTES));
         break;
        }
     }

   if(InpEnableLog)
     {
      if(blocked && !wasBlocked)
         PrintFormat("AjipIDM: News blackout started — %s", blockedEvent);
      else if(!blocked && wasBlocked)
         Print("AjipIDM: News blackout ended.");
     }

   wasBlocked = blocked;
   cached     = blocked;
   return(cached);
  }

#endif // AJIPIDM_NEWS_MQH
