//+------------------------------------------------------------------+
//|                                          移动止损策略_Trend.mq5 |
//|                                                             hery |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "8.0.0"   // 高周期趋势定方向 + MA20重新站上/跌破入场 + 无反向翻仓
#include <Trade\Trade.mqh>
CTrade trade;

#define INVALID_POSITION_ID 0

enum ENUM_INIT_DIRECTION
{
   DIR_SHORT = 0,
   DIR_LONG  = 1
};

//===== 输入参数 =====
input ulong   InpMagicNumber     = 888151;
input double  LotShort           = 0.01;
input double  LotLong            = 0.01;

input double  TP_USD             = 32.0;
input double  SL_USD             = 16.0;

input double  BE_Activate_USD    = 18.0;
input double  BE_Lock_USD        = 10.0;

input double  Trail_Start_USD    = 22.0;
input double  Trail_TP_Dist      = 10.0;
input double  Max_TP_USD         = 70.0;

// 高周期趋势
input bool    UseTrendFilter     = true;
input ENUM_TIMEFRAMES TrendTF    = PERIOD_H1;
input int     MA_Period          = 50;
input ENUM_MA_METHOD MA_Method   = MODE_EMA;
input ENUM_APPLIED_PRICE MA_Price = PRICE_CLOSE;

// ★★★ MA20 入场确认（重新站上/跌破）★★★
input bool    UseMA20Entry       = true;     // 是否启用MA20入场过滤
input int     MA20_Period        = 20;       // MA20周期（M15）

input int     IntervalMinutes    = 5;
input int     RepeatGuardMin     = 2;
input double  TargetNetProfit    = 500;
input double  MaxDrawdownPct     = 35.0;

input bool    AvoidSwapWednesdayOnly = false;
input int     AvoidSwapBeforeMin     = 10;
input int     AvoidSwapAfterMin      = 10;
input bool    EnableWeekendTrading   = false;

//===== 全局变量 =====
datetime g_lastTradeTime = 0;
datetime g_nextTriggerTime = 0;
ulong    g_monitor_position_id = INVALID_POSITION_ID;
bool     g_target_reached = false;
bool     g_stop_on_drawdown = false;
ENUM_INIT_DIRECTION g_currentDirection = DIR_SHORT;

double   g_virtual_sl_price = 0.0;
double   g_virtual_tp_price = 0.0;
bool     g_be_activated = false;
bool     g_trail_activated = false;

bool     g_need_reopen_after_swap = false;
ENUM_INIT_DIRECTION g_reopen_direction = DIR_SHORT;

int      g_ma_handle = INVALID_HANDLE;    // 高周期均线
int      g_ma20_handle = INVALID_HANDLE;  // M15 MA20

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);

   if(UseTrendFilter)
   {
      g_ma_handle = iMA(_Symbol, TrendTF, MA_Period, 0, MA_Method, MA_Price);
      if(g_ma_handle == INVALID_HANDLE)
      {
         Print("高周期均线创建失败！错误码：", GetLastError());
         return INIT_FAILED;
      }
   }

   if(UseMA20Entry)
   {
      g_ma20_handle = iMA(_Symbol, PERIOD_CURRENT, MA20_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(g_ma20_handle == INVALID_HANDLE)
      {
         Print("MA20创建失败！错误码：", GetLastError());
         return INIT_FAILED;
      }
   }

   if(!EventSetTimer(1))
   {
      Print("定时器创建失败！错误码：", GetLastError());
      return INIT_PARAMETERS_INCORRECT;
   }

   g_nextTriggerTime = CalculateNextTriggerTime(TimeTradeServer());
   UpdateDirectionByTrend();

   PrintFormat("EA启动 v7.1.0【高周期趋势 + MA20重新站上/跌破入场】 | 趋势周期:%s | MA20:%d",
               EnumToString(TrendTF), MA20_Period);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_ma_handle != INVALID_HANDLE) IndicatorRelease(g_ma_handle);
   if(g_ma20_handle != INVALID_HANDLE) IndicatorRelease(g_ma20_handle);
}

//+------------------------------------------------------------------+
//| 高周期趋势更新方向                                                  |
//+------------------------------------------------------------------+
void UpdateDirectionByTrend()
{
   if(!UseTrendFilter || g_ma_handle == INVALID_HANDLE) return;

   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_ma_handle, 0, 0, 1, ma) <= 0) return;

   double maValue = ma[0];
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   ENUM_INIT_DIRECTION newDir = (tick.bid > maValue) ? DIR_LONG : DIR_SHORT;

   if(newDir != g_currentDirection)
   {
      PrintFormat("【方向更新】高周期趋势变化 → %s (均线%.5f)",
                  (newDir == DIR_LONG ? "做多" : "做空"), maValue);
      g_currentDirection = newDir;
   }
}

//+------------------------------------------------------------------+
//| ★★★ MA20 重新站上/跌破入场确认 ★★★                                |
//+------------------------------------------------------------------+
bool IsMA20EntrySignal()
{
   if(!UseMA20Entry) return true;   // 未启用则直接通过
   if(g_ma20_handle == INVALID_HANDLE) return true;

   double ma20[];
   ArraySetAsSeries(ma20, true);
   if(CopyBuffer(g_ma20_handle, 0, 0, 3, ma20) < 3) return false;

   // 使用已收盘的K线（index 1 和 2）
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1); // 最近一根已收盘
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2); // 再前一根

   if(g_currentDirection == DIR_LONG)
   {
      // 重新站上：前一根在MA20下方，最近一根收盘站上MA20
      bool signal = (close2 < ma20[2] && close1 > ma20[1]);
      if(!signal)
         PrintFormat("【MA20过滤】做多信号未确认（未重新站上） close2:%.5f ma:%.5f | close1:%.5f ma:%.5f",
                     close2, ma20[2], close1, ma20[1]);
      return signal;
   }
   else
   {
      // 重新跌破：前一根在MA20上方，最近一根收盘跌破MA20
      bool signal = (close2 > ma20[2] && close1 < ma20[1]);
      if(!signal)
         PrintFormat("【MA20过滤】做空信号未确认（未重新跌破） close2:%.5f ma:%.5f | close1:%.5f ma:%.5f",
                     close2, ma20[2], close1, ma20[1]);
      return signal;
   }
}

//+------------------------------------------------------------------+
string GetBaseSymbol(string fullSymbol)
{
   StringToUpper(fullSymbol);
   int dotPos = StringFind(fullSymbol, ".");
   if(dotPos > 0) return StringSubstr(fullSymbol, 0, dotPos);
   if(StringLen(fullSymbol) > 6) return StringSubstr(fullSymbol, 0, 6);
   return fullSymbol;
}

bool IsSameBaseSymbol(string a, string b)
{
   return (GetBaseSymbol(a) == GetBaseSymbol(b));
}

ulong GetLatestPositionID()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      }
   }
   return INVALID_POSITION_ID;
}

datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   int interval = MathMax(IntervalMinutes, 1);
   int nextMin = ((dt.min / interval) + 1) * interval;
   MqlDateTime nextDt = dt;
   nextDt.min = nextMin % 60;
   nextDt.hour += nextMin / 60;
   nextDt.sec = 0;
   datetime candidate = StructToTime(nextDt);

   while(candidate <= fromTime ||
         (!EnableWeekendTrading && (dt.day_of_week == 0 || dt.day_of_week == 6)))
   {
      if(candidate <= fromTime) candidate += interval * 60;
      else candidate += 3600;
      TimeToStruct(candidate, dt);
   }
   return candidate;
}

bool CheckHasAnyPendingOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderSelect(ticket) &&
         IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol) &&
         OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

bool CheckHasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket) &&
         IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL), _Symbol) &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

void SetTradeFillingMode()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & ORDER_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & ORDER_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

void StopEAAndClean()
{
   PrintFormat("【回撤保护】回撤达到 %.2f%%，终止EA并清仓", MaxDrawdownPct);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         trade.PositionClose(ticket);
         Sleep(200);
      }
   }
}

void CalculateMaxDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   static double highestEquity = 0.0;
   if(highestEquity == 0.0) highestEquity = equity;

   double ddPct = (highestEquity > 0.0) ? ((highestEquity - equity) / highestEquity) * 100.0 : 0.0;
   if(equity > highestEquity) highestEquity = equity;

   if(ddPct >= MaxDrawdownPct && !g_stop_on_drawdown)
   {
      g_stop_on_drawdown = true;
      StopEAAndClean();
   }
}

void CheckAndCloseAllPositions()
{
   CalculateMaxDrawdown();
   if(g_stop_on_drawdown) return;

   if(AccountInfoDouble(ACCOUNT_EQUITY) >= TargetNetProfit)
   {
      Print("【目标净值达成】全面清仓");
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket) &&
            PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            trade.PositionClose(ticket);
      }
      g_target_reached = true;
   }
}

void ExecuteShortOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double bid = tick.bid;
   g_be_activated = false;
   g_trail_activated = false;

   if(trade.Sell(LotShort, _Symbol, bid, 0, 0, "TrendSell"))
   {
      ulong deal = trade.ResultDeal();
      g_monitor_position_id = (deal > 0 && HistoryDealSelect(deal)) ?
                              (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) : GetLatestPositionID();

      g_virtual_sl_price = NormalizeDouble(bid + SL_USD, _Digits);
      g_virtual_tp_price = NormalizeDouble(bid - TP_USD, _Digits);

      PrintFormat("【做空成功】ID:%I64u 开仓价:%.5f SL:%.5f TP:%.5f",
                  g_monitor_position_id, bid, g_virtual_sl_price, g_virtual_tp_price);
   }
}

void ExecuteLongOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double ask = tick.ask;
   g_be_activated = false;
   g_trail_activated = false;

   if(trade.Buy(LotLong, _Symbol, ask, 0, 0, "TrendBuy"))
   {
      ulong deal = trade.ResultDeal();
      g_monitor_position_id = (deal > 0 && HistoryDealSelect(deal)) ?
                              (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) : GetLatestPositionID();

      g_virtual_sl_price = NormalizeDouble(ask - SL_USD, _Digits);
      g_virtual_tp_price = NormalizeDouble(ask + TP_USD, _Digits);

      PrintFormat("【做多成功】ID:%I64u 开仓价:%.5f SL:%.5f TP:%.5f",
                  g_monitor_position_id, ask, g_virtual_sl_price, g_virtual_tp_price);
   }
}

void CheckVirtualStopsAndClose()
{
   if(g_monitor_position_id == INVALID_POSITION_ID) return;

   bool found = false;
   ulong posTicket = 0;
   long  posType = -1;
   double openPrice = 0.0, currentPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt > 0 && PositionSelectByTicket(pt) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetInteger(POSITION_IDENTIFIER) == (long)g_monitor_position_id)
      {
         found = true;
         posTicket = pt;
         posType = PositionGetInteger(POSITION_TYPE);
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         currentPrice = (posType == POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         break;
      }
   }

   if(!found)
   {
      g_monitor_position_id = INVALID_POSITION_ID;
      g_virtual_sl_price = 0.0;
      g_virtual_tp_price = 0.0;
      g_be_activated = false;
      g_trail_activated = false;
      return;
   }

   double floating = (posType == POSITION_TYPE_BUY) ?
                     (currentPrice - openPrice) : (openPrice - currentPrice);

   // 保本
   if(!g_be_activated && floating >= BE_Activate_USD)
   {
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(openPrice + BE_Lock_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(openPrice - BE_Lock_USD, _Digits);
      g_be_activated = true;
      PrintFormat("【保本】ID:%I64u 浮盈:%.2f → SL锁定到 %.5f", g_monitor_position_id, floating, g_virtual_sl_price);
   }

   // 启动锁定
   if(!g_trail_activated && floating >= Trail_Start_USD)
   {
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(openPrice + Trail_Start_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(openPrice - Trail_Start_USD, _Digits);
      g_trail_activated = true;
      PrintFormat("【启动锁定】ID:%I64u 浮盈:%.2f → SL锁定到 %.5f", g_monitor_position_id, floating, g_virtual_sl_price);
   }

   // 继续移动止损
   if(posType == POSITION_TYPE_BUY)
   {
      double newSL = NormalizeDouble(currentPrice - SL_USD, _Digits);
      if(newSL > g_virtual_sl_price)
         g_virtual_sl_price = newSL;
   }
   else
   {
      double newSL = NormalizeDouble(currentPrice + SL_USD, _Digits);
      if(newSL < g_virtual_sl_price || g_virtual_sl_price <= 0)
         g_virtual_sl_price = newSL;
   }

   // 移动止盈
   if(g_trail_activated)
   {
      if(posType == POSITION_TYPE_BUY)
      {
         double newTP = NormalizeDouble(currentPrice + Trail_TP_Dist, _Digits);
         double maxTP = NormalizeDouble(openPrice + Max_TP_USD, _Digits);
         if(newTP > g_virtual_tp_price)
            g_virtual_tp_price = MathMin(newTP, maxTP);
      }
      else
      {
         double newTP = NormalizeDouble(currentPrice - Trail_TP_Dist, _Digits);
         double maxTP = NormalizeDouble(openPrice - Max_TP_USD, _Digits);
         if(newTP < g_virtual_tp_price || g_virtual_tp_price <= 0)
            g_virtual_tp_price = MathMax(newTP, maxTP);
      }
   }

   // 检查触发
   bool hitTP = false, hitSL = false;
   if(posType == POSITION_TYPE_BUY)
   {
      if(g_virtual_tp_price > 0 && currentPrice >= g_virtual_tp_price) hitTP = true;
      if(g_virtual_sl_price > 0 && currentPrice <= g_virtual_sl_price) hitSL = true;
   }
   else
   {
      if(g_virtual_tp_price > 0 && currentPrice <= g_virtual_tp_price) hitTP = true;
      if(g_virtual_sl_price > 0 && currentPrice >= g_virtual_sl_price) hitSL = true;
   }

   if(hitTP || hitSL)
   {
      string reason = hitTP ? "止盈" : "止损";
      PrintFormat("【平仓】%s | ID:%I64u 现价:%.5f TP:%.5f SL:%.5f",
                  reason, g_monitor_position_id, currentPrice, g_virtual_tp_price, g_virtual_sl_price);

      if(trade.PositionClose(posTicket))
      {
         g_monitor_position_id = INVALID_POSITION_ID;
         g_virtual_sl_price = 0.0;
         g_virtual_tp_price = 0.0;
         g_be_activated = false;
         g_trail_activated = false;
      }
   }
}

void MonitorPositionStatus()
{
   CheckVirtualStopsAndClose();
}

bool IsInSwapAvoidWindow(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   if(AvoidSwapWednesdayOnly)
   {
      if(dt.day_of_week == 3 && dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      if(dt.day_of_week == 4 && dt.hour == 0 && dt.min < AvoidSwapAfterMin) return true;
      return false;
   }
   return (dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) ||
          (dt.hour == 0  && dt.min < AvoidSwapAfterMin);
}

bool IsInPreSwapWindow(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   if(AvoidSwapWednesdayOnly)
      return (dt.day_of_week == 3 && dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin));
   return (dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin));
}

void ScanAndCloseProfitablePositions()
{
   bool has = false;
   ENUM_INIT_DIRECTION lastDir = DIR_SHORT;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      if(PositionGetDouble(POSITION_PROFIT) > 8.0)
      {
         has = true;
         lastDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
         trade.PositionClose(ticket);
         Sleep(150);
      }
   }

   if(has)
   {
      g_need_reopen_after_swap = true;
      g_reopen_direction = lastDir;
      g_monitor_position_id = INVALID_POSITION_ID;
      g_virtual_sl_price = 0.0;
      g_virtual_tp_price = 0.0;
      g_be_activated = false;
      g_trail_activated = false;
   }
}

bool HasSkipOpenSignal()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(!IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol) ||
         OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;

      string cmt = OrderGetString(ORDER_COMMENT);
      if(StringFind(cmt, "SKIP") >= 0 || StringFind(cmt, "暂停") >= 0)
      {
         trade.OrderDelete(ticket);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 定时器主逻辑                                                        |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeTradeServer();
   if(g_stop_on_drawdown || g_target_reached) return;

   CheckAndCloseAllPositions();
   if(g_target_reached) return;

   MonitorPositionStatus();

   if(IsInSwapAvoidWindow(now))
   {
      if(IsInPreSwapWindow(now))
         ScanAndCloseProfitablePositions();
      g_nextTriggerTime = CalculateNextTriggerTime(now);
      return;
   }

   if(g_need_reopen_after_swap)
   {
      if(!CheckHasAnyPendingOrder() && !CheckHasAnyPosition() && !HasSkipOpenSignal())
      {
         UpdateDirectionByTrend();
         g_currentDirection = g_reopen_direction;
         if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
         else ExecuteLongOrder();
         g_lastTradeTime = now;
         g_need_reopen_after_swap = false;
      }
      g_nextTriggerTime = CalculateNextTriggerTime(now);
      return;
   }

   if(!EnableWeekendTrading)
   {
      MqlDateTime dt;
      TimeToStruct(now, dt);
      if(dt.day_of_week == 0 || dt.day_of_week == 6)
      {
         g_nextTriggerTime = CalculateNextTriggerTime(now);
         return;
      }
   }

   if(now < g_nextTriggerTime) return;
   if(now - g_nextTriggerTime > 5)
   {
      g_nextTriggerTime = CalculateNextTriggerTime(now);
      return;
   }

   datetime next = CalculateNextTriggerTime(now);

   if(now - g_lastTradeTime < RepeatGuardMin * 60)
   {
      g_nextTriggerTime = next;
      return;
   }

   if(CheckHasAnyPendingOrder() || CheckHasAnyPosition() || HasSkipOpenSignal())
   {
      g_nextTriggerTime = next;
      return;
   }

   // 1. 更新高周期方向
   UpdateDirectionByTrend();

   // 2. MA20 重新站上/跌破确认
   if(!IsMA20EntrySignal())
   {
      PrintFormat("【入场过滤】时间:%s MA20信号未确认，跳过本次开仓", TimeToString(now, TIME_DATE|TIME_MINUTES));
      g_nextTriggerTime = next;
      return;
   }

   // 3. 开仓
   if(g_currentDirection == DIR_SHORT)
      ExecuteShortOrder();
   else
      ExecuteLongOrder();

   g_lastTradeTime = now;
   g_nextTriggerTime = next;
}
//+------------------------------------------------------------------+