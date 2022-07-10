//+------------------------------------------------------------------+
//|                                      PythonOptimizExpert_zmq.mq5 |
//|                                   Copyright 2022 Aleksandr Orlov |
//|                                                  avo2000@mail.ru |
//|                                     created: 2022-06-09 16:53:29 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022 Aleksandr Orlov"
#property link      "avo2000@mail.ru"
#property version   "1.00"

//#define USE_PROLOG
//#include "Build.mqh"

#ifdef USE_PROLOG
#include <My/Prolog.mqh>
#else
#define ERROR(p) Print(p)
#define INFO(p) Print(p)
//+------------------------------------------------------------------+
//|  Алгоритм определения момента появления нового бара              |
//+------------------------------------------------------------------+
class CIsNewBar {
  //----
public:
  //---- функция определения момента появления нового бара
  bool               IsNewBar(string symbol,ENUM_TIMEFRAMES timeframe) {
    //---- получим время появления текущего бара
    long dt;
    bool success = SeriesInfoInteger(symbol,timeframe,
                                     SERIES_LASTBAR_DATE,dt);
    if ( !success ) {
      int err = GetLastError();
#ifdef __MQL4__
      if ( (err != 4074) ||
           !MQLInfoInteger((ENUM_MQL_INFO_INTEGER)MQL_TESTER) ||
           (symbol == Symbol()) )
#endif
        ERROR(StringFormat("ошибка вызова SeriesInfoInteger(%s,%s,SERIES_LASTBAR_DATE): %d",
                                 symbol,EnumToString(timeframe),err));
      return false;
    }
    datetime TNew = (datetime)dt;
    if (TNew != m_TOld
        && TNew) {   // проверка на появление нового бара
      m_TOld = TNew;
      return (true); // появился новый бар!
    }
    //----
    return (false);  // новых баров пока нет!
  }

  //---- конструктор класса
                     CIsNewBar() {
    m_TOld = -1;
  }

  datetime           lastBarTime() {
    return m_TOld;
  }

protected:
  datetime           m_TOld;
  //----
};

CIsNewBar nb;
#endif

#include <Trade\Trade.mqh>
#include "ZmqRpc.mqh"

//+------------------------------------------------------------------+

ZmqClient client("tcp://localhost:50506");

CModelZmq* model_Net1Min;
CModelZmq* model_Net1Max;
CModelZmq* model_Net2Min;
CModelZmq* model_Net2Max;

int input_shape1[] = { 1, 22 };
int output_shape1[] = { 1, 60 };
int input_shape2[] = { 1, 60 };
int output_shape2[] = { 1, 1 };

double x[];
double y1[];
double y2[];

CTrade  trade;

input int H1;
input int H2;
input int H3;
input int H4;

input double Buy;
input double Buy1;
input double Sell;
input double Sell1;

input int LossBuy;
input int ProfitBuy;
input int LossSell;
input int ProfitSell;

ulong TicketBuy1;
ulong TicketSell0;

datetime Count;

bool send1;
bool send0;

int bars;

double stat_t1 = 0., stat_t2 = 0.;
ulong stat_predict_count = 0;

//string model_folder = "D:\\_Link\\MetaQuotes\\Terminal\\D0E8209F77C8CF37AD8BF550E51FF075\\MQL5\\Experts\\tf2\\models\\";
string model_folder = "models/";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
//---
#ifdef USE_PROLOG
  __logLevel__ = V_DEBUG;
  if ( !my::onInit() ) {
    return INIT_FAILED;
  }
#endif

  client.timeout(20.0);
  client.connect();

  model_Net1Max = new CModelZmq(GetPointer(client));
  model_Net1Min = new CModelZmq(GetPointer(client));
  model_Net2Max = new CModelZmq(GetPointer(client));
  model_Net2Min = new CModelZmq(GetPointer(client));

  if ( !model_Net1Max.init(
         model_folder + "net1Max.h5",
         input_shape1,
         output_shape1
       )) {
    ERROR("model Net1Max init failed");
    return (INIT_FAILED);
  }

  if ( !model_Net1Min.init(
         model_folder + "net1Min.h5",
         input_shape1,
         output_shape1
       )) {
    ERROR("model Net1Min init failed");
    return (INIT_FAILED);
  }

  if ( !model_Net2Max.init(
         model_folder + "net2Max.h5",
         input_shape2,
         output_shape2
       )) {
    ERROR("model Net2Max init failed");
    return (INIT_FAILED);
  }

  if ( !model_Net2Min.init(
         model_folder + "net2Min.h5",
         input_shape2,
         output_shape2
       )) {
    ERROR("model Net2Min init failed");
    return (INIT_FAILED);
  }

  ArrayResize(x,model_Net1Max.getInputSize());
  ArrayResize(y1,model_Net1Max.getOutputSize());
  ArrayResize(y2,model_Net2Max.getOutputSize());

  int deviation=10;
  trade.SetDeviationInPoints(deviation);
  trade.SetTypeFilling(ORDER_FILLING_RETURN);
  trade.SetAsyncMode(true);

//---
  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
//---
  INFO(StringFormat("STAT: sum time1 %f, sum time2 %f, count %d", stat_t1, stat_t2, stat_predict_count));
  if (stat_predict_count > 0)
  INFO(StringFormat("STAT: avg time1 %f, avg time2 %f", stat_t1 / stat_predict_count, stat_t2 / stat_predict_count));
  client.disconnect();
  if ( CheckPointer(model_Net1Max) == POINTER_DYNAMIC )
    delete model_Net1Max;
  if ( CheckPointer(model_Net1Min) == POINTER_DYNAMIC )
    delete model_Net1Min;
  if ( CheckPointer(model_Net2Max) == POINTER_DYNAMIC )
    delete model_Net2Max;
  if ( CheckPointer(model_Net2Min) == POINTER_DYNAMIC )
    delete model_Net2Min;
//---
#ifdef USE_PROLOG
  my::onDeinit();
#endif
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
//---
  string s = Symbol();
  ENUM_TIMEFRAMES tf = Period();

  if ( !nb.IsNewBar(s,tf) )
    return;

  static int K = 0;

  for(int i=0; i<=14; i++) {
    x[i]=x[i+5];
  }

  x[15]=((iOpen(NULL,PERIOD_D1,0)-iLow(NULL,PERIOD_D1,0))*100000);
  x[16]=((iHigh(NULL,PERIOD_D1,0)-iOpen(NULL,PERIOD_D1,0))*100000);
  x[17]=((iHigh(NULL,PERIOD_D1,0)-iLow(NULL,PERIOD_D1,0))*10000);
  x[18]=((iHigh(NULL,PERIOD_D1,0)-iOpen(NULL,PERIOD_H1,1))*10000);
  x[19]=((iOpen(NULL,PERIOD_H1,1)-iLow(NULL,PERIOD_D1,0))*10000);


  x[20]=((iHigh(NULL,PERIOD_D1,0)-iOpen(NULL,PERIOD_H1,0))*10000);
  x[21]=((iOpen(NULL,PERIOD_H1,0)-iLow(NULL,PERIOD_D1,0))*10000);
  
  if ( !model_Net1Max.predict(x,model_Net1Max.getInputSize(),y1,model_Net1Max.getOutputSize(),stat_t1,stat_t2) ) {
    ERROR("model Net1Max predict failed");
    return;
  }
  ++stat_predict_count;
  if ( !model_Net2Max.predict(y1,model_Net2Max.getInputSize(),y2,model_Net2Max.getOutputSize(),stat_t1,stat_t2) ) {
    ERROR("model Net2Max predict failed");
    return;
  }
  ++stat_predict_count;
  double _max = y2[0];

  if ( !model_Net1Min.predict(x,model_Net1Min.getInputSize(),y1,model_Net1Min.getOutputSize(),stat_t1,stat_t2) ) {
    ERROR("model Net1Min predict failed");
    return;
  }
  ++stat_predict_count;
  if ( !model_Net2Min.predict(y1,model_Net2Min.getInputSize(),y2,model_Net2Min.getOutputSize(),stat_t1,stat_t2) ) {
    ERROR("model Net2Min predict failed");
    return;
  }
  ++stat_predict_count;
  double _min = y2[0];

//---
  MqlDateTime stm;
  TimeToStruct(TimeCurrent(),stm);

  int    digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
  double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
  double PriceAsk=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  double PriceBid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

  double SL1=NormalizeDouble(PriceBid-LossBuy*point,digits);
  double TP1=NormalizeDouble(PriceAsk+ProfitBuy*point,digits);
  double SL0=NormalizeDouble(PriceAsk+LossSell*point,digits);
  double TP0=NormalizeDouble(PriceBid-ProfitSell*point,digits);

  if(LossBuy==0)
    SL1=0;

  if(ProfitBuy==0)
    TP1=0;

  if(LossSell==0)
    SL0=0;

  if(ProfitSell==0)
    TP0=0;

//---------Buy1
  if(send1==false && K>0 && _min>Buy && Buy>Buy1 && iLow(NULL,PERIOD_H1,1)<iLow(NULL,PERIOD_H1,2) && stm.hour>H1 && stm.hour<H2 && H1<H2) {
    send1=trade.PositionOpen(_Symbol,ORDER_TYPE_BUY,1,PriceAsk,SL1,TP1);//SL1,TP1
    TicketBuy1 = trade.ResultDeal();
  }

  if(send1==true && K>0 && _min<Buy1 &&  Buy>Buy1 && iHigh(NULL,PERIOD_H1,1)>iHigh(NULL,PERIOD_H1,2)) {
    trade.PositionClose(TicketBuy1);
    send1=false;
  }

//---------Sell0

  if(send0==false && K>0 &&  _max>Sell && Sell>Sell1 && iHigh(NULL,PERIOD_H1,1)>iHigh(NULL,PERIOD_H1,2) && stm.hour>H3 && stm.hour<H4 && H3<H4) {
    send0=trade.PositionOpen(_Symbol,ORDER_TYPE_SELL,1,PriceBid,SL0,TP0);//SL0,TP0
    TicketSell0 = trade.ResultDeal();
  }

  if(send0==true && K>0 &&  _max<Sell1 && Sell>Sell1 && iLow(NULL,PERIOD_H1,1)<iLow(NULL,PERIOD_H1,2)) {
    trade.PositionClose(TicketSell0);
    send0=false;
  }
  K++;
}

//+------------------------------------------------------------------+
