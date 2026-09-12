//+------------------------------------------------------------------+
//|                                          移动止损策略_Trend.mq5 |
//|                                                             hery |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "7.0.0"   // 方案A：高周期趋势定方向 + 完全取消反向翻仓
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

input double  TP_USD             = 32.0;      // 初始固定止盈
input double  SL_USD             = 16.0;      // 初始移动止损距离

// 保本（第一层，已延后）
input double  BE_Activate_USD    = 18.0;      // 浮盈达到此值启动保本
input double  BE_Lock_USD        = 10.0;       // 保本锁定利润

// 启动锁定 + 移动止盈（第二层，已延后）
input double  Trail_Start_USD    = 22.0;      // 浮盈达到此值锁定止损并启动移动止盈
input double  Trail_TP_Dist      = 10.0;      // 移动止盈跟随距离
input double  Max_TP_USD         = 70.0;      // 最大止盈限制

// 高周期趋势过滤（方案A核心）
input bool    UseTrendFilter     = true;
input ENUM_TIMEFRAMES TrendTF    = PERIOD_H1; // 推荐H1，更稳可用H4
input int     MA_Period          = 50;
input ENUM_MA_METHOD MA_Method   = MODE_EMA;
input ENUM_APPLIED_PRICE MA_Price = PRICE_CLOSE;

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

int      g_ma_handle = INVALID_HANDLE;

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

   if(!EventSetTimer(1))
   {
      Print("定时器创建失败！错误码：", GetLastError());
      return INIT_PARAMETERS_INCORRECT;
   }

   g_nextTriggerTime = CalculateNextTriggerTime(TimeTradeServer());
   UpdateDirectionByTrend();   // 初始化方向

   PrintFormat("EA启动 v4.0.0【高周期趋势定方向 + 无反向翻仓】 | 趋势周期:%s | 均线:%d",
               EnumToString(TrendTF), MA_Period);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_ma_handle != INVALID_HANDLE)
      IndicatorRelease(g_ma_handle);
}

//+------------------------------------------------------------------+
//| 方案A核心：用高周期均线更新交易方向                                 |
//+------------------------------------------------------------------+
void UpdateDirectionByTrend()
{
   if(!UseTrendFilter || g_ma_handle == INVALID_HANDLE)
      return;

   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_ma_handle, 0, 0, 1, ma) <= 0)
      return;

   double maValue = ma[0];
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   ENUM_INIT_DIRECTION newDir;
   if(tick.bid > maValue)
      newDir = DIR_LONG;
   else
      newDir = DIR_SHORT;

   if(newDir != g_currentDirection)
   {
      PrintFormat("【方向更新】高周期趋势变化 → %s (均线%.5f)",
                  (newDir == DIR_LONG ? "做多" : "做空"), maValue);
      g_currentDirection = newDir;
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
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket) &&
         OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         trade.OrderDelete(ticket);
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

//+------------------------------------------------------------------+
//| 开仓（已无反向逻辑）                                                |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| 核心：虚拟止损止盈 + 保本 + 启动锁定 + 移动止盈                      |
//+------------------------------------------------------------------+
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
      // 持仓已不存在，清理
      g_monitor_position_id = INVALID_POSITION_ID;
      g_virtual_sl_price = 0.0;
      g_virtual_tp_price = 0.0;
      g_be_activated = false;
      g_trail_activated = false;
      return;
   }

   double floating = (posType == POSITION_TYPE_BUY) ?
                     (currentPrice - openPrice) : (openPrice - currentPrice);

   // 第一层：保本
   if(!g_be_activated && floating >= BE_Activate_USD)
   {
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(openPrice + BE_Lock_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(openPrice - BE_Lock_USD, _Digits);
      g_be_activated = true;
      PrintFormat("【保本】ID:%I64u 浮盈:%.2f → SL锁定到 %.5f", g_monitor_position_id, floating, g_virtual_sl_price);
   }

   // 第二层：启动锁定 + 开始移动止盈
   if(!g_trail_activated && floating >= Trail_Start_USD)
   {
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(openPrice + Trail_Start_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(openPrice - Trail_Start_USD, _Digits);
      g_trail_activated = true;
      PrintFormat("【启动锁定】ID:%I64u 浮盈:%.2f → SL锁定到 %.5f，开始移动止盈", g_monitor_position_id, floating, g_virtual_sl_price);
   }

   // 继续移动止损（模式A）
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

   // 移动止盈 + 最大限制
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

//+------------------------------------------------------------------+
//| 库存费相关（保持原有）                                              |
//+------------------------------------------------------------------+
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

   // 库存费窗口
   if(IsInSwapAvoidWindow(now))
   {
      if(IsInPreSwapWindow(now))
         ScanAndCloseProfitablePositions();
      g_nextTriggerTime = CalculateNextTriggerTime(now);
      return;
   }

   // 库存费后重开
   if(g_need_reopen_after_swap)
   {
      if(!CheckHasAnyPendingOrder() && !CheckHasAnyPosition() && !HasSkipOpenSignal())
      {
         UpdateDirectionByTrend();
         g_currentDirection = g_reopen_direction;  // 优先用之前盈利方向，也可改成强制用趋势
         if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
         else ExecuteLongOrder();
         g_lastTradeTime = now;
         g_need_reopen_after_swap = false;
      }
      g_nextTriggerTime = CalculateNextTriggerTime(now);
      return;
   }

   // 周末过滤
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

   // ★ 方案A：开仓前用高周期趋势更新方向
   UpdateDirectionByTrend();

   if(g_currentDirection == DIR_SHORT)
      ExecuteShortOrder();
   else
      ExecuteLongOrder();

   g_lastTradeTime = now;
   g_nextTriggerTime = next;
}
//+------------------------------------------------------------------+