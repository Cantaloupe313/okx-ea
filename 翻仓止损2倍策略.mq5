//+------------------------------------------------------------------+
//|                                                    翻仓止损两倍策略.mq5 |
//|                                                             hery |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "2.1.3"
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
input double LotLongReverse     = 0.02;     // 做空止损反向多单手数
input double LotShortReverse    = 0.02;     // 做多止损反向空手数
input double TP_USD             = 18;       // 止盈(美元，XAUUSD价格差)
input double SL_USD             = 18;       // 止损(美元，XAUUSD价格差)
input double REV_SL_USD         = 36;       // 翻仓单止损价差，默认36
input double REV_TP_USD         = 18;       // 翻仓单止盈价差，默认18
input int    IntervalMinutes    = 5;        // 开仓间隔(分钟)
input int    RepeatGuardMin     = 2;        // 防重复间隔(分钟)
input int    CancelDelaySec     = 5;        // 延迟撤单秒数
input double TargetNetProfit    = 10050.0;  // 目标净值(达到后全部平仓并停止)
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
bool     g_last_close_was_tp = false;   // 新增：最近一次平仓是否为止盈（虚拟平仓专用）
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
      PrintFormat("EA启动 v2.1.5【止盈后延迟撤单加固版】规则：定时自动做空 + 立即挂反向多单 | 间隔:%d分钟 | 目标净值:%.2f", IntervalMinutes, TargetNetProfit);
   else
      PrintFormat("EA启动 v2.1.5【止盈后延迟撤单加固版】规则：定时自动做多 + 立即挂反向空单 | 间隔:%d分钟 | 目标净值:%.2f", IntervalMinutes, TargetNetProfit);
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
//| 安全撤销关联的反向挂单（增强版：支持ticket丢失时全量扫描清理）      |
//+------------------------------------------------------------------+
void CancelAssociatedPendingOrder()
{
   // 1. 优先按记录的ticket撤销
   if(g_reverse_order_ticket != INVALID_ORDER_TICKET)
   {
      if(OrderSelect(g_reverse_order_ticket))
      {
         long orderState = OrderGetInteger(ORDER_STATE);
         if(orderState == ORDER_STATE_PLACED)
         {
            if(trade.OrderDelete(g_reverse_order_ticket))
               PrintFormat("【撤单成功】初始单已平仓(止盈)，成功撤销关联未成交翻仓单，Ticket：%I64u", g_reverse_order_ticket);
            else
               PrintFormat("【撤单失败】尝试撤销挂单失败，Ticket：%I64u，错误码：%d", g_reverse_order_ticket, trade.ResultRetcode());
         }
         else
            PrintFormat("【撤单跳过】反向挂单 Ticket:%I64u 状态已改变(%d)，极可能已被触发。", g_reverse_order_ticket, orderState);
      }
      else
      {
         PrintFormat("【撤单通知】未找到挂单Ticket：%I64u，可能已被激活或手动删除。", g_reverse_order_ticket);
      }
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
   }
   // 2. 安全网：无论ticket是否有效，扫描并强制清理本EA所有残留挂单（防止变量丢失导致挂单残留）
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
            else
            {
               PrintFormat("【安全撤单失败】Ticket:%I64u 错误码:%d", orderTicket, trade.ResultRetcode());
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
//| 下单逻辑                                                           |
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
      double rev_tp = NormalizeDouble(virtual_sl + REV_TP_USD, _Digits);
      double rev_sl = NormalizeDouble(virtual_sl - REV_SL_USD, _Digits);
      if(trade.BuyStop(LotLongReverse, virtual_sl, _Symbol, 0, 0, ORDER_TIME_GTC, 0, ""))
         g_reverse_order_ticket = trade.ResultOrder();
      g_monitoring_reverse_position = false;
      g_reverse_tp_price = rev_tp;
      g_reverse_sl_price = rev_sl;
      PrintFormat("【初始做空成功-虚拟】持仓ID: %I64u, 反向挂单Ticket: %I64u | 虚拟SL:%.5f TP:%.5f | 反向虚拟SL:%.5f TP:%.5f",
                  g_monitor_position_id, g_reverse_order_ticket,
                  g_virtual_sl_price, g_virtual_tp_price, rev_sl, rev_tp);
   }
   else
   {
      PrintFormat("【初始做空失败】价格: %.5f  虚拟SL: %.5f  虚拟TP: %.5f  错误码: %d (%s)",
                  bid, virtual_sl, virtual_tp,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
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
      double rev_tp = NormalizeDouble(virtual_sl - REV_TP_USD, _Digits);
      double rev_sl = NormalizeDouble(virtual_sl + REV_SL_USD, _Digits);
      if(trade.SellStop(LotShortReverse, virtual_sl, _Symbol, 0, 0, ORDER_TIME_GTC, 0, ""))
         g_reverse_order_ticket = trade.ResultOrder();
      g_monitoring_reverse_position = false;
      g_reverse_tp_price = rev_tp;
      g_reverse_sl_price = rev_sl;
      PrintFormat("【初始做多成功-虚拟】持仓ID: %I64u, 反向挂单Ticket: %I64u | 虚拟SL:%.5f TP:%.5f | 反向虚拟SL:%.5f TP:%.5f",
                  g_monitor_position_id, g_reverse_order_ticket,
                  g_virtual_sl_price, g_virtual_tp_price, rev_sl, rev_tp);
   }
   else
   {
      PrintFormat("【初始做多失败】价格: %.5f  虚拟SL: %.5f  虚拟TP: %.5f  错误码: %d (%s)",
                  ask, virtual_sl, virtual_tp,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
//| 【核心加固】虚拟止损/止盈检查 + 兜底全扫描                         |
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
         // 如果是反向单，定期用真实开仓价重新校准虚拟价位（防止之前设置错误）
         if(g_monitoring_reverse_position && openPrice > 0.0)
         {
            double expected_tp = 0.0, expected_sl = 0.0;
            if(posType == POSITION_TYPE_BUY)
            {
               expected_tp = NormalizeDouble(openPrice + REV_TP_USD, _Digits);
               expected_sl = NormalizeDouble(openPrice - REV_SL_USD, _Digits);
            }
            else
            {
               expected_tp = NormalizeDouble(openPrice - REV_TP_USD, _Digits);
               expected_sl = NormalizeDouble(openPrice + REV_SL_USD, _Digits);
            }
            // 如果偏差超过 1 点，强制更新
            if(MathAbs(g_virtual_tp_price - expected_tp) > 1.0 ||
               MathAbs(g_virtual_sl_price - expected_sl) > 1.0)
            {
               g_virtual_tp_price = expected_tp;
               g_virtual_sl_price = expected_sl;
               g_reverse_tp_price = expected_tp;
               g_reverse_sl_price = expected_sl;
               PrintFormat("【虚拟价位校准】反向单ID:%I64u 开仓价:%.5f → 重新设定 虚拟TP:%.5f SL:%.5f",
                           g_monitor_position_id, openPrice, g_virtual_tp_price, g_virtual_sl_price);
            }
         }
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
            string reason = hitTP ? "虚拟止盈" : "虚拟止损";
            PrintFormat("【虚拟平仓】触发%s | 持仓ID:%I64u | 当前价:%.5f | 虚拟TP:%.5f | 虚拟SL:%.5f",
                        reason, g_monitor_position_id, currentPrice, g_virtual_tp_price, g_virtual_sl_price);
            // ★ 关键：明确记录本次平仓原因
            g_last_close_was_tp = hitTP;
            if(trade.PositionClose(posTicket))
            {
               PrintFormat("【虚拟平仓成功】%s 已执行", reason);
               // ★ v2.1.5：初始单止盈后设置延迟撤单（默认5秒，保留并发保护）
               if(hitTP && !g_monitoring_reverse_position)
               {
                  g_pending_cancel_time = TimeTradeServer() + CancelDelaySec;
                  g_monitor_position_id = INVALID_POSITION_ID;
                  g_virtual_sl_price = 0.0;
                  g_virtual_tp_price = 0.0;
                  PrintFormat("【虚拟止盈】已进入 %d 秒延迟撤单期，将撤销未成交反向挂单", CancelDelaySec);
               }
            }
            else
               PrintFormat("【虚拟平仓失败】错误码: %d", trade.ResultRetcode());
            return; // 已处理，本轮结束
         }
      }
   }
   // ===== 2. 兜底全扫描：防止监控变量丢失导致单子跑飞 =====
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
      // 判断是用初始阈值还是反向阈值
      double tpThreshold = g_monitoring_reverse_position ? REV_TP_USD : TP_USD;
      double slThreshold = g_monitoring_reverse_position ? REV_SL_USD : SL_USD;
      // 如果当前没有监控任何单，或者ID对不上，用反向阈值作为更安全的兜底
      if(g_monitor_position_id == INVALID_POSITION_ID ||
         PositionGetInteger(POSITION_IDENTIFIER) != (long)g_monitor_position_id)
      {
         tpThreshold = REV_TP_USD;
         slThreshold = REV_SL_USD;
      }
      if(priceMove >= tpThreshold)
      {
         PrintFormat("【兜底虚拟止盈】强制平仓！Ticket:%I64u 开仓价:%.5f 当前价:%.5f 移动:%.2f >= 阈值:%.2f",
                     pt, openPrice, curPrice, priceMove, tpThreshold);
         // ★ 重要：记录为止盈
         g_last_close_was_tp = true;
         if(trade.PositionClose(pt))
         {
            // ★ v2.1.5：兜底止盈后设置延迟撤单（保留并发保护）
            if(!g_monitoring_reverse_position)
            {
               g_pending_cancel_time = TimeTradeServer() + CancelDelaySec;
               PrintFormat("【兜底虚拟止盈】已进入 %d 秒延迟撤单期，将撤销未成交反向挂单", CancelDelaySec);
            }
         }
         // 注意：这里不再强制清 g_monitoring_reverse_position，
         // 让后面的 MonitorPositionStatus 正式逻辑去处理方向翻转
         g_monitor_position_id = INVALID_POSITION_ID;
         g_virtual_sl_price = 0.0;
         g_virtual_tp_price = 0.0;
         // g_monitoring_reverse_position 保持原值，由正式逻辑清理
         return;
      }
      if(priceMove <= -slThreshold)
      {
         PrintFormat("【兜底虚拟止损】强制平仓！Ticket:%I64u 开仓价:%.5f 当前价:%.5f 移动:%.2f <= -阈值:%.2f",
                     pt, openPrice, curPrice, priceMove, slThreshold);
         // ★ 重要：记录为止损
         g_last_close_was_tp = false;
         trade.PositionClose(pt);
         g_monitor_position_id = INVALID_POSITION_ID;
         g_virtual_sl_price = 0.0;
         g_virtual_tp_price = 0.0;
         // 同上，不强制清 g_monitoring_reverse_position
         return;
      }
   }
}
//+------------------------------------------------------------------+
//| 【强化竞态修复】反向挂单成交瞬间立刻平掉初始单 + 对锁安全网       |
//+------------------------------------------------------------------+
void ForceCloseInitialIfReverseTriggered()
{
   // ========== 安全网：只要出现多空对锁，立刻处理 ==========
   int buyCount = 0, sellCount = 0;
   ulong buyTicket = 0, sellTicket = 0;
   ulong buyID = 0, sellID = 0;
   double buyOpen = 0.0, sellOpen = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyTicket = pt;
         buyID     = PositionGetInteger(POSITION_IDENTIFIER);
         buyOpen   = PositionGetDouble(POSITION_PRICE_OPEN);
      }
      else
      {
         sellCount++;
         sellTicket = pt;
         sellID     = PositionGetInteger(POSITION_IDENTIFIER);
         sellOpen   = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   // 出现多空对锁 → 强制平初始方向的单
   if(buyCount > 0 && sellCount > 0)
   {
      ulong closeTicket = 0;
      ulong keepID      = 0;
      double keepOpen   = 0.0;
      long   keepType   = -1;
      if(g_currentDirection == DIR_SHORT)
      {
         closeTicket = sellTicket;   // 平初始空单
         keepID      = buyID;
         keepOpen    = buyOpen;
         keepType    = POSITION_TYPE_BUY;
      }
      else
      {
         closeTicket = buyTicket;    // 平初始多单
         keepID      = sellID;
         keepOpen    = sellOpen;
         keepType    = POSITION_TYPE_SELL;
      }
      if(closeTicket > 0)
      {
         PrintFormat("【竞态安全网】检测到多空对锁，强制平初始单 Ticket:%I64u", closeTicket);
         if(trade.PositionClose(closeTicket))
         {
            g_monitor_position_id        = keepID;
            g_monitoring_reverse_position = true;
            g_reverse_order_ticket       = INVALID_ORDER_TICKET;
            g_last_close_was_tp          = false;
            g_pending_reverse_check_time = 0;
            if(keepOpen > 0.0)
            {
               if(keepType == POSITION_TYPE_BUY)
               {
                  g_virtual_tp_price = NormalizeDouble(keepOpen + REV_TP_USD, _Digits);
                  g_virtual_sl_price = NormalizeDouble(keepOpen - REV_SL_USD, _Digits);
               }
               else
               {
                  g_virtual_tp_price = NormalizeDouble(keepOpen - REV_TP_USD, _Digits);
                  g_virtual_sl_price = NormalizeDouble(keepOpen + REV_SL_USD, _Digits);
               }
               g_reverse_tp_price = g_virtual_tp_price;
               g_reverse_sl_price = g_virtual_sl_price;
               PrintFormat("【竞态安全网】已接管反向单 ID:%I64u  TP:%.5f  SL:%.5f", keepID, g_virtual_tp_price, g_virtual_sl_price);
            }
            return;   // 已处理，直接返回
         }
      }
   }
   // ========== 正常逻辑：检测反向挂单是否刚成交 ==========
   if(g_reverse_order_ticket == INVALID_ORDER_TICKET || g_monitoring_reverse_position)
      return;
   bool reverseStillPending = false;
   if(OrderSelect(g_reverse_order_ticket))
   {
      if(OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED)
         reverseStillPending = true;
   }
   if(reverseStillPending) return;   // 挂单还在，不用处理
   // 反向挂单已消失，检查初始单是否还在
   ulong initialTicket = 0;
   ulong initialID     = g_monitor_position_id;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetInteger(POSITION_IDENTIFIER) == (long)initialID)
      {
         initialTicket = pt;
         break;
      }
   }
   if(initialTicket > 0)
   {
      PrintFormat("【竞态瞬间修复】反向挂单已成交，初始单(ID:%I64u)仍存在，立即强制平仓！", initialID);
      if(!trade.PositionClose(initialTicket))
      {
         PrintFormat("【竞态瞬间修复】强制平仓失败，错误码:%d，下一秒重试", trade.ResultRetcode());
         return;
      }
      PrintFormat("【竞态瞬间修复】初始单强制平仓成功 Ticket:%I64u", initialTicket);
   }
   // 寻找并接管反向持仓
   ulong newPosID = INVALID_POSITION_ID;
   double openPrice = 0.0;
   long   posType   = -1;
   for(int retry = 0; retry < 8; retry++)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong pt = PositionGetTicket(i);
         if(pt == 0 || !PositionSelectByTicket(pt)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         ulong posID = PositionGetInteger(POSITION_IDENTIFIER);
         if(posID != initialID)
         {
            newPosID  = posID;
            openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            posType   = PositionGetInteger(POSITION_TYPE);
            break;
         }
      }
      if(newPosID != INVALID_POSITION_ID) break;
      Sleep(60);
   }
   if(newPosID != INVALID_POSITION_ID)
   {
      g_monitor_position_id        = newPosID;
      g_monitoring_reverse_position = true;
      g_reverse_order_ticket       = INVALID_ORDER_TICKET;
      g_last_close_was_tp          = false;
      g_pending_reverse_check_time = 0;
      if(openPrice > 0.0)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            g_virtual_tp_price = NormalizeDouble(openPrice + REV_TP_USD, _Digits);
            g_virtual_sl_price = NormalizeDouble(openPrice - REV_SL_USD, _Digits);
         }
         else
         {
            g_virtual_tp_price = NormalizeDouble(openPrice - REV_TP_USD, _Digits);
            g_virtual_sl_price = NormalizeDouble(openPrice + REV_SL_USD, _Digits);
         }
         g_reverse_tp_price = g_virtual_tp_price;
         g_reverse_sl_price = g_virtual_sl_price;
         PrintFormat("【竞态瞬间修复】已接管反向单 ID:%I64u  开仓价:%.5f  TP:%.5f  SL:%.5f",
                     newPosID, openPrice, g_virtual_tp_price, g_virtual_sl_price);
      }
   }
   else
   {
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      Print("【竞态瞬间修复】反向挂单消失但未找到对应持仓，已清理记录");
   }
}
//+------------------------------------------------------------------+
//| 监控持仓状态（加固版）                                             |
//+------------------------------------------------------------------+
void MonitorPositionStatus()
{
   // ★★★ 优先执行虚拟止损/止盈检查（含兜底） ★★★
   CheckVirtualStopsAndClose();
   // 2. 立刻检查：反向挂单是否刚刚成交 → 马上平初始单
   ForceCloseInitialIfReverseTriggered();
   // 延迟撤单逻辑
   if(g_pending_cancel_time > 0)
   {
      if(TimeTradeServer() >= g_pending_cancel_time)
      {
         Print("【延迟期结束】开始验证并清理反向挂单...");
         CancelAssociatedPendingOrder();
         g_pending_cancel_time = 0;
      }
      return;
   }
   // ========== 关键：先处理反向单离场（即使 ID 已被兜底清空也能走到） ==========
   if(g_monitoring_reverse_position)
   {
      // 先确认当前监控的持仓是否已经真正消失
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
      if(stillExists) return;   // 还在，继续监控
      // 已消失 → 进入延迟确认
      if(g_pending_reverse_check_time == 0)
      {
         g_pending_reverse_check_time = TimeTradeServer() + 2;
         PrintFormat("【监控通知】反向翻仓持仓(ID:%I64u)已离场，进入 2 秒延迟确认期...", g_monitor_position_id);
         return;
      }
      if(TimeTradeServer() < g_pending_reverse_check_time) return;
      PrintFormat("【延迟确认】开始最终判断反向持仓(ID:%I64u)是否止盈...", g_monitor_position_id);
      // 优先使用自己记录的标志，再兜底历史判断
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
      // 清理所有状态
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
   // 下面是原来的逻辑（此时已经不是反向单监控状态了）
   if(g_monitor_position_id == INVALID_POSITION_ID) return;
   bool isStillOpen = false;
   
   // 检查真实持仓是否还在
   if(!isStillOpen)
   {
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
   }
   if(isStillOpen) return;
   // === 初始单已消失 ===
   bool isOrderTriggered = false;
   ulong newPositionID = INVALID_POSITION_ID;
   if(g_reverse_order_ticket != INVALID_ORDER_TICKET)
   {
      if(!OrderSelect(g_reverse_order_ticket) || OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED)
      {
         isOrderTriggered = true;
         for(int retry = 0; retry < 5; retry++)
         {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong pt = PositionGetTicket(i);
               if(pt > 0 && PositionSelectByTicket(pt))
               {
                  if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
                     PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                  {
                     ulong posID = PositionGetInteger(POSITION_IDENTIFIER);
                     if(posID != g_monitor_position_id)
                     {
                        newPositionID = posID;
                        break;
                     }
                  }
               }
            }
            if(newPositionID != INVALID_POSITION_ID) break;
            Sleep(80);
         }
      }
   }
   if(isOrderTriggered && newPositionID != INVALID_POSITION_ID)
   {
      // ========== 初始单止损 → 反向单已激活 ==========
      PrintFormat("【监控通知】初始持仓止损离场，反向翻仓单已激活！新持仓ID: %I64u", newPositionID);
      g_monitor_position_id = newPositionID;
      g_monitoring_reverse_position = true;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
      g_last_close_was_tp = false;
      bool foundPos = false;
      double openPrice = 0.0;
      long   posType   = -1;
      for(int retry = 0; retry < 6; retry++)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong pt = PositionGetTicket(i);
            if(pt > 0 && PositionSelectByTicket(pt))
            {
               if(PositionGetInteger(POSITION_IDENTIFIER) == (long)newPositionID &&
                  PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                  PositionGetString(POSITION_SYMBOL) == _Symbol)
               {
                  openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  posType   = PositionGetInteger(POSITION_TYPE);
                  foundPos  = true;
                  break;
               }
            }
         }
         if(foundPos) break;
         Sleep(100);
      }
      if(foundPos && openPrice > 0.0)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            g_virtual_tp_price = NormalizeDouble(openPrice + REV_TP_USD, _Digits);
            g_virtual_sl_price = NormalizeDouble(openPrice - REV_SL_USD, _Digits);
         }
         else
         {
            g_virtual_tp_price = NormalizeDouble(openPrice - REV_TP_USD, _Digits);
            g_virtual_sl_price = NormalizeDouble(openPrice + REV_SL_USD, _Digits);
         }
         g_reverse_tp_price = g_virtual_tp_price;
         g_reverse_sl_price = g_virtual_sl_price;
         PrintFormat("【记录反向单虚拟价位-真实成交价】ID:%I64u  开仓价:%.5f  虚拟SL:%.5f  虚拟TP:%.5f",
                     newPositionID, openPrice, g_virtual_sl_price, g_virtual_tp_price);
      }
      else
      {
         g_virtual_sl_price = g_reverse_sl_price;
         g_virtual_tp_price = g_reverse_tp_price;
         PrintFormat("【记录反向单虚拟价位-兜底预存值】ID:%I64u  虚拟SL:%.5f  虚拟TP:%.5f （注意：可能存在偏差）",
                     newPositionID, g_virtual_sl_price, g_virtual_tp_price);
      }
   }
   else
   {
      // ========== 初始单虚拟止盈离场 ==========
      PrintFormat("【监控通知】初始持仓(ID:%I64u)已正常止盈离场！进入 %d 秒并发保护观察期...",
                  g_monitor_position_id, CancelDelaySec);
      // ★ v2.1.5：止盈后设置延迟撤单（默认5秒，保留并发保护）
      g_pending_cancel_time = TimeTradeServer() + CancelDelaySec;
      g_monitor_position_id = INVALID_POSITION_ID;
      g_monitoring_reverse_position = false;
      g_virtual_sl_price = 0.0;
      g_virtual_tp_price = 0.0;
      g_last_close_was_tp = false;
   }
}
//+------------------------------------------------------------------+
//| 库存费避让相关函数（保持原逻辑）                                   |
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
         if(trade.PositionClose(posTicket))
         {
            closedCount++;
            PrintFormat("【库存费避让】盈利仓位已平仓 Ticket:%I64u  浮动盈亏: %.2f", posTicket, profit);
            Sleep(150);
         }
         else
         {
            PrintFormat("【库存费避让】平仓失败 Ticket:%I64u  错误: %d", posTicket, trade.ResultRetcode());
         }
      }
   }
   if(hasProfitable)
   {
      int deletedCount = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket == 0) continue;
         if(!OrderSelect(orderTicket)) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
         if(trade.OrderDelete(orderTicket))
         {
            deletedCount++;
            PrintFormat("【库存费避让】已撤销挂单 Ticket:%I64u", orderTicket);
            Sleep(100);
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
   // 1. 优先执行基础检查与持仓监控（即使在Swap避让期也要跑）
   CheckAndCloseAllPositions();
   if(g_target_reached) return;
   MonitorPositionStatus();
   // 2. 库存费规避窗口
   if(IsInSwapAvoidWindow(serverNow))
   {
      if(IsInPreSwapWindow(serverNow))
         ScanAndCloseProfitablePositions();
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   // 3. 周末过滤
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
   // 4. 定时开仓触发
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
   // 执行开仓
   if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
   else                                 ExecuteLongOrder();
   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
}
//+------------------------------------------------------------------+
