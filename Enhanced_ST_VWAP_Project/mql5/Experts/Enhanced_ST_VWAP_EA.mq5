//+------------------------------------------------------------------+
//|                                         Enhanced_ST_VWAP_EA.mq5  |
//|            Minimal EA executing signals from ST&VWAP indicator   |
//+------------------------------------------------------------------+
#property copyright "2025"
#property strict

#include <Enhanced_TradeAlgorithms.mqh>

// Indicator buffer constants
#define ST_UP_BUF      0
#define ST_DOWN_BUF    1
#define VWAP_BUF       2
#define ARROW_BUY_BUF  3
#define ARROW_SELL_BUF 4
#define SIGNAL_BUF     5

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
input group "General";
input ulong   MagicNumber       = 567890;
input bool    EnableEntry       = true;
input bool    EnableBuy         = true;
input bool    EnableSell        = true;
input int     MaxSpreadPts      = 50;
input bool    SignalOnClosedBar = true;
input bool    DebugMode         = false;

input group "Indicator";
input ENUM_TIMEFRAMES InpIndTF  = PERIOD_CURRENT;
input int     ATRPeriod         = 22;
input double  STMultiplier      = 3.0;
input ENUM_APPLIED_PRICE STPrice = PRICE_MEDIAN;
input ENUM_APPLIED_PRICE VWAPPrice = PRICE_TYPICAL;
input bool    ResetVWAPDaily    = true;

input group "Position";
input bool    DynamicLots       = true;
input double  RiskPct           = 1.0;
input double  FixedLot          = 0.1;
input double  PointsSL          = 500;
input double  PointsTP          = 1000;

input group "Trailing";
input bool    EnableBreakEven   = true;
input bool    EnableTrailing    = true;
input double  BreakEvenPercent  = 40.0;
input double  BESLOffsetPct     = 5.0;
input double  TrailStartPercent = 60.0;
input int     TrailStepPoints   = 100;
input int     MaxSLModifications= 5;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
int        STVWAPHandle = INVALID_HANDLE;
TradeState g_state;
DailyLimits g_limits = {0.0,0,0};

//+------------------------------------------------------------------+
//| Utility functions                                                |
//+------------------------------------------------------------------+
int Shift()
{
   return SignalOnClosedBar ? 1 : 0;
}

bool IsNewBar()
{
   static datetime last=0;
   datetime t=iTime(_Symbol,_Period,0);
   if(t==0 || t==last) return false;
   last=t; return true;
}

bool ReadSignal(double &sig)
{
   if(STVWAPHandle==INVALID_HANDLE) return false;
   double v[1];
   int got=CopyBuffer(STVWAPHandle,SIGNAL_BUF,Shift(),1,v);
   if(got!=1) return false;
   sig=v[0];
   return true;
}

void LogDiag()
{
   if(!DebugMode) return;
   static datetime last=0; if(last==iTime(_Symbol,_Period,0)) return; last=iTime(_Symbol,_Period,0);
   double sig; int got=CopyBuffer(STVWAPHandle,SIGNAL_BUF,Shift(),1,&sig);
   double st[1],vw[1]; CopyBuffer(STVWAPHandle,ST_UP_BUF,Shift(),1,st); CopyBuffer(STVWAPHandle,VWAP_BUF,Shift(),1,vw);
   double spr=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
   PrintFormat("[diag] got=%d sig=%G ST=%.5f VWAP=%.5f spread=%.1f trade=%s",got,(got==1?sig:0.0),st[0],vw[0],spr,(TA_TradingAllowed()?"Y":"N"));
}

double CalcLot()
{
   if(!DynamicLots) return FixedLot;
   double risk=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPct/100.0;
   return TA_RiskToLot(risk,PointsSL);
}

void ApplyManagement()
{
   if(!PositionSelect(_Symbol)) return;
   ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);
   TrailParams P;
   P.be_trigger_pts = PointsTP*BreakEvenPercent/100.0;
   P.be_offset_pts  = PointsTP*BESLOffsetPct/100.0;
   P.trail_start_pts= PointsTP*TrailStartPercent/100.0;
   P.trail_step_pts = TrailStepPoints;
   P.max_sl_mods    = MaxSLModifications;
   if(EnableBreakEven) TA_ApplyBreakEven(ticket,P);
   if(EnableTrailing) TA_ApplyTrailing(ticket,P);
}

bool SpreadTooWide()
{
   return TA_SpreadTooWide(MaxSpreadPts);
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   TA_OnInit(g_state);
   STVWAPHandle = iCustom(_Symbol,InpIndTF,"Enhanced_ST_VWAP_Indicator",ATRPeriod,STMultiplier,STPrice,VWAPPrice,ResetVWAPDaily);
   if(STVWAPHandle==INVALID_HANDLE)
   {
      Print("iCustom failed, err=",GetLastError());
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(STVWAPHandle!=INVALID_HANDLE) IndicatorRelease(STVWAPHandle);
   TA_OnDeinit();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   TS_ResetDailyIfNewDay(g_state);
   TS_UnfreezeIfDue(g_state);

   if(SignalOnClosedBar && !IsNewBar()) { LogDiag(); return; }
   LogDiag();

   double sig; if(!ReadSignal(sig)) return;
   if(!EnableEntry || SpreadTooWide() || !TA_TradingAllowed()) return;

   bool hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(sig>0 && EnableBuy && TS_Ready(g_state) && TA_CanOpenNewPosition(hedging))
   {
      double lot=CalcLot();
      double sl=SymbolInfoDouble(_Symbol,SYMBOL_BID)-PointsSL*_Point;
      double tp=SymbolInfoDouble(_Symbol,SYMBOL_BID)+PointsTP*_Point;
      ulong ticket; long rc; if(TA_OpenBuy(lot,sl,tp,ticket,rc)) TS_OnOpened(g_state);
   }
   else if(sig<0 && EnableSell && TS_Ready(g_state) && TA_CanOpenNewPosition(hedging))
   {
      double lot=CalcLot();
      double sl=SymbolInfoDouble(_Symbol,SYMBOL_ASK)+PointsSL*_Point;
      double tp=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-PointsTP*_Point;
      ulong ticket; long rc; if(TA_OpenSell(lot,sl,tp,ticket,rc)) TS_OnOpened(g_state);
   }

   ApplyManagement();
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_entry==DEAL_ENTRY_OUT)
      {
         double pnl=trans.profit+trans.swap+trans.commission;
         TA_UpdateDailyOnClose(g_state,pnl);
         TS_OnClosed(g_state,pnl);
      }
   }
}

