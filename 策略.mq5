#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "2.4.9"

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
input double TP_USD             = 3;     // 止盈(美元，XAUUSD价格差)
input double SL_USD             = 3;     // 止损(美元，XAUUSD价格差)
input int    RepeatGuardMin     = 2;       // 防重复间隔(分钟)
input int    CancelDelaySec     = 5;      // 延迟撤单秒数(防止平仓与挂单触发的并发冲突)
input double TargetNetProfit    = 10050.0;  // 目标净值(达到后全部平仓并停止)
input double MaxDrawdownPct     = 50.0;    // 最大回撤率(%)，达到后终止EA并清仓

//===== 隔夜库存费规避参数 =====
input bool   AvoidSwapWednesdayOnly = false; // 是否仅在周三深夜规避库存费
input int    AvoidSwapBeforeMin     = 10;   // 扣除库存费前停止时间(分钟)
input int    AvoidSwapAfterMin      = 10;   // 扣除库存费后恢复时间(分钟)

//===== 全局变量 =====
datetime g_lastTradeTime = 0;        // 上次下单时间戳
datetime g_nextTriggerTime = 0;      // 下次定时触发时间
ulong g_monitor_position_id = INVALID_POSITION_ID; // 待监控的持仓唯一ID
ulong g_reverse_order_ticket = INVALID_ORDER_TICKET; // 关联的反向翻仓挂单Ticket
datetime g_pending_cancel_time = 0;  // 计划执行撤单的时间 (0表示无计划)
bool  g_target_reached = false;    // 目标净值是否已达成标志
double g_max_drawdown = 0.0;        // 当前最大回撤(美元)
bool  g_stop_on_drawdown = false;   // 是否因回撤停止标志

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
   
   if(InitialDirection == DIR_SHORT)
      PrintFormat("EA启动，规则：定时自动做空 + 立即挂反向多单 | 目标净值: %.2f", TargetNetProfit);
   else
      PrintFormat("EA启动，规则：定时自动做多 + 立即挂反向空单 | 目标净值: %.2f", TargetNetProfit);
   
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
//| 辅助函数：提取商品的基础名称（自动剥离后缀）                           |
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
//| 辅助函数：获取当前魔术码最新的持仓 ID                             |
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
//| 工具函数：准确计算下一个触发点 (修改为每15分钟：00, 15, 30, 45)  |
//+------------------------------------------------------------------+
datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   
   // 计算下一个15分钟的整数倍分钟数
   int nextMin = ((dt.min / 5) + 1) * 5;
   
   MqlDateTime nextDt = dt;
   nextDt.min = nextMin % 60;   // 超过60分钟会自动取模
   nextDt.hour += nextMin / 60; // 超过60分钟小时数+1
   nextDt.sec = 0;
   
   datetime candidate = StructToTime(nextDt);
   
   // 如果计算出的时间小于等于当前时间，或者属于周末（周六0或周日6），则继续往后推
   while(candidate <= fromTime || dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      if(candidate <= fromTime) 
         candidate += 5 * 60;  // 每次递增15分钟
      else 
         candidate += 3600;     // 周末跳过
         
      TimeToStruct(candidate, dt);
   }
   return candidate;
}

//===== 防重复校验函数 =====
bool CheckHasAnyPendingOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      if(OrderSelect(orderTicket))
      {
         if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), _Symbol) && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
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
         if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL), _Symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
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
//| 回撤止损：停止EA并清仓清单                                         |
//+------------------------------------------------------------------+
void StopEAAndClean()
{
   PrintFormat("【回撤保护】回撤率 %.2f%% 已达到阈值 %.2f%%，终止EA并清理仓位！", g_max_drawdown / (AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) * AccountInfoDouble(ACCOUNT_MARGIN)) * 100, MaxDrawdownPct);

   // 清理所有仓位
   int closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0 && PositionSelectByTicket(posTicket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            if(trade.PositionClose(posTicket))
               closedCount++;
            Sleep(200);
         }
      }
   }

   // 清理所有委托
   int deletedCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0 && OrderSelect(orderTicket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
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
//| 计算并检查最大回撤                                                   |
//+------------------------------------------------------------------+
void CalculateMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_BALANCE) + AccountInfoDouble(ACCOUNT_PROFIT);
   static double highestEquity = 0.0;

   // 首次调用时，记录初始权益作为基准（此时 g_max_drawdown 应该为 0）
   if(g_max_drawdown == 0.0 && highestEquity == 0.0)
   {
      highestEquity = currentEquity;
      g_max_drawdown = 0.0;
      return;
   }

   // 计算回撤百分比（相对于历史最高权益）
   double drawdownPct = 0.0;
   if(highestEquity > 0.0)
   {
      drawdownPct = ((highestEquity - currentEquity) / highestEquity) * 100.0;
   }

   g_max_drawdown = highestEquity - currentEquity;

   // 更新历史最高权益
   if(currentEquity > highestEquity)
   {
      highestEquity = currentEquity;
   }

   // 如果回撤超过阈值，触发停止
   if(drawdownPct >= MaxDrawdownPct && !g_stop_on_drawdown)
   {
      PrintFormat("【回撤保护】检测到回撤率 %.2f%%，达到阈值 %.2f%%，立即停止EA并清仓！", drawdownPct, MaxDrawdownPct);
      g_stop_on_drawdown = true;
      StopEAAndClean();
   }
}

//+------------------------------------------------------------------+
//| 检查目标净值                                                     |
//+------------------------------------------------------------------+
void CheckAndCloseAllPositions()
{
   // 检查回撤是否达到阈值
   CalculateMaxDrawdown();

   // 如果已经因回撤停止，不再执行任何操作
   if(g_stop_on_drawdown) return;

   if(AccountInfoDouble(ACCOUNT_EQUITY) >= TargetNetProfit)
   {
      Print("【目标净值达成】正在全面清仓与撤单...");

      // 平仓
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
               trade.PositionClose(posTicket);
         }
      }
      Sleep(500);
      // 撤单
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket > 0 && OrderSelect(orderTicket))
         {
            if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
               trade.OrderDelete(orderTicket);
         }
      }
      g_target_reached = true;
   }
}

//+------------------------------------------------------------------+
//| 安全撤销关联的反向挂单                                           |
//+------------------------------------------------------------------+
void CancelAssociatedPendingOrder()
{
   if(g_reverse_order_ticket == INVALID_ORDER_TICKET) return;
   
   // 再次确认该挂单是否还未成交（如果类型变成了已成交或被删除，则不处理）
   if(OrderSelect(g_reverse_order_ticket))
   {
      long orderState = OrderGetInteger(ORDER_STATE);
      // 只有当挂单处于“等待中(PLACED)”状态时才执行删除，防止把已经触发转为持仓的单子误删
      if(orderState == ORDER_STATE_PLACED)
      {
         if(trade.OrderDelete(g_reverse_order_ticket))
            PrintFormat("【撤单成功】初始单已平仓(止盈)，成功撤销关联未成交翻仓单，Ticket：%I64u", g_reverse_order_ticket);
         else
            PrintFormat("【撤单失败】尝试撤销挂单失败，Ticket：%I64u，错误码：%d", g_reverse_order_ticket, trade.ResultRetcode());
      }
      else
         PrintFormat("【撤单跳过】反向挂单 Ticket:%I64u 状态已改变(%d)，极可能已被止损触发激活。", g_reverse_order_ticket, orderState);
   }
   else
   {
      PrintFormat("【撤单通知】未找到挂单Ticket：%I64u，可能已被激活或手动删除。", g_reverse_order_ticket);
   }
   
   g_reverse_order_ticket = INVALID_ORDER_TICKET;
}

//+------------------------------------------------------------------+
//| 下单逻辑                                                         |
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

   // 打印诊断信息（非常重要）
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
         
      PrintFormat("【初始做空成功】持仓ID: %I64u, 反向挂单Ticket: %I64u", g_monitor_position_id, g_reverse_order_ticket);
   }
   else
   {
      // 把开仓价也打出来，方便排查 invalid stops
      PrintFormat("【初始做空失败】价格: %.5f  SL: %.5f  TP: %.5f  错误码: %d (%s)",
                  bid, sl_price, tp_price,
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

   // 打印诊断信息（非常重要）
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

      PrintFormat("【初始做多成功】持仓ID: %I64u, 反向挂单Ticket: %I64u", g_monitor_position_id, g_reverse_order_ticket);
   }
   else
   {
      // 把开仓价也打出来，方便排查 invalid stops
      PrintFormat("【初始做多失败】价格: %.5f  SL: %.5f  TP: %.5f  错误码: %d (%s)",
                  ask, sl_price, tp_price,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

void MonitorPositionStatus()
{
   // 优先处理观察期延迟撤单逻辑
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
   
   // 如果初始持仓还在，继续监控
   if(isStillOpen) return;

   // === 漏洞修复与逻辑优化 ===
   // 初始仓位消失了，检查反向挂单的状态，判断是“止盈”还是“止损翻仓”
   bool isOrderTriggered = false;
   ulong newPositionID = INVALID_POSITION_ID;

   if(g_reverse_order_ticket != INVALID_ORDER_TICKET)
   {
      // 如果挂单在活动订单列表中找不到了，或者状态变了，说明可能触发了
      if(!OrderSelect(g_reverse_order_ticket) || OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED)
      {
         isOrderTriggered = true;
         // 尝试去持仓列表里找由这个MagicNumber生成的、且不是原ID的新持仓
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong pt = PositionGetTicket(i);
            if(pt > 0 && PositionSelectByTicket(pt))
            {
               if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
               {
                  ulong posID = PositionGetInteger(POSITION_IDENTIFIER);
                  if(posID != g_monitor_position_id)
                  {
                     newPositionID = posID; // 找到了翻仓后的新持仓ID
                     break;
                  }
               }
            }
         }
      }
   }

   if(isOrderTriggered && newPositionID != INVALID_POSITION_ID)
   {
      // 属于【止损翻仓】情况：更新监控ID为新持仓的ID，不执行撤单流程
      PrintFormat("【监控通知】初始持仓止损离场，反向翻仓单已激活！新持仓ID: %I64u", newPositionID);
      g_monitor_position_id = newPositionID; 
      g_reverse_order_ticket = INVALID_ORDER_TICKET; // 挂单已成持仓，释放挂单Ticket
   }
   else
   {
      // 属于【止盈离场】情况：进入延迟撤单流程
      PrintFormat("【监控通知】初始持仓(ID:%I64u)已正常止盈离场！进入 %d 秒并发保护观察期...", 
                  g_monitor_position_id, CancelDelaySec);
      
      g_pending_cancel_time = TimeTradeServer() + CancelDelaySec; 
      g_monitor_position_id = INVALID_POSITION_ID; // 正常释放
   }
}

//+------------------------------------------------------------------+
//| 检查是否处于库存费避让窗口                                         |
//+------------------------------------------------------------------+
bool IsInSwapAvoidWindow(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   if(AvoidSwapWednesdayOnly)
   {
      if(dt.day_of_week == 3) // 周三
      {
         if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      }
      else if(dt.day_of_week == 4) // 周四
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

//+------------------------------------------------------------------+
//| 定时器主逻辑                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();

   // ===== 回撤保护优先级最高 =====
   if(g_stop_on_drawdown) return;

   // ===== 核心逻辑优化：生命周期监控与目标净值检查不受避让窗影响 =====
   if(g_target_reached) return;

   // 1. 优先执行基础系统检查与持仓监控（即使在Swap避让期也要跑，否则止盈单在避让期内成交将无法撤单）
   CheckAndCloseAllPositions();
   if(g_target_reached) return;

   MonitorPositionStatus();

   // 2. 检查是否处于库存费规避时间段（只限制开仓动作）
   if(IsInSwapAvoidWindow(serverNow))
   {
      // 处于避让期时，更新下一次定时开仓的时间，并退出开仓流
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }

   // 3. 过滤周末
   MqlDateTime dt;
   TimeToStruct(serverNow, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
   // 4. 定时开仓触发控制
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
   
   // 执行开仓
   if(InitialDirection == DIR_SHORT) ExecuteShortOrder();
   else                              ExecuteLongOrder();
      
   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
}