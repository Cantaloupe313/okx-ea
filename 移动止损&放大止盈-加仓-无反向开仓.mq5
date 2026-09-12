//+------------------------------------------------------------------+
//|                                          移动止损策略_Trend.mq5 |
//|                                                             hery |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "9.1.0"   // 方案A + 硬锁后切换更紧追踪距离
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
input double  SL_USD             = 22.0;      // 初始移动止损距离
// 保本（第一层）
input double  BE_Activate_USD    = 13.0;      // 浮盈达到此值启动保本
input double  BE_Lock_USD        = 6.0;      // 保本锁定利润
// 启动锁定 + 移动止盈（第二层）
input double  Trail_Start_USD    = 22.0;      // 浮盈达到此值锁定止损并启动移动止盈
input double  Trail_SL_Dist_After= 8.0;       // 锁定利润后的止损跟随距离（更紧）
input double  Trail_TP_Dist      = 10.0;      // 移动止盈跟随距离
input double  Max_TP_USD         = 70.0;      // 最大止盈限制
// 高周期趋势过滤（方案A核心）
input bool    UseTrendFilter     = true;
input ENUM_TIMEFRAMES TrendTF    = PERIOD_H1;
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
//===== 保守加仓参数 =====
input bool   EnableAddPos        = true;
input int    MaxAddTimes         = 1;
input double AddLotSize          = 0.01;
input double AddActivate_USD     = 15.0;
input double MaxTotalLots        = 0.03;
input bool   AddOnlyInTrend      = true;
input double AddBE_Lock_USD      = 8.0;
//===== 全局变量 =====
int      g_add_count          = 0;
double   g_main_lot           = 0.0;
double   g_avg_open_price     = 0.0;
double   g_total_lots         = 0.0;
datetime g_lastTradeTime      = 0;
datetime g_nextTriggerTime    = 0;
ulong    g_monitor_position_id = INVALID_POSITION_ID;
bool     g_target_reached     = false;
bool     g_stop_on_drawdown   = false;
ENUM_INIT_DIRECTION g_currentDirection = DIR_SHORT;
double   g_virtual_sl_price   = 0.0;
double   g_virtual_tp_price   = 0.0;
bool     g_be_activated       = false;
bool     g_trail_activated    = false;
bool     g_need_reopen_after_swap = false;
ENUM_INIT_DIRECTION g_reopen_direction = DIR_SHORT;
int      g_ma_handle          = INVALID_HANDLE;
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
   UpdateDirectionByTrend();
   PrintFormat("EA启动 v9.1.0【硬锁+更紧追踪】 | 趋势周期:%s | 均线:%d | 锁定后追踪距离:%.1f",
               EnumToString(TrendTF), MA_Period, Trail_SL_Dist_After);
   return INIT_SUCCEEDED;
}
// 计算当前同方向所有仓位的总手数、平均开仓价、总浮盈
bool GetBasketInfo(long posType, double &avgPrice, double &totalLots, double &totalProfit)
{
   avgPrice = 0.0;
   totalLots = 0.0;
   totalProfit = 0.0;
   double sumPriceLots = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE) != posType) continue;
      
      double lots = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      sumPriceLots += open * lots;
      totalLots    += lots;
      totalProfit  += PositionGetDouble(POSITION_PROFIT);
   }
   
   if(totalLots <= 0) return false;
   avgPrice = sumPriceLots / totalLots;
   return true;
}
// 检查是否满足加仓条件并执行（保守版：只加一次）
void CheckAndAddPosition()
{
   if(!EnableAddPos || g_add_count >= MaxAddTimes) return;
   if(g_monitor_position_id == INVALID_POSITION_ID) return;
   
   long posType = -1;
   double mainOpen = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt > 0 && PositionSelectByTicket(pt) &&
         PositionGetInteger(POSITION_IDENTIFIER) == (long)g_monitor_position_id)
      {
         posType = PositionGetInteger(POSITION_TYPE);
         mainOpen = PositionGetDouble(POSITION_PRICE_OPEN);
         g_main_lot = PositionGetDouble(POSITION_VOLUME);
         break;
      }
   }
   if(posType < 0) return;
   
   double avgPrice, totalLots, totalProfit;
   if(!GetBasketInfo(posType, avgPrice, totalLots, totalProfit)) return;
   
   if(totalLots >= MaxTotalLots) return;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   if(totalProfit < AddActivate_USD) return;
   
   if(AddOnlyInTrend)
   {
      UpdateDirectionByTrend();
      if((posType == POSITION_TYPE_BUY && g_currentDirection != DIR_LONG) ||
         (posType == POSITION_TYPE_SELL && g_currentDirection != DIR_SHORT))
         return;
   }
   
   double addLots = NormalizeDouble(AddLotSize, 2);
   if(addLots < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) return;
   if(totalLots + addLots > MaxTotalLots) addLots = MaxTotalLots - totalLots;
   if(addLots <= 0) return;
   
   SetTradeFillingMode();
   bool success = false;
   if(posType == POSITION_TYPE_BUY)
      success = trade.Buy(addLots, _Symbol, tick.ask, 0, 0, "TrendAdd");
   else
      success = trade.Sell(addLots, _Symbol, tick.bid, 0, 0, "TrendAdd");
   
   if(success)
   {
      g_add_count++;
      GetBasketInfo(posType, g_avg_open_price, g_total_lots, totalProfit);
      
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(g_avg_open_price + AddBE_Lock_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(g_avg_open_price - AddBE_Lock_USD, _Digits);
      
      g_be_activated = true;
      PrintFormat("【保守加仓成功】第%d次 | 加仓手数:%.2f | 新平均价:%.5f | 整仓SL移至:%.5f",
                  g_add_count, addLots, g_avg_open_price, g_virtual_sl_price);
   }
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_ma_handle != INVALID_HANDLE)
      IndicatorRelease(g_ma_handle);
}
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
   ENUM_INIT_DIRECTION newDir;
   if(tick.bid > maValue) newDir = DIR_LONG;
   else                   newDir = DIR_SHORT;
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
      g_add_count = 0;
      g_avg_open_price = 0.0;
      g_total_lots = 0.0;
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
      g_add_count = 0;
      g_avg_open_price = 0.0;
      g_total_lots = 0.0;
      PrintFormat("【做多成功】ID:%I64u 开仓价:%.5f SL:%.5f TP:%.5f",
                  g_monitor_position_id, ask, g_virtual_sl_price, g_virtual_tp_price);
   }
}
//+------------------------------------------------------------------+
//| 核心：虚拟止损止盈 + 保本 + 硬锁 + 两阶段移动止损 + 移动止盈（支持整仓） |
//+------------------------------------------------------------------+
void CheckVirtualStopsAndClose()
{
   if(g_monitor_position_id == INVALID_POSITION_ID) return;

   // 找到当前监控方向
   long posType = -1;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt > 0 && PositionSelectByTicket(pt) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetInteger(POSITION_IDENTIFIER) == (long)g_monitor_position_id)
      {
         posType = PositionGetInteger(POSITION_TYPE);
         found = true;
         break;
      }
   }
   // 兼容加仓后主仓ID可能变化的情况
   if(!found)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong pt = PositionGetTicket(i);
         if(pt > 0 && PositionSelectByTicket(pt) &&
            PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            posType = PositionGetInteger(POSITION_TYPE);
            found = true;
            g_monitor_position_id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
            break;
         }
      }
   }
   if(!found || posType < 0)
   {
      g_monitor_position_id = INVALID_POSITION_ID;
      g_virtual_sl_price     = 0.0;
      g_virtual_tp_price     = 0.0;
      g_be_activated         = false;
      g_trail_activated      = false;
      g_add_count            = 0;
      g_avg_open_price       = 0.0;
      g_total_lots           = 0.0;
      return;
   }

   // 获取整仓信息
   double avgPrice = 0.0, totalLots = 0.0, totalProfit = 0.0;
   if(!GetBasketInfo(posType, avgPrice, totalLots, totalProfit))
   {
      g_monitor_position_id = INVALID_POSITION_ID;
      return;
   }
   g_avg_open_price = avgPrice;
   g_total_lots     = totalLots;

   double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 使用真实总浮盈（USD）判断层级
   double floating = totalProfit;

   //===== 第一层：保本 =====
   if(!g_be_activated && floating >= BE_Activate_USD)
   {
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(avgPrice + BE_Lock_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(avgPrice - BE_Lock_USD, _Digits);
      g_be_activated = true;
      PrintFormat("【保本】整仓浮盈:%.2f → SL锁定到 %.5f (均价%.5f)", floating, g_virtual_sl_price, avgPrice);
   }

   //===== 第二层：硬性锁定 + 切换更紧追踪距离 =====
   if(!g_trail_activated && floating >= Trail_Start_USD)
   {
      // 1. 硬性至少锁到均价 ± Trail_Start_USD
      if(posType == POSITION_TYPE_BUY)
         g_virtual_sl_price = NormalizeDouble(avgPrice + Trail_Start_USD, _Digits);
      else
         g_virtual_sl_price = NormalizeDouble(avgPrice - Trail_Start_USD, _Digits);

      // 2. 立刻用更紧距离基于当前价刷新一次，消除空窗期
      double newSL = (posType == POSITION_TYPE_BUY) ?
                     NormalizeDouble(currentPrice - Trail_SL_Dist_After, _Digits) :
                     NormalizeDouble(currentPrice + Trail_SL_Dist_After, _Digits);

      if(posType == POSITION_TYPE_BUY)
      {
         if(newSL > g_virtual_sl_price)
            g_virtual_sl_price = newSL;
      }
      else
      {
         if(newSL < g_virtual_sl_price || g_virtual_sl_price <= 0)
            g_virtual_sl_price = newSL;
      }

      g_trail_activated = true;
      PrintFormat("【启动锁定+紧追踪】整仓浮盈:%.2f → SL=%.5f，之后用%.1f距离追踪",
                  floating, g_virtual_sl_price, Trail_SL_Dist_After);
   }

   //===== 持续移动止损（两阶段）=====
   // 未启动前用 SL_USD，启动后用更紧的 Trail_SL_Dist_After
   double trailDist = g_trail_activated ? Trail_SL_Dist_After : SL_USD;

   if(posType == POSITION_TYPE_BUY)
   {
      double newSL = NormalizeDouble(currentPrice - trailDist, _Digits);
      if(newSL > g_virtual_sl_price)
         g_virtual_sl_price = newSL;
   }
   else
   {
      double newSL = NormalizeDouble(currentPrice + trailDist, _Digits);
      if(newSL < g_virtual_sl_price || g_virtual_sl_price <= 0)
         g_virtual_sl_price = newSL;
   }

   //===== 移动止盈 + 最大限制（仅启动锁定后生效）=====
   if(g_trail_activated)
   {
      if(posType == POSITION_TYPE_BUY)
      {
         double newTP = NormalizeDouble(currentPrice + Trail_TP_Dist, _Digits);
         double maxTP = NormalizeDouble(avgPrice + Max_TP_USD, _Digits);
         if(newTP > g_virtual_tp_price)
            g_virtual_tp_price = MathMin(newTP, maxTP);
      }
      else
      {
         double newTP = NormalizeDouble(currentPrice - Trail_TP_Dist, _Digits);
         double maxTP = NormalizeDouble(avgPrice - Max_TP_USD, _Digits);
         if(newTP < g_virtual_tp_price || g_virtual_tp_price <= 0)
            g_virtual_tp_price = MathMax(newTP, maxTP);
      }
   }

   //===== 检查触发 =====
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
      PrintFormat("【整仓平仓】%s | 均价:%.5f 现价:%.5f TP:%.5f SL:%.5f 总浮盈:%.2f",
                  reason, avgPrice, currentPrice, g_virtual_tp_price, g_virtual_sl_price, totalProfit);

      // 一次性平掉所有同方向同magic仓位
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket) &&
            PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_TYPE) == posType)
         {
            trade.PositionClose(ticket);
            Sleep(150);
         }
      }

      // 清理状态
      g_monitor_position_id = INVALID_POSITION_ID;
      g_virtual_sl_price     = 0.0;
      g_virtual_tp_price     = 0.0;
      g_be_activated         = false;
      g_trail_activated      = false;
      g_add_count            = 0;
      g_avg_open_price       = 0.0;
      g_total_lots           = 0.0;
   }
}
void MonitorPositionStatus()
{
   CheckVirtualStopsAndClose();
}
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
      g_add_count      = 0;
      g_avg_open_price = 0.0;
      g_total_lots     = 0.0;
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
void OnTimer()
{
   datetime now = TimeTradeServer();
   if(g_stop_on_drawdown || g_target_reached) return;
   CheckAndCloseAllPositions();
   if(g_target_reached) return;
   MonitorPositionStatus();
   CheckAndAddPosition();

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

   UpdateDirectionByTrend();
   if(g_currentDirection == DIR_SHORT)
      ExecuteShortOrder();
   else
      ExecuteLongOrder();
   g_lastTradeTime = now;
   g_nextTriggerTime = next;
}
//+------------------------------------------------------------------+