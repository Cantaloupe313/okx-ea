//+------------------------------------------------------------------+
//|                                                    移动止损策略.mq5 |
//|                                                             hery |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "6.0.1"   // ★ 升级：保本+启动锁定+移动止盈+均线方向过滤
#include <Trade\Trade.mqh> 
CTrade trade;

#define INVALID_POSITION_ID 0
#define INVALID_ORDER_TICKET 0

enum ENUM_INIT_DIRECTION
{
   DIR_SHORT = 0,  // 初始做空
   DIR_LONG  = 1   // 初始做多
};

//===== 外部参数 =====
input ulong   InpMagicNumber     = 888151;  // EA魔术码(用于区分订单)
input ENUM_INIT_DIRECTION InitialDirection = DIR_SHORT; // 初始方向
input double LotShort           = 0.01;   // 初始做空手数
input double LotLong            = 0.01;   // 初始做多手数
input double LotLongReverse     = 0.01;   // 做空止损反向多单手数
input double LotShortReverse    = 0.01;   // 做多止损反向空手数
input double TP_USD             = 28;    // 止盈(美元，XAUUSD价格差)
input double SL_USD             = 20;    // 初始单移动止损价差（固定价差）
input double REV_SL_USD         = 20;    // 反向单移动止损价差（固定价差）
input double REV_TP_USD         = 28;   // 反向单止盈价差，默认18
input double BE_Activate_USD    = 5.0;   // 浮盈达到多少点后启动保本锁利
input double BE_Lock_USD        = 2.0;  // 保本锁定利润点数（开仓价±此值）

// 移动止盈相关
input double Trail_Start_USD    = 16.0;  // 初始单：启动移动止盈的浮盈阈值
input double Trail_Start_REV    = 16.0;  // 反向单：启动移动止盈的浮盈阈值
input double Trail_TP_Dist      = 12.0;  // 移动止盈跟随距离
input double Max_TP_USD         = 80.0;  // 最大止盈限制

// ★★★ 均线方向过滤参数 ★★★
input bool   UseTrendFilter     = true;           // 是否启用均线方向过滤
input int    MA_Period          = 50;             // 均线周期
input ENUM_MA_METHOD MA_Method  = MODE_EMA;       // 均线类型
input ENUM_APPLIED_PRICE MA_Price = PRICE_CLOSE;  // 应用价格

input int    IntervalMinutes    = 15;           // 开仓间隔(分钟)
input int    RepeatGuardMin     = 2;    // 防重复间隔(分钟)
input int    CancelDelaySec     = 5;   // 延迟撤单秒数（已基本不用，保留兼容）
input double TargetNetProfit    = 500;   // 目标净值(达到后全部平仓并停止)
input double MaxDrawdownPct     = 50.0;   // 最大回撤率(%)，达到后终止EA并清仓
input bool   ReverseDirectionAfterSL = true;   // 初始单止损 + 反向单止盈后，是否反转方向

input bool   AvoidSwapWednesdayOnly = false;  // 是否仅在周三深夜规避库存费
input int    AvoidSwapBeforeMin     = 10;  // 距离扣除库存费前多少分钟开始扫描
input int    AvoidSwapAfterMin      = 10;  // 扣除库存费后恢复时间(分钟)
input bool   EnableWeekendTrading   = false;  // 是否开启周末定时开仓

//===== 全局变量 =====
datetime g_lastTradeTime = 0;
datetime g_nextTriggerTime = 0;
ulong    g_monitor_position_id = INVALID_POSITION_ID;
ulong    g_reverse_order_ticket = INVALID_ORDER_TICKET;
datetime g_pending_cancel_time = 0;
bool     g_target_reached = false;
double   g_max_drawdown = 0.0;
bool     g_stop_on_drawdown = false;
ENUM_INIT_DIRECTION g_currentDirection = DIR_SHORT;
bool     g_monitoring_reverse_position = false;
datetime g_pending_reverse_check_time = 0;
double   g_reverse_tp_price = 0.0;
double   g_reverse_sl_price = 0.0;
double   g_virtual_sl_price = 0.0;
double   g_virtual_tp_price = 0.0;
bool     g_last_close_was_tp = false;
bool     g_be_activated = false;
bool     g_trail_activated = false;
bool                 g_need_reopen_after_swap = false;
ENUM_INIT_DIRECTION  g_reopen_direction       = DIR_SHORT;

int      g_ma_handle = INVALID_HANDLE;   // ★ 均线句柄

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // ★ 创建均线指标
   if(UseTrendFilter)
   {
      g_ma_handle = iMA(_Symbol, PERIOD_CURRENT, MA_Period, 0, MA_Method, MA_Price);
      if(g_ma_handle == INVALID_HANDLE)
      {
         Print("均线指标创建失败！错误码：", GetLastError());
         return INIT_FAILED;
      }
   }
   
   if(!EventSetTimer(1))
   {
      Print("定时器创建失败！错误码：", GetLastError());
      return INIT_PARAMETERS_INCORRECT;
   }
   g_nextTriggerTime = CalculateNextTriggerTime(TimeTradeServer());
   g_currentDirection = InitialDirection;
   
   string filterStr = UseTrendFilter ? "均线方向过滤已启用" : "均线方向过滤已关闭";
   if(g_currentDirection == DIR_SHORT)
      PrintFormat("EA启动 v3.3.0【保本+启动锁定+移动止盈+均线过滤】规则：定时自动做空 | 间隔:%d分钟 | %s", IntervalMinutes, filterStr);
   else
      PrintFormat("EA启动 v3.3.0【保本+启动锁定+移动止盈+均线过滤】规则：定时自动做多 | 间隔:%d分钟 | %s", IntervalMinutes, filterStr);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_ma_handle != INVALID_HANDLE)
      IndicatorRelease(g_ma_handle);
}

//+------------------------------------------------------------------+
//| ★★★ 均线方向过滤函数 ★★★                                          |
//+------------------------------------------------------------------+
bool IsTrendAligned()
{
   if(!UseTrendFilter) return true;   // 未启用则直接通过
   
   if(g_ma_handle == INVALID_HANDLE) return true;  // 安全保护
   
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_ma_handle, 0, 0, 1, ma) <= 0)
   {
      Print("【趋势过滤】获取均线数据失败，本次允许开仓");
      return true;  // 失败时默认允许，避免错过机会
   }
   
   double maValue = ma[0];
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return true;
   
   if(g_currentDirection == DIR_LONG)
   {
      // 做多时，要求价格在均线上方
      bool aligned = (tick.ask > maValue);
      if(!aligned)
         PrintFormat("【趋势过滤】当前做多，但价格%.5f < 均线%.5f，跳过开仓", tick.ask, maValue);
      return aligned;
   }
   else
   {
      // 做空时，要求价格在均线下方
      bool aligned = (tick.bid < maValue);
      if(!aligned)
         PrintFormat("【趋势过滤】当前做空，但价格%.5f > 均线%.5f，跳过开仓", tick.bid, maValue);
      return aligned;
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
bool IsSameBaseSymbol(string symbolA, string symbolB)
{
   return (GetBaseSymbol(symbolA) == GetBaseSymbol(symbolB));
}

ulong GetLatestPositionID()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0 && PositionSelectByTicket(posTicket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return PositionGetInteger(POSITION_IDENTIFIER);
      }
   }
   return INVALID_POSITION_ID;
}

datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   int interval = IntervalMinutes;
   if(interval < 1) interval = 1;
   int nextMin = ((dt.min / interval) + 1) * interval;
   MqlDateTime nextDt = dt;
   nextDt.min = nextMin % 60;
   nextDt.hour += nextMin / 60;
   nextDt.sec = 0;
   datetime candidate = StructToTime(nextDt);
   while(candidate <= fromTime ||
         (!EnableWeekendTrading && (dt.day_of_week == 0 || dt.day_of_week == 6)))
   {
      if(candidate <= fromTime)
         candidate += interval * 60;
      else
         candidate += 3600;
      TimeToStruct(candidate, dt);
   }
   return candidate;
}

bool CheckHasAnyPendingOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      if(OrderSelect(orderTicket))
      {
         if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol) &&
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            PrintFormat("【防重复】存在未成交挂单 Ticket:%I64u", orderTicket);
            return true;
         }
      }
   }
   return false;
}

bool CheckHasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      if(PositionSelectByTicket(posTicket))
      {
         if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL), _Symbol) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            PrintFormat("【防重复】已存在持仓 Ticket:%I64u", posTicket);
            return true;
         }
      }
   }
   return false;
}

void SetTradeFillingMode()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & ORDER_FILLING_FOK) != 0)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & ORDER_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                        trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

void StopEAAndClean()
{
   PrintFormat("【回撤保护】回撤率已达到阈值 %.2f%%，终止EA并清理仓位！", MaxDrawdownPct);
   int closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0 && PositionSelectByTicket(posTicket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            if(trade.PositionClose(posTicket)) closedCount++;
            Sleep(200);
         }
      }
   }
   int deletedCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0 && OrderSelect(orderTicket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            if(trade.OrderDelete(orderTicket)) deletedCount++;
            Sleep(200);
         }
      }
   }
   PrintFormat("【回撤保护】已平仓 %d 个仓位，已撤销 %d 个委托。EA已停止运行。", closedCount, deletedCount);
}

void CalculateMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_BALANCE) + AccountInfoDouble(ACCOUNT_PROFIT);
   static double highestEquity = 0.0;
   if(g_max_drawdown == 0.0 && highestEquity == 0.0)
   {
      highestEquity = currentEquity;
      g_max_drawdown = 0.0;
      return;
   }
   double drawdownPct = 0.0;
   if(highestEquity > 0.0)
      drawdownPct = ((highestEquity - currentEquity) / highestEquity) * 100.0;
   g_max_drawdown = highestEquity - currentEquity;
   if(currentEquity > highestEquity)
      highestEquity = currentEquity;
   if(drawdownPct >= MaxDrawdownPct && !g_stop_on_drawdown)
   {
      PrintFormat("【回撤保护】检测到回撤率 %.2f%%，达到阈值 %.2f%%，立即停止EA并清仓！", drawdownPct, MaxDrawdownPct);
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
      Print("【目标净值达成】正在全面清仓与撤单...");
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
               trade.PositionClose(posTicket);
         }
      }
      Sleep(500);
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket > 0 && OrderSelect(orderTicket))
         {
            if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
               OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
               trade.OrderDelete(orderTicket);
         }
      }
      g_target_reached = true;
   }
}

void CancelAssociatedPendingOrder()
{
   if(g_reverse_order_ticket != INVALID_ORDER_TICKET)
   {
      if(OrderSelect(g_reverse_order_ticket))
      {
         long orderState = OrderGetInteger(ORDER_STATE);
         if(orderState == ORDER_STATE_PLACED)
         {
            if(trade.OrderDelete(g_reverse_order_ticket))
               PrintFormat("【撤单成功】成功撤销关联未成交翻仓单，Ticket：%I64u", g_reverse_order_ticket);
            else
               PrintFormat("【撤单失败】尝试撤销挂单失败，Ticket：%I64u，错误码：%d", g_reverse_order_ticket, trade.ResultRetcode());
         }
      }
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
   }
   int extraDeleted = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      if(OrderSelect(orderTicket))
      {
         if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol) &&
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
            OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED)
         {
            if(trade.OrderDelete(orderTicket))
            {
               extraDeleted++;
               PrintFormat("【安全撤单】额外清理残留挂单 Ticket:%I64u", orderTicket);
               Sleep(100);
            }
         }
      }
   }
   if(extraDeleted > 0)
      PrintFormat("【安全撤单】共额外清理 %d 个残留挂单", extraDeleted);
}

bool IsPositionClosedByTP(ulong position_id)
{
   if(position_id == INVALID_POSITION_ID) return false;
   double expectedTP = g_monitoring_reverse_position ? g_reverse_tp_price : g_virtual_tp_price;
   if(expectedTP <= 0.0) return false;
   
   for(int retry = 0; retry < 8; retry++)
   {
      if(!HistorySelectByPosition(position_id))
      {
         if(retry < 7) Sleep(100 + retry * 50);
         continue;
      }
      int total = HistoryDealsTotal();
      double closePrice = 0.0;
      double profit     = 0.0;
      long   reason     = -1;
      bool   foundOut   = false;
      for(int i = total - 1; i >= 0; i--)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
         foundOut   = true;
         closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         profit     = HistoryDealGetDouble(deal, DEAL_PROFIT);
         reason     = HistoryDealGetInteger(deal, DEAL_REASON);
         break;
      }
      if(foundOut)
      {
         double tolerance = MathMax(_Point * 30, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * 15);
         if(MathAbs(closePrice - expectedTP) <= tolerance) return true;
         if(reason == DEAL_REASON_TP) return true;
         if(reason == DEAL_REASON_SL) return false;
         
         double lot = 0.0;
         if(HistoryDealSelect(HistoryDealGetTicket(total - 1)))
            lot = HistoryDealGetDouble(HistoryDealGetTicket(total - 1), DEAL_VOLUME);
         if(lot <= 0.0) lot = LotLongReverse;
         double threshold = MathMax(3.0, (g_monitoring_reverse_position ? REV_TP_USD : TP_USD) * lot * 0.35);
         if(profit > threshold) return true;
         return false;
      }
      if(retry < 7) Sleep(120 + retry * 60);
   }
   return false;
}

void ExecuteReverseOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   g_be_activated = false;
   g_trail_activated = false;
   
   if(g_currentDirection == DIR_SHORT)
   {
      const double ask = tick.ask;
      if(trade.Buy(LotLongReverse, _Symbol, ask, 0, 0, "Reverse"))
      {
         ulong deal_ticket = trade.ResultDeal();
         g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                                 HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
         g_monitoring_reverse_position = true;
         g_last_close_was_tp = false;
         g_reverse_order_ticket = INVALID_ORDER_TICKET;
         
         double openPrice = 0.0;
         for(int i = PositionsTotal()-1; i>=0; i--)
         {
            ulong pt = PositionGetTicket(i);
            if(pt>0 && PositionSelectByTicket(pt) &&
               PositionGetInteger(POSITION_IDENTIFIER)==(long)g_monitor_position_id)
            {
               openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               break;
            }
         }
         if(openPrice <= 0.0) openPrice = ask;
         
         g_virtual_tp_price = NormalizeDouble(openPrice + REV_TP_USD, _Digits);
         g_virtual_sl_price = NormalizeDouble(openPrice - REV_SL_USD, _Digits);
         g_reverse_tp_price = g_virtual_tp_price;
         g_reverse_sl_price = g_virtual_sl_price;
         PrintFormat("【反向翻仓成功-多】持仓ID:%I64u 开仓价:%.5f 初始虚拟TP:%.5f SL:%.5f",
                     g_monitor_position_id, openPrice, g_virtual_tp_price, g_virtual_sl_price);
      }
   }
   else
   {
      const double bid = tick.bid;
      if(trade.Sell(LotShortReverse, _Symbol, bid, 0, 0, "Reverse"))
      {
         ulong deal_ticket = trade.ResultDeal();
         g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                                 HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
         g_monitoring_reverse_position = true;
         g_last_close_was_tp = false;
         g_reverse_order_ticket = INVALID_ORDER_TICKET;
         
         double openPrice = 0.0;
         for(int i = PositionsTotal()-1; i>=0; i--)
         {
            ulong pt = PositionGetTicket(i);
            if(pt>0 && PositionSelectByTicket(pt) &&
               PositionGetInteger(POSITION_IDENTIFIER)==(long)g_monitor_position_id)
            {
               openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               break;
            }
         }
         if(openPrice <= 0.0) openPrice = bid;
         
         g_virtual_tp_price = NormalizeDouble(openPrice - REV_TP_USD, _Digits);
         g_virtual_sl_price = NormalizeDouble(openPrice + REV_SL_USD, _Digits);
         g_reverse_tp_price = g_virtual_tp_price;
         g_reverse_sl_price = g_virtual_sl_price;
         PrintFormat("【反向翻仓成功-空】持仓ID:%I64u 开仓价:%.5f 初始虚拟TP:%.5f SL:%.5f",
                     g_monitor_position_id, openPrice, g_virtual_tp_price, g_virtual_sl_price);
      }
   }
}

void ExecuteShortOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   const double bid = tick.bid;
   const double virtual_sl = NormalizeDouble(bid + SL_USD, _Digits);
   const double virtual_tp = NormalizeDouble(bid - TP_USD, _Digits);
   g_be_activated = false;
   g_trail_activated = false;
   
   if(trade.Sell(LotShort, _Symbol, bid, 0, 0, ""))
   {
      ulong deal_ticket = trade.ResultDeal();
      g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                              HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
      g_virtual_sl_price = virtual_sl;
      g_virtual_tp_price = virtual_tp;
      g_monitoring_reverse_position = false;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      g_last_close_was_tp = false;
      PrintFormat("【初始做空成功】持仓ID: %I64u | 初始虚拟SL:%.5f TP:%.5f",
                  g_monitor_position_id, g_virtual_sl_price, g_virtual_tp_price);
   }
}

void ExecuteLongOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   const double ask = tick.ask;
   const double virtual_sl = NormalizeDouble(ask - SL_USD, _Digits);
   const double virtual_tp = NormalizeDouble(ask + TP_USD, _Digits);
   g_be_activated = false;
   g_trail_activated = false;
   
   if(trade.Buy(LotLong, _Symbol, ask, 0, 0, ""))
   {
      ulong deal_ticket = trade.ResultDeal();
      g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                              HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
      g_virtual_sl_price = virtual_sl;
      g_virtual_tp_price = virtual_tp;
      g_monitoring_reverse_position = false;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      g_last_close_was_tp = false;
      PrintFormat("【初始做多成功】持仓ID: %I64u | 初始虚拟SL:%.5f TP:%.5f",
                  g_monitor_position_id, g_virtual_sl_price, g_virtual_tp_price);
   }
}

//+------------------------------------------------------------------+
//| 核心检查函数（与v3.2.0相同，已包含保本+启动锁定+移动止盈）          |
//+------------------------------------------------------------------+
void CheckVirtualStopsAndClose()
{
   if(g_monitor_position_id != INVALID_POSITION_ID &&
      (g_virtual_sl_price > 0.0 || g_virtual_tp_price > 0.0))
   {
      bool found = false;
      ulong posTicket = 0;
      long  posType = -1;
      double currentPrice = 0.0;
      double openPrice = 0.0;
      
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong pt = PositionGetTicket(i);
         if(pt > 0 && PositionSelectByTicket(pt))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
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
      }
      
      if(found)
      {
         double trailDistance = g_monitoring_reverse_position ? REV_SL_USD : SL_USD;
         double trailStart    = g_monitoring_reverse_position ? Trail_Start_REV : Trail_Start_USD;
         
         double floatingProfit = (posType == POSITION_TYPE_BUY) ?
                                 (currentPrice - openPrice) : (openPrice - currentPrice);
         
         // 第一层：保本
         if(!g_be_activated && BE_Activate_USD > 0.0 && floatingProfit >= BE_Activate_USD)
         {
            if(posType == POSITION_TYPE_BUY)
               g_virtual_sl_price = NormalizeDouble(openPrice + BE_Lock_USD, _Digits);
            else
               g_virtual_sl_price = NormalizeDouble(openPrice - BE_Lock_USD, _Digits);
            g_be_activated = true;
            if(g_monitoring_reverse_position) g_reverse_sl_price = g_virtual_sl_price;
            PrintFormat("【保本启动】持仓ID:%I64u 浮盈:%.2f → 锁定止损到 %.5f",
                        g_monitor_position_id, floatingProfit, g_virtual_sl_price);
         }
         
         // 第二层：启动锁定 + 移动止盈
         if(!g_trail_activated && trailStart > 0.0 && floatingProfit >= trailStart)
         {
            if(posType == POSITION_TYPE_BUY)
               g_virtual_sl_price = NormalizeDouble(openPrice + trailStart, _Digits);
            else
               g_virtual_sl_price = NormalizeDouble(openPrice - trailStart, _Digits);
            g_trail_activated = true;
            if(g_monitoring_reverse_position) g_reverse_sl_price = g_virtual_sl_price;
            PrintFormat("【启动锁定+移动止盈】持仓ID:%I64u 浮盈:%.2f → 止损锁定到 %.5f",
                        g_monitor_position_id, floatingProfit, g_virtual_sl_price);
         }
         
         // 继续移动止损（模式A）
         if(posType == POSITION_TYPE_BUY)
         {
            double newSL = NormalizeDouble(currentPrice - trailDistance, _Digits);
            if(newSL > g_virtual_sl_price)
            {
               g_virtual_sl_price = newSL;
               if(g_monitoring_reverse_position) g_reverse_sl_price = newSL;
            }
         }
         else
         {
            double newSL = NormalizeDouble(currentPrice + trailDistance, _Digits);
            if(newSL < g_virtual_sl_price || g_virtual_sl_price <= 0.0)
            {
               g_virtual_sl_price = newSL;
               if(g_monitoring_reverse_position) g_reverse_sl_price = newSL;
            }
         }
         
         // 移动止盈 + 最大限制
         if(g_trail_activated)
         {
            double maxTPPrice = 0.0;
            if(posType == POSITION_TYPE_BUY)
            {
               double newTP = NormalizeDouble(currentPrice - Trail_TP_Dist, _Digits);
               maxTPPrice = NormalizeDouble(openPrice + Max_TP_USD, _Digits);
               if(newTP > g_virtual_tp_price)
                  g_virtual_tp_price = MathMin(newTP, maxTPPrice);
            }
            else
            {
               double newTP = NormalizeDouble(currentPrice + Trail_TP_Dist, _Digits);
               maxTPPrice = NormalizeDouble(openPrice - Max_TP_USD, _Digits);
               if(newTP < g_virtual_tp_price || g_virtual_tp_price <= 0.0)
                  g_virtual_tp_price = MathMax(newTP, maxTPPrice);
            }
            if(g_monitoring_reverse_position) g_reverse_tp_price = g_virtual_tp_price;
         }
         
         // 检查触发
         bool hitTP = false, hitSL = false;
         if(posType == POSITION_TYPE_BUY)
         {
            if(g_virtual_tp_price > 0.0 && currentPrice >= g_virtual_tp_price) hitTP = true;
            if(g_virtual_sl_price > 0.0 && currentPrice <= g_virtual_sl_price) hitSL = true;
         }
         else
         {
            if(g_virtual_tp_price > 0.0 && currentPrice <= g_virtual_tp_price) hitTP = true;
            if(g_virtual_sl_price > 0.0 && currentPrice >= g_virtual_sl_price) hitSL = true;
         }
         
         if(hitTP || hitSL)
         {
            string reason = hitTP ? "虚拟止盈" : "虚拟止损";
            PrintFormat("【虚拟平仓】触发%s | 持仓ID:%I64u | 当前价:%.5f | TP:%.5f | SL:%.5f",
                        reason, g_monitor_position_id, currentPrice, g_virtual_tp_price, g_virtual_sl_price);
            g_last_close_was_tp = hitTP;
            if(trade.PositionClose(posTicket))
            {
               if(hitSL && !g_monitoring_reverse_position)
               {
                  g_monitor_position_id = INVALID_POSITION_ID;
                  g_virtual_sl_price = 0.0;
                  g_virtual_tp_price = 0.0;
                  g_be_activated = false;
                  g_trail_activated = false;
                  ExecuteReverseOrder();
               }
               else
               {
                  g_monitor_position_id = INVALID_POSITION_ID;
                  g_virtual_sl_price = 0.0;
                  g_virtual_tp_price = 0.0;
                  g_be_activated = false;
                  g_trail_activated = false;
               }
            }
            return;
         }
      }
   }
   
   // 兜底扫描（简化版，保持原有逻辑）
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice  = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double priceMove = (posType == POSITION_TYPE_BUY) ? (curPrice - openPrice) : (openPrice - curPrice);
      double tpThreshold = g_monitoring_reverse_position ? REV_TP_USD : TP_USD;
      double slThreshold = g_monitoring_reverse_position ? REV_SL_USD : SL_USD;
      
      if(priceMove >= tpThreshold || priceMove <= -slThreshold)
      {
         g_last_close_was_tp = (priceMove >= tpThreshold);
         if(trade.PositionClose(pt))
         {
            g_monitor_position_id = INVALID_POSITION_ID;
            g_virtual_sl_price = 0.0;
            g_virtual_tp_price = 0.0;
            g_be_activated = false;
            g_trail_activated = false;
            if(priceMove <= -slThreshold && !g_monitoring_reverse_position)
               ExecuteReverseOrder();
         }
         return;
      }
   }
}

void MonitorPositionStatus()
{
   CheckVirtualStopsAndClose();
   
   if(g_pending_cancel_time > 0)
   {
      if(TimeTradeServer() >= g_pending_cancel_time)
      {
         CancelAssociatedPendingOrder();
         g_pending_cancel_time = 0;
      }
      return;
   }
   
   if(g_monitoring_reverse_position)
   {
      bool stillExists = false;
      if(g_monitor_position_id != INVALID_POSITION_ID)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong pt = PositionGetTicket(i);
            if(pt > 0 && PositionSelectByTicket(pt))
            {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
                  PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                  PositionGetInteger(POSITION_IDENTIFIER) == (long)g_monitor_position_id)
               {
                  stillExists = true;
                  break;
               }
            }
         }
      }
      if(stillExists) return;
      
      if(g_pending_reverse_check_time == 0)
      {
         g_pending_reverse_check_time = TimeTradeServer() + 2;
         return;
      }
      if(TimeTradeServer() < g_pending_reverse_check_time) return;
      
      bool closedByTP = g_last_close_was_tp || IsPositionClosedByTP(g_monitor_position_id);
      if(closedByTP && ReverseDirectionAfterSL)
      {
         g_currentDirection = (g_currentDirection == DIR_SHORT) ? DIR_LONG : DIR_SHORT;
         PrintFormat("【方向更新】已反转方向为: %s", (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
      }
      
      g_monitoring_reverse_position = false;
      g_monitor_position_id = INVALID_POSITION_ID;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      g_pending_reverse_check_time = 0;
      g_reverse_tp_price = 0.0;
      g_reverse_sl_price = 0.0;
      g_virtual_sl_price = 0.0;
      g_virtual_tp_price = 0.0;
      g_last_close_was_tp = false;
      g_be_activated = false;
      g_trail_activated = false;
      return;
   }
   
   if(g_monitor_position_id == INVALID_POSITION_ID) return;
   
   bool isStillOpen = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong pt = PositionGetTicket(i);
      if(pt > 0 && PositionSelectByTicket(pt))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_IDENTIFIER) == (long)g_monitor_position_id)
         {
            isStillOpen = true;
            break;
         }
      }
   }
   if(isStillOpen) return;
   
   g_monitor_position_id = INVALID_POSITION_ID;
   g_virtual_sl_price = 0.0;
   g_virtual_tp_price = 0.0;
   g_last_close_was_tp = false;
   g_be_activated = false;
   g_trail_activated = false;
}

bool IsInSwapAvoidWindow(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   if(AvoidSwapWednesdayOnly)
   {
      if(dt.day_of_week == 3 && dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      if(dt.day_of_week == 4 && dt.hour == 0 && dt.min < AvoidSwapAfterMin) return true;
      return false;
   }
   else
   {
      if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      if(dt.hour == 0  && dt.min < AvoidSwapAfterMin) return true;
      return false;
   }
}

bool IsInPreSwapWindow(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   if(AvoidSwapWednesdayOnly)
      return (dt.day_of_week == 3 && dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin));
   else
      return (dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin));
}

void ScanAndCloseProfitablePositions()
{
   bool hasProfitable = false;
   int closedCount = 0;
   ENUM_INIT_DIRECTION lastClosedDir = DIR_SHORT;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0 || !PositionSelectByTicket(posTicket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 8.0)
      {
         hasProfitable = true;
         long posType = PositionGetInteger(POSITION_TYPE);
         lastClosedDir = (posType == POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
         if(trade.PositionClose(posTicket))
         {
            closedCount++;
            Sleep(150);
         }
      }
   }
   
   if(hasProfitable)
   {
      g_need_reopen_after_swap = true;
      g_reopen_direction = lastClosedDir;
      
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket == 0 || !OrderSelect(orderTicket)) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
            trade.OrderDelete(orderTicket);
      }
      
      g_monitor_position_id = INVALID_POSITION_ID;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      g_pending_cancel_time = 0;
      g_monitoring_reverse_position = false;
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
      if(!IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      
      string comment = OrderGetString(ORDER_COMMENT);
      if(StringFind(comment, "SKIP") >= 0 || StringFind(comment, "暂停") >= 0)
      {
         trade.OrderDelete(ticket);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 定时器主逻辑（已加入均线过滤）                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();
   if(g_stop_on_drawdown || g_target_reached) return;
   
   CheckAndCloseAllPositions();
   if(g_target_reached) return;
   
   MonitorPositionStatus();
   
   if(IsInSwapAvoidWindow(serverNow))
   {
      if(IsInPreSwapWindow(serverNow))
         ScanAndCloseProfitablePositions();
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
   if(g_need_reopen_after_swap)
   {
      if(!CheckHasAnyPendingOrder() && !CheckHasAnyPosition() && !HasSkipOpenSignal())
      {
         ENUM_INIT_DIRECTION oldDir = g_currentDirection;
         g_currentDirection = g_reopen_direction;
         if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
         else ExecuteLongOrder();
         g_currentDirection = oldDir;
         g_lastTradeTime = serverNow;
         g_need_reopen_after_swap = false;
      }
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
   if(!EnableWeekendTrading)
   {
      MqlDateTime dt;
      TimeToStruct(serverNow, dt);
      if(dt.day_of_week == 0 || dt.day_of_week == 6)
      {
         g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
         return;
      }
   }
   
   if(serverNow < g_nextTriggerTime) return;
   if(serverNow - g_nextTriggerTime > 5)
   {
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
   datetime nextAfterThis = CalculateNextTriggerTime(serverNow);
   
   if(serverNow - g_lastTradeTime < RepeatGuardMin * 60)
   {
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   
   if(CheckHasAnyPendingOrder() || CheckHasAnyPosition())
   {
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   
   if(HasSkipOpenSignal())
   {
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   
   // ★★★ 均线方向过滤 ★★★
   if(!IsTrendAligned())
   {
      PrintFormat("【趋势过滤】时间:%s 方向与均线不符，跳过本次开仓。下次触发:%s",
                  TimeToString(serverNow, TIME_DATE|TIME_MINUTES),
                  TimeToString(nextAfterThis, TIME_DATE|TIME_MINUTES));
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   
   // 通过过滤，正常开仓
   if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
   else ExecuteLongOrder();
   
   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
}
//+------------------------------------------------------------------+