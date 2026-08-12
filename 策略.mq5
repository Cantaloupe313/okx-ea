#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "2.4.6"

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
input double LotShort           = 1.0;     // 初始做空手数
input double LotLong            = 1.0;     // 初始做多手数
input double LotLongReverse     = 2.0;     // 做空止损反向多单手数
input double LotShortReverse    = 2.0;     // 做多止损反向空手数
input double TP_USD             = 2.0;     // 止盈(美元，XAUUSD价格差)
input double SL_USD             = 2.0;     // 止损(美元，XAUUSD价格差)
input int    RepeatGuardMin     = 2;       // 防重复间隔(分钟)
input int    CancelDelaySec     = 10;      // 延迟撤单秒数(防止平仓与挂单触发的并发冲突)
input double TargetNetProfit    = 100000.0;  // 目标净值(达到后全部平仓并停止)

//===== 新增：隔夜库存费规避参数 =====
input bool   AvoidSwapWednesdayOnly = false; // 是否仅在周三深夜(即周三到周四0点)规避库存费(false则每天规避)
input int    AvoidSwapBeforeMin     = 10;   // 扣除库存费前停止时间(分钟)
input int    AvoidSwapAfterMin      = 10;   // 扣除库存费后恢复时间(分钟)

//===== 全局变量 =====
datetime g_lastTradeTime = 0;        // 上次下单时间戳
datetime g_nextTriggerTime = 0;      // 下次定时触发时间
ulong g_monitor_position_id = INVALID_POSITION_ID; // 待监控的持仓唯一ID
ulong g_reverse_order_ticket = INVALID_ORDER_TICKET; // 关联的反向翻仓挂单Ticket
datetime g_pending_cancel_time = 0;  // 计划执行撤单的时间 (0表示无计划)
bool  g_target_reached = false;    // 目标净值是否已达成标志

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
//| 辅助函数：提取商品的基础名称（自动剥离 .n, m, pro 等各种后缀）         |
//+------------------------------------------------------------------+
string GetBaseSymbol(string fullSymbol)
{
   StringToUpper(fullSymbol);
   
   int dotPos = StringFind(fullSymbol, ".");
   if(dotPos > 0)
   {
      return StringSubstr(fullSymbol, 0, dotPos);
   }
   
   if(StringLen(fullSymbol) > 6)
   {
      return StringSubstr(fullSymbol, 0, 6);
   }
   
   return fullSymbol;
}

//+------------------------------------------------------------------+
//| 判断两个品种是否属于同一个基础商品                               |
//+------------------------------------------------------------------+
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
//| 工具函数：准确计算下一个 05/10/15... 分 00 秒触发点                  |
//+------------------------------------------------------------------+
datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   
   int nextMin = 0;
   if(dt.min < 5)       nextMin = 5;
   else if(dt.min < 10)      nextMin = 10;
   else if(dt.min < 15)      nextMin = 15;
   else if(dt.min < 20)      nextMin = 20;
   else if(dt.min < 25)      nextMin = 25;
   else if(dt.min < 30) nextMin = 30;
   else if(dt.min < 35)      nextMin = 35;
   else if(dt.min < 40)      nextMin = 40;
   else if(dt.min < 45) nextMin = 45;
   else if(dt.min < 50)      nextMin = 50;
   else if(dt.min < 55)      nextMin = 55;
   else                      nextMin = 60;
   
   MqlDateTime nextDt = dt;
   nextDt.min = nextMin % 60;
   nextDt.hour += nextMin / 60;
   nextDt.sec = 0;
   
   datetime candidate = StructToTime(nextDt);
   
   while(candidate <= fromTime || dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      if(candidate <= fromTime)
         candidate += 5 * 60; 
      else
         candidate += 3600;    
      TimeToStruct(candidate, dt);
   }
   return candidate;
}

//+------------------------------------------------------------------+
//| 检查是否存在任意方向的未成交挂单（兼容后缀与同魔术码）              |
//+------------------------------------------------------------------+
bool CheckHasAnyPendingOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      
      if(OrderSelect(orderTicket))
      {
         string orderSymbol = OrderGetString(ORDER_SYMBOL);
         
         if(IsSameBaseSymbol(orderSymbol, _Symbol))
         {
            if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
            {
               PrintFormat("【防重复校验】拦截！同基础商品(%s)已存在未成交挂单 Ticket:%I64u", orderSymbol, orderTicket);
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 检查是否存在任意方向的已成交持仓（兼容后缀与同魔术码）              |
//+------------------------------------------------------------------+
bool CheckHasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      
      if(PositionSelectByTicket(posTicket))
      {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         
         if(IsSameBaseSymbol(posSymbol, _Symbol))
         {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            {
               PrintFormat("【防重复校验】拦截！同基础商品(%s)已存在持仓 Ticket:%I64u", posSymbol, posTicket);
               return true;
            }
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
//| 检查并平仓所有持仓、撤单所有挂单，达到目标净值后停止EA运行              |
//+------------------------------------------------------------------+
void CheckAndCloseAllPositions()
{
   if(AccountInfoDouble(ACCOUNT_EQUITY) >= TargetNetProfit)
   {
      Print("【目标净值达成】正在平仓所有持仓并撤单...");

      // 平仓所有持仓
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket == 0) continue;

         if(PositionSelectByTicket(posTicket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            {
               long posType = PositionGetInteger(POSITION_TYPE);
               if(trade.PositionClose(posTicket))
               {
                  PrintFormat("【平仓成功】Ticket: %I64u, 类型: %s", posTicket,
                              (posType == POSITION_TYPE_BUY ? "多单" : "空单"));
               }
               else
               {
                  PrintFormat("【平仓失败】Ticket: %I64u, 错误码: %d",
                              posTicket, trade.ResultRetcode());
               }
            }
         }
      }

      Sleep(1000);

      // 撤单所有挂单
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket == 0) continue;

         if(OrderSelect(orderTicket))
         {
            if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
               OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
            {
               if(trade.OrderDelete(orderTicket))
               {
                  PrintFormat("【撤单成功】Ticket: %I64u", orderTicket);
               }
               else
               {
                  PrintFormat("【撤单失败】Ticket: %I64u, 错误码: %d",
                              orderTicket, trade.ResultRetcode());
               }
            }
         }
      }

      g_target_reached = true;
      PrintFormat("【EA终止】目标净值 %.2f 已达成，已平仓所有持仓并撤单所有挂单！", TargetNetProfit);
   }
}

//+------------------------------------------------------------------+
//| 安全撤销关联的反向挂单（绝不影响持仓）                               |
//+------------------------------------------------------------------+
void CancelAssociatedPendingOrder()
{
   if(g_reverse_order_ticket == INVALID_ORDER_TICKET) return;
   
   if(OrderSelect(g_reverse_order_ticket))
   {
      if(trade.OrderDelete(g_reverse_order_ticket))
         PrintFormat("【撤单成功】初始持仓已离场，成功撤销关联的未成交挂单，Ticket：%I64u", g_reverse_order_ticket);
      else
         PrintFormat("【撤单失败】尝试撤销挂单失败，Ticket：%I64u，错误码：%d", g_reverse_order_ticket, trade.ResultRetcode());
   }
   
   g_reverse_order_ticket = INVALID_ORDER_TICKET;
}

//+------------------------------------------------------------------+
//| 下单逻辑                                                         |
//+------------------------------------------------------------------+
void ExecuteShortOrder()
{
   SetTradeFillingMode();
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double sl_price = NormalizeDouble(bid + SL_USD, _Digits);
   const double tp_price = NormalizeDouble(bid - TP_USD, _Digits);
   
   if(trade.Sell(LotShort, _Symbol, bid, sl_price, tp_price, "Init Short"))
   {
      ulong deal_ticket = trade.ResultDeal();
      if(deal_ticket > 0 && HistoryDealSelect(deal_ticket))
      {
         g_monitor_position_id = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      }
      else
      {
         g_monitor_position_id = GetLatestPositionID();
      }

      double rev_tp = NormalizeDouble(sl_price + TP_USD, _Digits);
      double rev_sl = NormalizeDouble(sl_price - SL_USD, _Digits);
      if(trade.BuyStop(LotLongReverse, sl_price, _Symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse BuyStop"))
         g_reverse_order_ticket = trade.ResultOrder();
         
      PrintFormat("【初始做空成功】持仓ID: %I64u, 反向挂单Ticket: %I64u", g_monitor_position_id, g_reverse_order_ticket);
   }
}

void ExecuteLongOrder()
{
   SetTradeFillingMode();
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double sl_price = NormalizeDouble(ask - SL_USD, _Digits);
   const double tp_price = NormalizeDouble(ask + TP_USD, _Digits);
   
   if(trade.Buy(LotLong, _Symbol, ask, sl_price, tp_price, "Init Long"))
   {
      ulong deal_ticket = trade.ResultDeal();
      if(deal_ticket > 0 && HistoryDealSelect(deal_ticket))
      {
         g_monitor_position_id = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      }
      else
      {
         g_monitor_position_id = GetLatestPositionID();
      }

      double rev_tp = NormalizeDouble(sl_price - TP_USD, _Digits);
      double rev_sl = NormalizeDouble(sl_price + SL_USD, _Digits);
      if(trade.SellStop(LotShortReverse, sl_price, _Symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse SellStop"))
         g_reverse_order_ticket = trade.ResultOrder();

      PrintFormat("【初始做多成功】持仓ID: %I64u, 反向挂单Ticket: %I64u", g_monitor_position_id, g_reverse_order_ticket);
   }
}

//+------------------------------------------------------------------+
//| 定时器监控初始持仓生命周期                                         |
//+------------------------------------------------------------------+
void MonitorPositionStatus()
{
   if(g_pending_cancel_time > 0)
   {
      if(TimeTradeServer() >= g_pending_cancel_time)
      {
         Print("【延迟期结束】开始验证反向挂单状态...");
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
   
   if(isStillOpen) return;

   PrintFormat("【监控通知】初始持仓(ID:%I64u)已离场！为防止止损翻仓延迟被误撤单，系统进入 %d 秒观察期...", 
               g_monitor_position_id, CancelDelaySec);
   
   g_pending_cancel_time = TimeTradeServer() + CancelDelaySec; 
   g_monitor_position_id = INVALID_POSITION_ID;
}

//+------------------------------------------------------------------+
//| 新增核心函数：检查当前时间是否处于库存费避让窗口                     |
//+------------------------------------------------------------------+
bool IsInSwapAvoidWindow(datetime serverTime)
{
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // 如果开启了“仅在周三规避”，则非周三(dt.day_of_week==3)或非周四前夕直接返回 false
   // 平台一般在服务器时间周三 23:59:59 进入周四 00:00:00 时扣除3倍库存费
   if(AvoidSwapWednesdayOnly)
   {
      // 窗口可能跨越周三23点到周四0点
      // 如果是周三，检查是否在 23:(60 - AvoidSwapBeforeMin) 之后
      if(dt.day_of_week == 3)
      {
         if(dt.hour != 23 || dt.min < (60 - AvoidSwapBeforeMin)) 
            return false;
      }
      // 如果是周四，检查是否在 00:AvoidSwapAfterMin 之前
      else if(dt.day_of_week == 4)
      {
         if(dt.hour != 0 || dt.min >= AvoidSwapAfterMin)
            return false;
      }
      else
      {
         return false; // 其他日子不限制
      }
   }
   else
   {
      // 每天都避开0点前后
      // 跨深夜0点情况：23点后半段 或 0点前半段
      if(dt.hour == 23 && dt.min >= (60 - AvoidSwapBeforeMin)) return true;
      if(dt.hour == 0  && dt.min < AvoidSwapAfterMin) return true;
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| 定时器主逻辑                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();
   
   // ===== 核心改动 1：检查是否处于库存费规避时间段 =====
   if(IsInSwapAvoidWindow(serverNow))
   {
      // 处于避让期时，静默跳过，不做任何开仓/监控动作
      // 重新修正下一次触发时间，确保避让期结束后能立刻重新计算
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }

   MqlDateTime dt;
   TimeToStruct(serverNow, dt);

   // 检查是否已达到目标净值
   if(g_target_reached)
   {
      return;
   }

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }

   // 检查并执行目标净值平仓逻辑
   CheckAndCloseAllPositions();

   if(g_target_reached)
      return;

   MonitorPositionStatus();
   
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
      PrintFormat("【定时任务】时间: %s，存在未成交委托或已成交仓位，跳过本次执行，下次触发时间设为: %s", 
                  TimeToString(serverNow, TIME_DATE|TIME_MINUTES), 
                  TimeToString(nextAfterThis, TIME_DATE|TIME_MINUTES));
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   
   if(InitialDirection == DIR_SHORT) ExecuteShortOrder();
   else                              ExecuteLongOrder();
      
   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
}