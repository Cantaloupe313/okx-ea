//+------------------------------------------------------------------+
//|                                                    移动止盈&止损策略.mq5 |
//|                                                             hery |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "3.1.0"
// 引入MQL5标准交易类库
#include <Trade\Trade.mqh> 
CTrade trade;
//===== 兼容常量定义 =====
#define INVALID_POSITION_ID 0
#define INVALID_ORDER_TICKET 0
//===== 初始方向枚举 =====
enum ENUM_INIT_DIRECTION
{
   DIR_SHORT = 0,  // 初始做空
   DIR_LONG  = 1   // 初始做多
};
//===== 外部参数 =====
input ulong   InpMagicNumber     = 888151;  // EA魔术码(用于区分订单)
input ENUM_INIT_DIRECTION InitialDirection = DIR_SHORT; // 初始方向
input double LotShort           = 0.01;     // 初始做空手数
input double LotLong            = 0.01;     // 初始做多手数
input double LotLongReverse     = 0.01;     // 做空止损反向多单手数
input double LotShortReverse    = 0.01;     // 做多止损反向空手数
input double TP_USD             = 23;       // 初始单移动止盈距离（逆势收紧）
input double SL_USD             = 18;       // 初始单移动止损距离
input double REV_SL_USD         = 18;       // 反向单移动止损距离
input double REV_TP_USD         = 23;       // 反向单移动止盈距离（逆势收紧）
input int    IntervalMinutes    = 15;        // 开仓间隔(分钟)
input int    RepeatGuardMin     = 2;        // 防重复间隔(分钟)
input int    CancelDelaySec     = 5;        // 延迟撤单秒数（已基本不用，保留兼容）
input double TargetNetProfit    = 500;  // 目标净值(达到后全部平仓并停止)
input double MaxDrawdownPct     = 50.0;     // 最大回撤率(%)，达到后终止EA并清仓
input bool   ReverseDirectionAfterSL = true; // 初始单止损 + 反向单止盈后，是否反转方向
//===== 隔夜库存费规避参数 =====
input bool   AvoidSwapWednesdayOnly = false; // 是否仅在周三深夜规避库存费
input int    AvoidSwapBeforeMin     = 10;    // 距离扣除库存费前多少分钟开始扫描
input int    AvoidSwapAfterMin      = 10;    // 扣除库存费后恢复时间(分钟)
input bool   EnableWeekendTrading   = false; // 是否开启周末定时开仓
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
//===== 虚拟止损/止盈（本地记录）=====
double   g_virtual_sl_price = 0.0;
double   g_virtual_tp_price = 0.0;
bool     g_last_close_was_tp = false;
// ★★★ 库存费前盈利平仓后，过了窗口按原方向重新开仓 ★★★
bool                 g_need_reopen_after_swap = false;
ENUM_INIT_DIRECTION  g_reopen_direction       = DIR_SHORT;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   if(!EventSetTimer(1))
   {
      Print("定时器创建失败！错误码：", GetLastError());
      return INIT_PARAMETERS_INCORRECT;
   }
   g_nextTriggerTime = CalculateNextTriggerTime(TimeTradeServer());
   g_currentDirection = InitialDirection;
   if(g_currentDirection == DIR_SHORT)
      PrintFormat("EA启动 v3.3.0【移动止损 + 逆势收紧移动止盈(带±5保护) + 止损后立即翻仓】规则：定时自动做空 | 间隔:%d分钟 | 目标净值:%.2f", IntervalMinutes, TargetNetProfit);
   else
      PrintFormat("EA启动 v3.3.0【移动止损 + 逆势收紧移动止盈(带±5保护) + 止损后立即翻仓】规则：定时自动做多 | 间隔:%d分钟 | 目标净值:%.2f", IntervalMinutes, TargetNetProfit);
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}
//+------------------------------------------------------------------+
//| 辅助函数：提取商品的基础名称                                       |
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
//+------------------------------------------------------------------+
//| 获取当前魔术码最新的持仓 ID                                        |
//+------------------------------------------------------------------+
ulong GetLatestPositionID()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0 && PositionSelectByTicket(posTicket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            return PositionGetInteger(POSITION_IDENTIFIER);
         }
      }
   }
   return INVALID_POSITION_ID;
}
//+------------------------------------------------------------------+
//| 计算下一个触发点                                                   |
//+------------------------------------------------------------------+
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
//===== 防重复校验 =====
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
//+------------------------------------------------------------------+
//| 回撤止损：停止EA并清仓                                             |
//+------------------------------------------------------------------+
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
            if(trade.PositionClose(posTicket))
               closedCount++;
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
            if(trade.OrderDelete(orderTicket))
               deletedCount++;
            Sleep(200);
         }
      }
   }
   PrintFormat("【回撤保护】已平仓 %d 个仓位，已撤销 %d 个委托。EA已停止运行。", closedCount, deletedCount);
}
//+------------------------------------------------------------------+
//| 计算并检查最大回撤                                                 |
//+------------------------------------------------------------------+
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
//+------------------------------------------------------------------+
//| 检查目标净值                                                       |
//+------------------------------------------------------------------+
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
//+------------------------------------------------------------------+
//| 安全撤销关联的反向挂单（保留兼容）                                 |
//+------------------------------------------------------------------+
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
//+------------------------------------------------------------------+
//| 判断指定持仓是否以止盈方式平仓                                     |
//+------------------------------------------------------------------+
bool IsPositionClosedByTP(ulong position_id)
{
   if(position_id == INVALID_POSITION_ID) return false;
   double expectedTP = g_monitoring_reverse_position ? g_reverse_tp_price : g_virtual_tp_price;
   if(expectedTP <= 0.0)
   {
      PrintFormat("【平仓判定】PositionID:%I64u 虚拟止盈价无效，无法判断", position_id);
      return false;
   }
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
         if(MathAbs(closePrice - expectedTP) <= tolerance)
         {
            PrintFormat("【平仓判定】PositionID:%I64u 平仓价:%.5f 接近虚拟TP:%.5f → 判定为止盈",
                        position_id, closePrice, expectedTP);
            return true;
         }
         if(reason == DEAL_REASON_TP)
         {
            PrintFormat("【平仓判定】PositionID:%I64u DEAL_REASON_TP → 止盈", position_id);
            return true;
         }
         if(reason == DEAL_REASON_SL)
         {
            PrintFormat("【平仓判定】PositionID:%I64u DEAL_REASON_SL → 止损", position_id);
            return false;
         }
         double lot = 0.0;
         if(HistoryDealSelect(HistoryDealGetTicket(total - 1)))
            lot = HistoryDealGetDouble(HistoryDealGetTicket(total - 1), DEAL_VOLUME);
         if(lot <= 0.0) lot = LotLongReverse;
         double threshold = MathMax(3.0, (g_monitoring_reverse_position ? REV_TP_USD : TP_USD) * lot * 0.35);
         if(profit > threshold)
         {
            PrintFormat("【平仓判定】PositionID:%I64u 利润:%.2f > 阈值%.2f → 按止盈处理", position_id, profit, threshold);
            return true;
         }
         PrintFormat("【平仓判定】PositionID:%I64u 平仓价:%.5f 利润:%.2f Reason:%d → 非止盈",
                     position_id, closePrice, profit, reason);
         return false;
      }
      if(retry < 7) Sleep(120 + retry * 60);
   }
   PrintFormat("【平仓判定】PositionID:%I64u 多次重试仍未找到OUT成交 → 按非止盈处理", position_id);
   return false;
}
//+------------------------------------------------------------------+
//| 开反向翻仓单（初始单止损后立即调用）                               |
//+------------------------------------------------------------------+
void ExecuteReverseOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【错误】获取Tick失败，错误码: ", GetLastError());
      return;
   }
   if(g_currentDirection == DIR_SHORT)
   {
      // 初始做空 → 反向做多
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
         // 初始虚拟止盈 + 虚拟止损（后续按规则移动）
         g_virtual_tp_price = NormalizeDouble(openPrice + REV_TP_USD, _Digits);
         g_virtual_sl_price = NormalizeDouble(openPrice - REV_SL_USD, _Digits);
         g_reverse_tp_price = g_virtual_tp_price;
         g_reverse_sl_price = g_virtual_sl_price;
         PrintFormat("【反向翻仓成功-多】持仓ID:%I64u 开仓价:%.5f 初始虚拟TP:%.5f SL:%.5f（止盈逆势收紧+保护）",
                     g_monitor_position_id, openPrice, g_virtual_tp_price, g_virtual_sl_price);
      }
      else
      {
         PrintFormat("【反向翻仓失败-多】错误码: %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
   else
   {
      // 初始做多 → 反向做空
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
         PrintFormat("【反向翻仓成功-空】持仓ID:%I64u 开仓价:%.5f 初始虚拟TP:%.5f SL:%.5f（止盈逆势收紧+保护）",
                     g_monitor_position_id, openPrice, g_virtual_tp_price, g_virtual_sl_price);
      }
      else
      {
         PrintFormat("【反向翻仓失败-空】错误码: %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
}
//+------------------------------------------------------------------+
//| 下单逻辑（初始单）——不再挂反向单                                   |
//+------------------------------------------------------------------+
void ExecuteShortOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【错误】获取Tick失败，错误码: ", GetLastError());
      return;
   }
   const double bid = tick.bid;
   const double virtual_sl = NormalizeDouble(bid + SL_USD, _Digits);
   const double virtual_tp = NormalizeDouble(bid - TP_USD, _Digits);
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
      PrintFormat("【初始做空成功】持仓ID: %I64u | 初始虚拟SL:%.5f TP:%.5f（止盈逆势收紧+保护）",
                  g_monitor_position_id, g_virtual_sl_price, g_virtual_tp_price);
   }
   else
   {
      PrintFormat("【初始做空失败】价格: %.5f  错误码: %d (%s)",
                  bid, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
void ExecuteLongOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【错误】获取Tick失败，错误码: ", GetLastError());
      return;
   }
   const double ask = tick.ask;
   const double virtual_sl = NormalizeDouble(ask - SL_USD, _Digits);
   const double virtual_tp = NormalizeDouble(ask + TP_USD, _Digits);
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
      PrintFormat("【初始做多成功】持仓ID: %I64u | 初始虚拟SL:%.5f TP:%.5f（止盈逆势收紧+保护）",
                  g_monitor_position_id, g_virtual_sl_price, g_virtual_tp_price);
   }
   else
   {
      PrintFormat("【初始做多失败】价格: %.5f  错误码: %d (%s)",
                  ask, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
//| 【核心】虚拟移动止损 + 逆势收紧移动止盈（带±5保护） + 兜底全扫描   |
//+------------------------------------------------------------------+
void CheckVirtualStopsAndClose()
{
   // ===== 1. 优先检查当前监控持仓 =====
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
         double trailSL = g_monitoring_reverse_position ? REV_SL_USD : SL_USD;
         double trailTP = g_monitoring_reverse_position ? REV_TP_USD : TP_USD;

         if(posType == POSITION_TYPE_BUY)
         {
            // ===== 多单 =====
            // 止损：只能上移
            double newSL = NormalizeDouble(currentPrice - trailSL, _Digits);
            if(newSL > g_virtual_sl_price)
            {
               g_virtual_sl_price = newSL;
               if(g_monitoring_reverse_position)
                  g_reverse_sl_price = newSL;
            }

            // 止盈：只能下移，且不能低于 开仓价 + 5
            double candidateTP = NormalizeDouble(currentPrice + trailTP, _Digits);
            double minAllowedTP = NormalizeDouble(openPrice + 5.0, _Digits);

            if(candidateTP < g_virtual_tp_price)
            {
               double limitedTP = MathMax(candidateTP, minAllowedTP);
               if(limitedTP < g_virtual_tp_price)
               {
                  g_virtual_tp_price = limitedTP;
                  if(g_monitoring_reverse_position)
                     g_reverse_tp_price = limitedTP;
               }
            }
         }
         else // SELL
         {
            // ===== 空单 =====
            // 止损：只能下移
            double newSL = NormalizeDouble(currentPrice + trailSL, _Digits);
            if(newSL < g_virtual_sl_price || g_virtual_sl_price <= 0.0)
            {
               g_virtual_sl_price = newSL;
               if(g_monitoring_reverse_position)
                  g_reverse_sl_price = newSL;
            }

            // 止盈：只能上移，且不能高于 开仓价 - 5
            double candidateTP = NormalizeDouble(currentPrice - trailTP, _Digits);
            double maxAllowedTP = NormalizeDouble(openPrice - 5.0, _Digits);

            if(candidateTP > g_virtual_tp_price)
            {
               double limitedTP = MathMin(candidateTP, maxAllowedTP);
               if(limitedTP > g_virtual_tp_price)
               {
                  g_virtual_tp_price = limitedTP;
                  if(g_monitoring_reverse_position)
                     g_reverse_tp_price = limitedTP;
               }
            }
         }

         // 检查是否触发止盈或止损
         bool hitTP = false;
         bool hitSL = false;
         if(posType == POSITION_TYPE_BUY)
         {
            if(g_virtual_tp_price > 0.0 && currentPrice >= g_virtual_tp_price) hitTP = true;
            if(g_virtual_sl_price > 0.0 && currentPrice <= g_virtual_sl_price) hitSL = true;
         }
         else // SELL
         {
            if(g_virtual_tp_price > 0.0 && currentPrice <= g_virtual_tp_price) hitTP = true;
            if(g_virtual_sl_price > 0.0 && currentPrice >= g_virtual_sl_price) hitSL = true;
         }
         if(hitTP || hitSL)
         {
            string reason = hitTP ? "虚拟移动止盈(逆势收紧+保护)" : "虚拟移动止损";
            PrintFormat("【虚拟平仓】触发%s | 持仓ID:%I64u | 当前价:%.5f | 虚拟TP:%.5f | 虚拟SL:%.5f",
                        reason, g_monitor_position_id, currentPrice, g_virtual_tp_price, g_virtual_sl_price);
            g_last_close_was_tp = hitTP;
            if(trade.PositionClose(posTicket))
            {
               PrintFormat("【虚拟平仓成功】%s 已执行", reason);
               // 初始单止损后，立即开反向翻仓单
               if(hitSL && !g_monitoring_reverse_position)
               {
                  Print("【初始单止损】立即执行反向翻仓...");
                  g_monitor_position_id = INVALID_POSITION_ID;
                  g_virtual_sl_price = 0.0;
                  g_virtual_tp_price = 0.0;
                  ExecuteReverseOrder();
               }
               else if(hitTP && !g_monitoring_reverse_position)
               {
                  // 初始单止盈：仅清理
                  g_monitor_position_id = INVALID_POSITION_ID;
                  g_virtual_sl_price = 0.0;
                  g_virtual_tp_price = 0.0;
                  Print("【初始单移动止盈】已平仓，不进行翻仓");
               }
            }
            else
               PrintFormat("【虚拟平仓失败】错误码: %d", trade.ResultRetcode());
            return;
         }
      }
   }
   // ===== 2. 兜底全扫描 =====
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
      if(g_monitor_position_id == INVALID_POSITION_ID ||
         PositionGetInteger(POSITION_IDENTIFIER) != (long)g_monitor_position_id)
      {
         tpThreshold = REV_TP_USD;
         slThreshold = REV_SL_USD;
      }
      if(priceMove >= tpThreshold)
      {
         PrintFormat("【兜底虚拟止盈】强制平仓！Ticket:%I64u 移动:%.2f >= %.2f", pt, priceMove, tpThreshold);
         g_last_close_was_tp = true;
         if(trade.PositionClose(pt))
         {
            g_monitor_position_id = INVALID_POSITION_ID;
            g_virtual_sl_price = 0.0;
            g_virtual_tp_price = 0.0;
         }
         return;
      }
      if(priceMove <= -slThreshold)
      {
         PrintFormat("【兜底虚拟止损】强制平仓！Ticket:%I64u 移动:%.2f <= -%.2f", pt, priceMove, slThreshold);
         g_last_close_was_tp = false;
         if(trade.PositionClose(pt))
         {
            if(!g_monitoring_reverse_position)
            {
               g_monitor_position_id = INVALID_POSITION_ID;
               g_virtual_sl_price = 0.0;
               g_virtual_tp_price = 0.0;
               Print("【兜底初始单止损】尝试立即反向翻仓...");
               ExecuteReverseOrder();
            }
            else
            {
               g_monitor_position_id = INVALID_POSITION_ID;
               g_virtual_sl_price = 0.0;
               g_virtual_tp_price = 0.0;
            }
         }
         return;
      }
   }
}
//+------------------------------------------------------------------+
//| 监控持仓状态                                                       |
//+------------------------------------------------------------------+
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
         PrintFormat("【监控通知】反向翻仓持仓(ID:%I64u)已离场，进入 2 秒延迟确认期...", g_monitor_position_id);
         return;
      }
      if(TimeTradeServer() < g_pending_reverse_check_time) return;
      PrintFormat("【延迟确认】开始最终判断反向持仓(ID:%I64u)是否止盈...", g_monitor_position_id);
      bool closedByTP = g_last_close_was_tp || IsPositionClosedByTP(g_monitor_position_id);
      if(closedByTP && ReverseDirectionAfterSL)
      {
         g_currentDirection = (g_currentDirection == DIR_SHORT) ? DIR_LONG : DIR_SHORT;
         PrintFormat("【方向更新】初始单止损 + 反向单止盈 → 已反转方向为: %s",
                     (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
      }
      else
      {
         PrintFormat("【方向保持】反向单非止盈离场，方向不反转，当前仍为: %s",
                     (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
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
   PrintFormat("【监控通知】初始持仓(ID:%I64u)已离场（可能被外部平仓）", g_monitor_position_id);
   g_monitor_position_id = INVALID_POSITION_ID;
   g_virtual_sl_price = 0.0;
   g_virtual_tp_price = 0.0;
   g_last_close_was_tp = false;
}
//+------------------------------------------------------------------+
//| 库存费避让相关函数                                                 |
//+------------------------------------------------------------------+
bool IsInSwapAvoidWindow(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   if(AvoidSwapWednesdayOnly)
   {
      if(dt.day_of_week == 3)
      {
         if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      }
      else if(dt.day_of_week == 4)
      {
         if(dt.hour == 0 && dt.min < AvoidSwapAfterMin) return true;
      }
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
   {
      if(dt.day_of_week == 3 && dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin))
         return true;
      return false;
   }
   else
   {
      if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin))
         return true;
      return false;
   }
}
void ScanAndCloseProfitablePositions()
{
   bool hasProfitable = false;
   int closedCount = 0;
   ENUM_INIT_DIRECTION lastClosedDir = DIR_SHORT;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      if(!PositionSelectByTicket(posTicket)) continue;
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
            PrintFormat("【库存费避让】盈利仓位已平仓 Ticket:%I64u  浮动盈亏: %.2f  方向:%s",
                        posTicket, profit, (lastClosedDir == DIR_LONG ? "多" : "空"));
            Sleep(150);
         }
      }
   }
   if(hasProfitable)
   {
      g_need_reopen_after_swap = true;
      g_reopen_direction       = lastClosedDir;
      PrintFormat("【库存费避让】已记录盈利平仓方向 = %s，过窗口后将按此方向重新开仓",
                  (g_reopen_direction == DIR_LONG ? "做多" : "做空"));
      int deletedCount = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket == 0) continue;
         if(!OrderSelect(orderTicket)) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            if(trade.OrderDelete(orderTicket))
            {
               deletedCount++;
               PrintFormat("【库存费避让】已撤销挂单 Ticket:%I64u", orderTicket);
               Sleep(100);
            }
         }
      }
      g_monitor_position_id = INVALID_POSITION_ID;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      g_pending_cancel_time = 0;
      g_monitoring_reverse_position = false;
      g_virtual_sl_price = 0.0;
      g_virtual_tp_price = 0.0;
      g_reverse_sl_price = 0.0;
      g_reverse_tp_price = 0.0;
      PrintFormat("【库存费避让】扫描完成：平仓 %d 个盈利仓位，撤销 %d 个挂单。亏损仓位已保留。",
                  closedCount, deletedCount);
   }
}
bool HasSkipOpenSignal()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(!IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      string comment = OrderGetString(ORDER_COMMENT);
      if(StringFind(comment, "SKIP") >= 0 || StringFind(comment, "暂停") >= 0)
      {
         trade.OrderDelete(ticket);
         PrintFormat("【手机控制】已删除跳过信号挂单 Ticket:%I64u Comment:%s", ticket, comment);
         return true;
      }
   }
   return false;
}
//+------------------------------------------------------------------+
//| 定时器主逻辑                                                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();
   if(g_stop_on_drawdown) return;
   if(g_target_reached) return;
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
         PrintFormat("【库存费后重开】按之前盈利方向重新开仓 → %s",
                     (g_reopen_direction == DIR_LONG ? "做多" : "做空"));
         ENUM_INIT_DIRECTION oldDir = g_currentDirection;
         g_currentDirection = g_reopen_direction;
         if(g_currentDirection == DIR_SHORT)
            ExecuteShortOrder();
         else
            ExecuteLongOrder();
         g_currentDirection = oldDir;
         g_lastTradeTime = serverNow;
         g_need_reopen_after_swap = false;
      }
      else
      {
         Print("【库存费后重开】存在持仓/挂单或跳过信号，本次跳过，标志保持，等待下次机会");
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
      PrintFormat("【定时任务】时间: %s，存在未成交委托或已成交仓位，跳过本次执行。下次触发: %s",
                  TimeToString(serverNow, TIME_DATE|TIME_MINUTES),
                  TimeToString(nextAfterThis, TIME_DATE|TIME_MINUTES));
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   if(HasSkipOpenSignal())
   {
      PrintFormat("【手机控制】检测到跳过开仓信号，本次不执行开仓。时间: %s",
                  TimeToString(serverNow, TIME_DATE|TIME_MINUTES));
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
   else                                 ExecuteLongOrder();
   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
}
//+------------------------------------------------------------------+