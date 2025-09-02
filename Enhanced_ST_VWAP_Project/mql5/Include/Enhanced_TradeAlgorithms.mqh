//+------------------------------------------------------------------+
//|                                     Enhanced_TradeAlgorithms.mqh |
//|                     Execution & trade management utilities       |
//+------------------------------------------------------------------+
#property copyright "2025"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum EA_STATE
{
   ST_READY = 0,
   ST_IN_TRADE,
   ST_COOLDOWN,
   ST_FROZEN
};

struct TradeState
{
   EA_STATE state;
   datetime last_open_time;
   datetime last_close_time;
   int      daily_trades;
   double   daily_pnl;
   datetime daily_anchor;
   datetime cooldown_until;
   datetime freeze_until;
};

struct DailyLimits
{
   double max_loss_money;
   int    max_trades;
   int    cooldown_sec;
};

struct TrailParams
{
   double be_trigger_pts;
   double be_offset_pts;
   double trail_start_pts;
   double trail_step_pts;
   int    max_sl_mods;
};

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
CTrade g_trade;

struct ModCounter
{
   ulong ticket;
   int   sl_mods;
};
static ModCounter g_mods[];

//+------------------------------------------------------------------+
//| Internal helpers                                                 |
//+------------------------------------------------------------------+
int FindModIndex(ulong ticket)
{
   for(int i=0;i<ArraySize(g_mods);i++)
      if(g_mods[i].ticket==ticket)
         return i;
   return -1;
}

int GetSLMods(ulong ticket)
{
   int idx=FindModIndex(ticket);
   return idx>=0 ? g_mods[idx].sl_mods : 0;
}

void IncSLMods(ulong ticket)
{
   int idx=FindModIndex(ticket);
   if(idx<0)
   {
      idx=ArraySize(g_mods);
      ArrayResize(g_mods,idx+1);
      g_mods[idx].ticket=ticket;
      g_mods[idx].sl_mods=0;
   }
   g_mods[idx].sl_mods++;
}

//+------------------------------------------------------------------+
//| Trade state management                                           |
//+------------------------------------------------------------------+
void TS_Init(TradeState &S)
{
   S.state         = ST_READY;
   S.last_open_time=0;
   S.last_close_time=0;
   S.daily_trades  =0;
   S.daily_pnl     =0.0;
   S.daily_anchor  = (datetime)TimeCurrent();
   S.cooldown_until=0;
   S.freeze_until  =0;
}

bool TS_Ready(const TradeState &S)
{
   if(S.state!=ST_READY) return false;
   if(S.freeze_until>0 && TimeCurrent()<S.freeze_until) return false;
   if(S.cooldown_until>0 && TimeCurrent()<S.cooldown_until) return false;
   return true;
}

void TS_OnOpened(TradeState &S)
{
   S.state=ST_IN_TRADE;
   S.last_open_time=TimeCurrent();
   S.daily_trades++;
}

void TS_OnClosed(TradeState &S,double pnl)
{
   S.last_close_time=TimeCurrent();
   S.daily_pnl+=pnl;
   S.state=ST_READY;
   S.cooldown_until=TimeCurrent();
}

void TS_SetCooldown(TradeState &S,int seconds)
{
   S.cooldown_until=TimeCurrent()+seconds;
   S.state=ST_COOLDOWN;
}

void TS_SetFreeze(TradeState &S,int minutes)
{
   S.freeze_until=TimeCurrent()+minutes*60;
   S.state=ST_FROZEN;
}

void TS_UnfreezeIfDue(TradeState &S)
{
   if(S.state==ST_FROZEN && TimeCurrent()>=S.freeze_until)
      S.state=ST_READY;
}

void TS_ResetDailyIfNewDay(TradeState &S)
{
   datetime now=TimeCurrent();
   if(TimeDay(S.daily_anchor)!=TimeDay(now) || TimeMonth(S.daily_anchor)!=TimeMonth(now) || TimeYear(S.daily_anchor)!=TimeYear(now))
   {
      S.daily_anchor=now;
      S.daily_trades=0;
      S.daily_pnl=0.0;
   }
}

//+------------------------------------------------------------------+
//| Operational checks                                               |
//+------------------------------------------------------------------+
bool TA_TradingAllowed()
{
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
}

bool TA_SpreadTooWide(double max_spread_pts)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spr=(ask-bid)/_Point;
   return spr>max_spread_pts;
}

bool TA_CanOpenNewPosition(bool hedging_allowed)
{
   if(hedging_allowed) return true;
   return !PositionSelect(_Symbol);
}

//+------------------------------------------------------------------+
//| Lot and price helpers                                            |
//+------------------------------------------------------------------+
double TA_MinLot()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
}

double TA_LotStep()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
}

double TA_NormalizeLot(double lots)
{
   double step=TA_LotStep();
   return MathRound(lots/step)*step;
}

double TA_PointsToPrice(double pts,bool up)
{
   return pts*_Point*(up?1:-1);
}

double TA_SanitizeStop(double price,bool is_sl)
{
   double level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   double cur=SymbolInfoDouble(_Symbol,is_sl?SYMBOL_BID:SYMBOL_ASK);
   if(is_sl)
   {
      if(price>cur-level) price=cur-level;
      if(price>cur-freeze) price=cur-freeze;
   }
   else
   {
      if(price<cur+level) price=cur+level;
      if(price<cur+freeze) price=cur+freeze;
   }
   return NormalizeDouble(price,_Digits);
}

double TA_RiskToLot(double risk_money,double stop_pts)
{
   double tick_value=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double lot_step=TA_LotStep();
   double lot_min=TA_MinLot();
   double lot=risk_money/(stop_pts*_Point*tick_value);
   lot=TA_NormalizeLot(lot);
   if(lot<lot_min) lot=lot_min;
   return lot;
}

//+------------------------------------------------------------------+
//| Execution wrappers                                               |
//+------------------------------------------------------------------+
bool TA_OpenBuy(double lot,double sl,double tp,ulong &ticket,long &retcode)
{
   bool ok=g_trade.Buy(lot,_Symbol,0,sl,tp);
   retcode=g_trade.ResultRetcode();
   ticket=g_trade.ResultOrder();
   if(ticket==0) ticket=g_trade.ResultDeal();
   if(ticket==0 && PositionSelect(_Symbol))
      ticket=(ulong)PositionGetInteger(POSITION_TICKET);
   return ok;
}

bool TA_OpenSell(double lot,double sl,double tp,ulong &ticket,long &retcode)
{
   bool ok=g_trade.Sell(lot,_Symbol,0,sl,tp);
   retcode=g_trade.ResultRetcode();
   ticket=g_trade.ResultOrder();
   if(ticket==0) ticket=g_trade.ResultDeal();
   if(ticket==0 && PositionSelect(_Symbol))
      ticket=(ulong)PositionGetInteger(POSITION_TICKET);
   return ok;
}

bool TA_ModifySLTP(ulong pos_ticket,double sl,double tp,long &retcode)
{
   bool ok=g_trade.PositionModify(pos_ticket,sl,tp);
   retcode=g_trade.ResultRetcode();
   return ok;
}

bool TA_Close(ulong pos_ticket,long &retcode)
{
   bool ok=g_trade.PositionClose(pos_ticket);
   retcode=g_trade.ResultRetcode();
   return ok;
}

//+------------------------------------------------------------------+
//| Break-even & trailing                                            |
//+------------------------------------------------------------------+
bool TA_ApplyBreakEven(ulong ticket,const TrailParams &P)
{
   if(P.max_sl_mods>=0 && GetSLMods(ticket)>=P.max_sl_mods) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   double price_open=PositionGetDouble(POSITION_PRICE_OPEN);
   double price_cur=PositionGetDouble(POSITION_PRICE_CURRENT);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double profit_pts=(type==POSITION_TYPE_BUY)?(price_cur-price_open)/_Point:(price_open-price_cur)/_Point;
   if(profit_pts<P.be_trigger_pts) return false;
   double new_sl=price_open + TA_PointsToPrice(P.be_offset_pts,(type==POSITION_TYPE_BUY));
   double sl=PositionGetDouble(POSITION_SL);
   if(type==POSITION_TYPE_BUY && (sl==0 || new_sl>sl))
   {
      long rc; if(TA_ModifySLTP(ticket,new_sl,PositionGetDouble(POSITION_TP),rc)) {IncSLMods(ticket); return true;}
   }
   if(type==POSITION_TYPE_SELL && (sl==0 || new_sl<sl))
   {
      long rc; if(TA_ModifySLTP(ticket,new_sl,PositionGetDouble(POSITION_TP),rc)) {IncSLMods(ticket); return true;}
   }
   return false;
}

bool TA_ApplyTrailing(ulong ticket,const TrailParams &P)
{
   if(P.max_sl_mods>=0 && GetSLMods(ticket)>=P.max_sl_mods) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   double price_open=PositionGetDouble(POSITION_PRICE_OPEN);
   double price_cur=PositionGetDouble(POSITION_PRICE_CURRENT);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double profit_pts=(type==POSITION_TYPE_BUY)?(price_cur-price_open)/_Point:(price_open-price_cur)/_Point;
   if(profit_pts<P.trail_start_pts) return false;
   double desired=(type==POSITION_TYPE_BUY)?(price_cur-TA_PointsToPrice(P.trail_step_pts,false)):(price_cur-TA_PointsToPrice(P.trail_step_pts,true));
   double sl=PositionGetDouble(POSITION_SL);
   if(type==POSITION_TYPE_BUY && desired>sl)
   {
      long rc; if(TA_ModifySLTP(ticket,desired,PositionGetDouble(POSITION_TP),rc)) {IncSLMods(ticket); return true;}
   }
   if(type==POSITION_TYPE_SELL && (sl==0 || desired<sl))
   {
      long rc; if(TA_ModifySLTP(ticket,desired,PositionGetDouble(POSITION_TP),rc)) {IncSLMods(ticket); return true;}
   }
   return false;
}

//+------------------------------------------------------------------+
//| Daily limits                                                     |
//+------------------------------------------------------------------+
bool TA_CheckDailyLimits(const TradeState &S,const DailyLimits &L,string &reason)
{
   if(L.max_trades>0 && S.daily_trades>=L.max_trades)
   {
      reason="max trades"; return false;
   }
   if(L.max_loss_money>0 && S.daily_pnl<=-L.max_loss_money)
   {
      reason="max loss"; return false;
   }
   return true;
}

void TA_UpdateDailyOnClose(TradeState &S,double pnl)
{
   S.daily_pnl+=pnl;
   S.last_close_time=TimeCurrent();
}

void TA_OnInit(TradeState &S)
{
   TS_Init(S);
   ArrayResize(g_mods,0);
}

void TA_OnDeinit()
{
   ArrayResize(g_mods,0);
}

