#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "2.4.4"

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
input ulong  InpMagicNumber     = 888151;  // EA魔术码(用于区分订单)
input ENUM_INIT_DIRECTION InitialDirection = DIR_SHORT; // 初始方向
input double LotShort           = 1.0;     // 初始做空手数
input double LotLong            = 1.0;     // 初始做多手数
input double LotLongReverse     = 2.0;     // 做空止损反向多单手数
input double LotShortReverse    = 2.0;     // 做多止损反向空手数
input double TP_USD             = 2.0;     // 止盈(美元，XAUUSD价格差)
input double SL_USD             = 2.0;     // 止损(美元，XAUUSD价格差)
input int    RepeatGuardMin     = 2;       // 防重复间隔(分钟)
input int    CancelDelaySec     = 10;      // 延迟撤单秒数(防止平仓与挂单触发的并发冲突)

//===== 全局变量 =====
datetime g_lastTradeTime = 0;        // 上次下单时间戳
datetime g_nextTriggerTime = 0;      // 下次定时触发时间
ulong g_monitor_position_id = INVALID_POSITION_ID; // 待监控的持仓唯一ID
ulong g_reverse_order_ticket = INVALID_ORDER_TICKET; // 关联的反向翻仓挂单Ticket
datetime g_pending_cancel_time = 0;  // 计划执行撤单的时间 (0表示无计划)

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
      Print("EA启动，规则：定时自动做空 + 立即挂反向多单");
   else
      Print("EA启动，规则：定时自动做多 + 立即挂反向空单");
   
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
//| 例如："XAUUSD.n" -> "XAUUSD" | "EURUSDm" -> "EURUSD"             |
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
//| 辅助函数：获取当前魔术码最新的持仓 ID                            |
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
//| 工具函数：准确计算下一个 00/15/30/45 分 00 秒触发点                    |
//+------------------------------------------------------------------+
datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   
   int nextMin = 0;
   if(dt.min < 5)      nextMin = 5;
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
   else                 nextMin = 60;
   
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
//| 检查是否存在任意方向的未成交挂单（兼容后缀与同魔术码）             |
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
//| 检查是否存在任意方向的已成交持仓（兼容后缀与同魔术码）             |
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
//| 安全撤销关联的反向挂单（绝不影响持仓）                              |
//+------------------------------------------------------------------+
void CancelAssociatedPendingOrder()
{
   if(g_reverse_order_ticket == INVALID_ORDER_TICKET) return;
   
   if(OrderSelect(g_reverse_order_ticket))
   {
      if(trade.OrderDelete(g_reverse_order_ticket))
         PrintFormat("【撤单成功】初始持仓已离场，成功撤销关联的未成交挂单，Ticket：%d", g_reverse_order_ticket);
      else
         PrintFormat("【撤单失败】尝试撤销挂单失败，Ticket：%d，错误码：%d", g_reverse_order_ticket, trade.ResultRetcode());
   }
   else
   {
      PrintFormat("【安全跳过】未在挂单列表中找到Ticket:%d。该反向挂单已触发成交为【持仓】(止损翻仓成功)，程序不做任何平仓干预！", g_reverse_order_ticket);
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

   PrintFormat("【监控通知】初始持仓(ID:%d)已离场！为防止止损翻仓延迟被误撤单，系统进入 %d 秒观察期...", 
               g_monitor_position_id, CancelDelaySec);
   
   g_pending_cancel_time = TimeTradeServer() + CancelDelaySec; 
   g_monitor_position_id = INVALID_POSITION_ID;
}

//+------------------------------------------------------------------+
//| 定时器主逻辑                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(serverNow, dt); 
   
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
   {
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   
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
   
   // ===== 核心改动：存在任何未成交挂单 或 任何已成交持仓 时，跳过本次定时任务 =====
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