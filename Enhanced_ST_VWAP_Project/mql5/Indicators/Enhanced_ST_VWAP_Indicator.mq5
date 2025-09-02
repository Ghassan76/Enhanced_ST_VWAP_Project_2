//+------------------------------------------------------------------+
//|                                 Enhanced_ST_VWAP_Indicator.mq5   |
//|            SuperTrend with VWAP filter and signal buffer         |
//+------------------------------------------------------------------+
#property copyright "2025"
#property strict
#property indicator_chart_window
#property indicator_plots 5

//--- plots
double ST_Up[];      // plot 0
double ST_Down[];    // plot 1
double VWAP[];       // plot 2
double ArrowBuy[];   // plot 3
double ArrowSell[];  // plot 4

//--- non plotted
double SignalBuffer[];  // index 5
double ST_Direction[];  // index 6
double StrengthBuf[];   // index 7 (unused)

input group "SuperTrend";
input int    ATRPeriod      = 22;
input double STMultiplier   = 3.0;
input ENUM_APPLIED_PRICE STPrice = PRICE_MEDIAN;
input group "VWAP";
input ENUM_APPLIED_PRICE VWAPPrice = PRICE_TYPICAL;
input bool   ResetVWAPDaily = true;

int atrHandle;
string dashName="STVWAP_Dash";

//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0,ST_Up,INDICATOR_DATA);    PlotIndexSetInteger(0,PLOT_DRAW_TYPE,DRAW_LINE);   PlotIndexSetInteger(0,PLOT_LINE_COLOR,0,clrLime);
   SetIndexBuffer(1,ST_Down,INDICATOR_DATA);  PlotIndexSetInteger(1,PLOT_DRAW_TYPE,DRAW_LINE);   PlotIndexSetInteger(1,PLOT_LINE_COLOR,0,clrTomato);
   SetIndexBuffer(2,VWAP,INDICATOR_DATA);     PlotIndexSetInteger(2,PLOT_DRAW_TYPE,DRAW_LINE);   PlotIndexSetInteger(2,PLOT_LINE_COLOR,0,clrOrange);
   SetIndexBuffer(3,ArrowBuy,INDICATOR_DATA); PlotIndexSetInteger(3,PLOT_DRAW_TYPE,DRAW_ARROW);  PlotIndexSetInteger(3,PLOT_ARROW,233);
   SetIndexBuffer(4,ArrowSell,INDICATOR_DATA);PlotIndexSetInteger(4,PLOT_DRAW_TYPE,DRAW_ARROW); PlotIndexSetInteger(4,PLOT_ARROW,234);
   SetIndexBuffer(5,SignalBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(6,ST_Direction,INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,StrengthBuf,INDICATOR_CALCULATIONS);

   atrHandle=iATR(_Symbol,_Period,ATRPeriod);

   // dashboard label
   ObjectCreate(0,dashName,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,dashName,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,dashName,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,dashName,OBJPROP_YDISTANCE,15);
   ObjectSetInteger(0,dashName,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,dashName,OBJPROP_FONTSIZE,10);
   ObjectSetString (0,dashName,OBJPROP_FONT,"Segoe UI");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);
   ObjectDelete(0,dashName);
}

//+------------------------------------------------------------------+
// helper for applied price
//+------------------------------------------------------------------+
double AppliedPrice(const ENUM_APPLIED_PRICE price,const double open,const double high,const double low,const double close)
{
   switch(price)
   {
      case PRICE_OPEN:    return open;
      case PRICE_HIGH:    return high;
      case PRICE_LOW:     return low;
      case PRICE_MEDIAN:  return (high+low)/2.0;
      case PRICE_TYPICAL: return (high+low+close)/3.0;
      case PRICE_WEIGHTED:return (high+low+close+close)/4.0;
      default:            return close;
   }
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],const double &high[],const double &low[],const double &close[],
                const long &tick_volume[],const long &volume[],const int &spread[])
{
   if(rates_total<ATRPeriod+2) return 0;

   static double cumPV=0.0,cumVol=0.0;
   static int day=0;

   int start=(prev_calculated==0)?rates_total-1:rates_total-prev_calculated;
   double atr[]; ArraySetAsSeries(atr,true); CopyBuffer(atrHandle,0,0,rates_total,atr);

   for(int shift=start;shift>=0;--shift)
   {
      int barDay=TimeDay(time[shift]);
      if(ResetVWAPDaily && barDay!=day)
      {
         cumPV=0.0; cumVol=0.0; day=barDay;
      }
      double price=AppliedPrice(VWAPPrice,open[shift],high[shift],low[shift],close[shift]);
      double vol=volume[shift];
      cumPV+=price*vol; cumVol+=vol; VWAP[shift]=(cumVol>0)?cumPV/cumVol:price;

      double hl2=AppliedPrice(STPrice,open[shift],high[shift],low[shift],close[shift]);
      double atrv=atr[shift];
      double basicUpper=hl2+STMultiplier*atrv;
      double basicLower=hl2-STMultiplier*atrv;

      double prevST=(shift==rates_total-1)?hl2:(ST_Direction[shift+1]>0?ST_Up[shift+1]:ST_Down[shift+1]);
      int prevDir=(shift==rates_total-1)?+1:(int)ST_Direction[shift+1];

      double st=prevST; int dir=prevDir;
      if(prevDir>0)
      {
         st=MathMax(basicLower,prevST);
         if(close[shift]<st){dir=-1;st=basicUpper;}
      }
      else
      {
         st=MathMin(basicUpper,prevST);
         if(close[shift]>st){dir=+1;st=basicLower;}
      }
      ST_Direction[shift]=dir;
      if(dir>0){ST_Up[shift]=st; ST_Down[shift]=EMPTY_VALUE;} else {ST_Down[shift]=st; ST_Up[shift]=EMPTY_VALUE;}

      SignalBuffer[shift]=0.0; ArrowBuy[shift]=ArrowSell[shift]=EMPTY_VALUE;
      if(shift+1<rates_total)
      {
         bool revUp   = (dir>0 && ST_Direction[shift+1]<0);
         bool revDown = (dir<0 && ST_Direction[shift+1]>0);
         if(revUp   && close[shift]>=VWAP[shift]) {SignalBuffer[shift]=+1; ArrowBuy[shift]=low[shift];}
         if(revDown && close[shift]<=VWAP[shift]) {SignalBuffer[shift]=-1; ArrowSell[shift]=high[shift];}
      }
   }

   string txt=StringFormat("ST dir=%d",(int)ST_Direction[0]);
   ObjectSetString(0,dashName,OBJPROP_TEXT,txt);
   return(rates_total);
}

