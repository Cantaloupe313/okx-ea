#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "2.5.0"
// 引入MQL5标准交易类库
#include <Trade\Trade.mqh>
CTrade trade;

//===== 兼容常量定义 =====
#define INVALID_POSITION_ID  0
#define INVALID_ORDER_TICKET 0

//===== 初始方向枚举 =====
enum ENUM_INIT_DIRECTION
{
   DIR_SHORT = 0,   // 初始做空
   DIR_LONG  = 1    // 初始做多
};

//===== 外部参数 =====
input ulong                InpMagicNumber      = 888151;          // EA魔术码
input ENUM_INIT_DIRECTION  InitialDirection     = DIR_SHORT;       // 初始方向
input double               LotShort            = 0.01;            // 初始做空手数
input double               LotLong             = 0.01;            // 初始做多手数
input double               LotLongReverse      = 0.02;            // 做空止损反向多单手数
input double               LotShortReverse     = 0.02;            // 做多止损反向空单手数
input double               TP_USD              = 3;               // 止盈(美元)
input double               SL_USD              = 3;               // 止损(美元)
input int                  RepeatGuardMin      = 2;               // 防重复间隔(分钟)
input int                  CancelDelaySec      = 5;               // 延迟撤单秒数
input double               TargetNetProfit     = 10050.0;         // 目标净值

//===== 隔夜库存费规避参数 =====
input bool                 AvoidSwapWednesdayOnly = false;
input int                  AvoidSwapBeforeMin     = 10;
input int                  AvoidSwapAfterMin      = 10;

//===== 全局变量 =====
datetime g_lastTradeTime        = 0;
datetime g_nextTriggerTime      = 0;
ulong    g_monitor_position_id  = INVALID_POSITION_ID;
ulong    g_reverse_order_ticket = INVALID_ORDER_TICKET;
datetime g_pending_cancel_time  = 0;
bool     g_target_reached       = false;

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
   
   if(InitialDirection == DIR_SHORT)
      PrintFormat("EA启动 v2.5.0 | 大单边策略：初始做空 + 止盈后正向翻仓 | 目标净值: %.2f", TargetNetProfit);
   else
      PrintFormat("EA启动 v2.5.0 | 大单边策略：初始做多 + 止盈后正向翻仓 | 目标净值: %.2f", TargetNetProfit);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
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
            return PositionGetInteger(POSITION_IDENTIFIER);
      }
   }
   return INVALID_POSITION_ID;
}

//+------------------------------------------------------------------+
datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   
   int nextMin = ((dt.min / 15) + 1) * 15;
   
   MqlDateTime nextDt = dt;
   nextDt.min = nextMin % 60;
   nextDt.hour += nextMin / 60;
   nextDt.sec = 0;
   
   datetime candidate = StructToTime(nextDt);
   
   while(candidate <= fromTime || dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      if(candidate <= fromTime)
         candidate += 15 * 60;
      else
         candidate += 3600;
      TimeToStruct(candidate, dt);
   }
   return candidate;
}

//+------------------------------------------------------------------+
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
void CheckAndCloseAllPositions()
{
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
void CancelAssociatedPendingOrder()
{
   if(g_reverse_order_ticket == INVALID_ORDER_TICKET) return;
   
   if(OrderSelect(g_reverse_order_ticket))
   {
      long orderState = OrderGetInteger(ORDER_STATE);
      if(orderState == ORDER_STATE_PLACED)
      {
         if(trade.OrderDelete(g_reverse_order_ticket))
            PrintFormat("【撤单成功】初始单已止盈，成功撤销反向挂单 Ticket：%I64u", g_reverse_order_ticket);
         else
            PrintFormat("【撤单失败】Ticket：%I64u 错误码：%d", g_reverse_order_ticket, trade.ResultRetcode());
      }
      else
         PrintFormat("【撤单跳过】反向挂单 Ticket:%I64u 状态已改变(%d)", g_reverse_order_ticket, orderState);
   }
   else
      PrintFormat("【撤单通知】未找到挂单Ticket：%I64u", g_reverse_order_ticket);
   
   g_reverse_order_ticket = INVALID_ORDER_TICKET;
}

//+------------------------------------------------------------------+
//| 正向翻仓单（大单边核心）                                           |
//+------------------------------------------------------------------+
void ExecuteForwardOrder()
{
   SetTradeFillingMode();
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【错误】获取Tick失败，错误码: ", GetLastError());
      return;
   }
   
   if(InitialDirection == DIR_SHORT)
   {
      // 正向继续做空
      const double bid = tick.bid;
      const double sl_price = NormalizeDouble(bid + SL_USD, _Digits);
      const double tp_price = NormalizeDouble(bid - TP_USD, _Digits);
      
      if(trade.Sell(LotShort, _Symbol, bid, sl_price, tp_price, "Forward Short"))
      {
         ulong deal_ticket = trade.ResultDeal();
         g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                                 HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
         
         // 重新挂反向多单
         double rev_tp = NormalizeDouble(sl_price + TP_USD, _Digits);
         double rev_sl = NormalizeDouble(sl_price - SL_USD, _Digits);
         if(trade.BuyStop(LotLongReverse, sl_price, _Symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse BuyStop"))
            g_reverse_order_ticket = trade.ResultOrder();
         
         PrintFormat("【正向翻仓做空成功】新持仓ID: %I64u, 反向挂单Ticket: %I64u",
                     g_monitor_position_id, g_reverse_order_ticket);
      }
      else
         PrintFormat("【正向翻仓做空失败】错误码: %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
   {
      // 正向继续做多
      const double ask = tick.ask;
      const double sl_price = NormalizeDouble(ask - SL_USD, _Digits);
      const double tp_price = NormalizeDouble(ask + TP_USD, _Digits);
      
      if(trade.Buy(LotLong, _Symbol, ask, sl_price, tp_price, "Forward Long"))
      {
         ulong deal_ticket = trade.ResultDeal();
         g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                                 HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
         
         // 重新挂反向空单
         double rev_tp = NormalizeDouble(sl_price - TP_USD, _Digits);
         double rev_sl = NormalizeDouble(sl_price + SL_USD, _Digits);
         if(trade.SellStop(LotShortReverse, sl_price, _Symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse SellStop"))
            g_reverse_order_ticket = trade.ResultOrder();
         
         PrintFormat("【正向翻仓做多成功】新持仓ID: %I64u, 反向挂单Ticket: %I64u",
                     g_monitor_position_id, g_reverse_order_ticket);
      }
      else
         PrintFormat("【正向翻仓做多失败】错误码: %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

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
   
   PrintFormat("【诊断】品种: %s | Tick时间: %s | 服务器时间: %s | Bid: %.5f | Ask: %.5f | 点差: %d",
               _Symbol,
               TimeToString(tick.time, TIME_DATE|TIME_SECONDS),
               TimeToString(TimeTradeServer(), TIME_DATE|TIME_SECONDS),
               tick.bid, tick.ask,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   
   const double bid = tick.bid;
   const double sl_price = NormalizeDouble(bid + SL_USD, _Digits);
   const double tp_price = NormalizeDouble(bid - TP_USD, _Digits);
   
   if(trade.Sell(LotShort, _Symbol, bid, sl_price, tp_price, "Init Short"))
   {
      ulong deal_ticket = trade.ResultDeal();
      g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                              HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
      
      double rev_tp = NormalizeDouble(sl_price + TP_USD, _Digits);
      double rev_sl = NormalizeDouble(sl_price - SL_USD, _Digits);
      if(trade.BuyStop(LotLongReverse, sl_price, _Symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse BuyStop"))
         g_reverse_order_ticket = trade.ResultOrder();
      
      PrintFormat("【初始做空成功】持仓ID: %I64u, 反向挂单Ticket: %I64u",
                  g_monitor_position_id, g_reverse_order_ticket);
   }
   else
   {
      PrintFormat("【初始做空失败】价格: %.5f SL: %.5f TP: %.5f 错误码: %d (%s)",
                  bid, sl_price, tp_price,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void ExecuteLongOrder()
{
   SetTradeFillingMode();
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【错误】获取Tick失败，错误码: ", GetLastError());
      return;
   }
   
   PrintFormat("【诊断】品种: %s | Tick时间: %s | 服务器时间: %s | Bid: %.5f | Ask: %.5f | 点差: %d",
               _Symbol,
               TimeToString(tick.time, TIME_DATE|TIME_SECONDS),
               TimeToString(TimeTradeServer(), TIME_DATE|TIME_SECONDS),
               tick.bid, tick.ask,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   
   const double ask = tick.ask;
   const double sl_price = NormalizeDouble(ask - SL_USD, _Digits);
   const double tp_price = NormalizeDouble(ask + TP_USD, _Digits);
   
   if(trade.Buy(LotLong, _Symbol, ask, sl_price, tp_price, "Init Long"))
   {
      ulong deal_ticket = trade.ResultDeal();
      g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                              HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();
      
      double rev_tp = NormalizeDouble(sl_price - TP_USD, _Digits);
      double rev_sl = NormalizeDouble(sl_price + SL_USD, _Digits);
      if(trade.SellStop(LotShortReverse, sl_price, _Symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse SellStop"))
         g_reverse_order_ticket = trade.ResultOrder();
      
      PrintFormat("【初始做多成功】持仓ID: %I64u, 反向挂单Ticket: %I64u",
                  g_monitor_position_id, g_reverse_order_ticket);
   }
   else
   {
      PrintFormat("【初始做多失败】价格: %.5f SL: %.5f TP: %.5f 错误码: %d (%s)",
                  ask, sl_price, tp_price,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void MonitorPositionStatus()
{
   // 优先处理延迟撤单
   if(g_pending_cancel_time > 0)
   {
      if(TimeTradeServer() >= g_pending_cancel_time)
      {
         Print("【延迟期结束】开始验证并清理反向挂单 + 执行正向翻仓...");
         CancelAssociatedPendingOrder();
         
         // ===== 大单边核心：止盈后下正向翻仓单 =====
         ExecuteForwardOrder();
         
         g_pending_cancel_time = 0;
      }
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
   
   // 持仓已消失，判断是止盈还是止损翻仓
   bool isOrderTriggered = false;
   ulong newPositionID = INVALID_POSITION_ID;
   
   if(g_reverse_order_ticket != INVALID_ORDER_TICKET)
   {
      if(!OrderSelect(g_reverse_order_ticket) || OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED)
      {
         isOrderTriggered = true;
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
      }
   }
   
   if(isOrderTriggered && newPositionID != INVALID_POSITION_ID)
   {
      // 止损翻仓 → 更新监控ID
      PrintFormat("【监控通知】初始持仓止损离场，反向翻仓单已激活！新持仓ID: %I64u", newPositionID);
      g_monitor_position_id = newPositionID;
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
   }
   else
   {
      // 止盈离场 → 进入延迟观察期，之后会下正向翻仓单
      PrintFormat("【监控通知】初始持仓(ID:%I64u)已正常止盈离场！进入 %d 秒观察期后执行正向翻仓...",
                  g_monitor_position_id, CancelDelaySec);
      
      g_pending_cancel_time = TimeTradeServer() + CancelDelaySec;
      g_monitor_position_id = INVALID_POSITION_ID;
   }
}

//+------------------------------------------------------------------+
bool IsInSwapAvoidWindow(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   if(AvoidSwapWednesdayOnly)
   {
      if(dt.day_of_week == 3)           // 周三
      {
         if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      }
      else if(dt.day_of_week == 4)      // 周四
      {
         if(dt.hour == 0 && dt.min < AvoidSwapAfterMin) return true;
      }
      return false;
   }
   else
   {
      if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      if(dt.hour == 0 && dt.min < AvoidSwapAfterMin) return true;
      return false;
   }
}

//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();
   
   if(g_target_reached) return;
   
   // 1. 目标净值 + 持仓监控（不受避让窗影响）
   CheckAndCloseAllPositions();
   if(g_target_reached) return;
   MonitorPositionStatus();
   
   // 2. 库存费避让窗（只限制开仓）
   if(IsInSwapAvoidWindow(serverNow))
   {
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
   // 3. 周末过滤
   MqlDateTime dt;
   TimeToStruct(serverNow, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
   // 4. 定时触发控制
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
   
   // 执行初始开仓
   if(InitialDirection == DIR_SHORT) ExecuteShortOrder();
   else                              ExecuteLongOrder();
   
   g_lastTradeTime   = serverNow;
   g_nextTriggerTime = nextAfterThis;
}