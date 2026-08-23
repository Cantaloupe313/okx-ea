#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "3.0.0"
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
input ulong    InpMagicNumber     = 888151;    // EA魔术码(用于区分订单)
input ENUM_INIT_DIRECTION InitialDirection = DIR_SHORT; // 初始方向
input double   LotShort           = 0.01;      // 初始做空手数
input double   LotLong            = 0.01;      // 初始做多手数
input double   LotLongReverse     = 0.02;      // 做空止损反向多单手数
input double   LotShortReverse    = 0.02;      // 做多止损反向空手数
input double   TP_USD             = 18;        // 止盈(美元)
input double   SL_USD             = 18;        // 止损(美元)
input int      RepeatGuardMin     = 2;         // 防重复间隔(分钟)
input int      CancelDelaySec     = 5;         // 延迟撤单秒数(防止平仓与挂单触发的并发冲突)
input double   TargetNetProfit    = 150;       // 目标净值(达到后全部平仓并停止)
input double   MaxDrawdownPct     = 50.0;      // 最大回撤率(%)，达到后终止EA并清仓
input bool     ReverseDirectionAfterSL = true; // 初始单止损平仓后，下一次方向是否反转
//===== 库存费规避参数 =====
input int      SwapAvoidBeforeMin     = 45;    // 扣除库存费前检查并清理盈利仓位的时间(分钟)
//===== 全局变量 =====
string g_symbol;                    // 当前交易品种
datetime g_lastTradeTime = 0;        // 上次下单时间戳
datetime g_nextTriggerTime = 0;      // 下次定时触发时间
datetime g_swap_check_time = 0;      // 下次库存费检查时间
ulong g_monitor_position_id = INVALID_POSITION_ID; // 待监控的持仓唯一ID
ulong g_reverse_order_ticket = INVALID_ORDER_TICKET; // 关联的反向翻仓挂单Ticket
datetime g_pending_cancel_time = 0;  // 计划执行撤单的时间 (0表示无计划)
bool  g_target_reached = false;    // 目标净值是否已达成标志
double g_max_drawdown = 0.0;        // 当前最大回撤(美元)
bool  g_stop_on_drawdown = false;   // 是否因回撤停止标志
ENUM_INIT_DIRECTION g_currentDirection = DIR_SHORT; // 当前执行方向（用于方向反转功能）
datetime g_swap_window_start = 0;   // 库存费时间窗口开始时间
datetime g_swap_window_end = 0;     // 库存费时间窗口结束时间
static double g_highest_equity = 0.0;
//+------------------------------------------------------------------+
//| MqlDateTime标准化：处理分钟>=60、小时>=24进位                     |
//+------------------------------------------------------------------+
void NormalizeDateTime(MqlDateTime &dt)
{
   while(dt.min >= 60)
   {
      dt.min -= 60;
      dt.hour += 1;
   }
   while(dt.hour >= 24)
   {
      dt.hour -= 24;
      dt.day += 1;
   }
}
//+------------------------------------------------------------------+
//| 根据美元盈亏换算价格点数(返回价格差值)                              |
//+------------------------------------------------------------------+
double CalcPriceDistanceByUSD(double usd_value, double lot)
{
   if(lot <= 0) return 0.0;
   double tick_value = SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <=0 || tick_size <=0) return 0.0;
   // 该手数下，每tick盈亏美元 tick_value * lot
   double usd_per_tick = tick_value * lot;
   if(usd_per_tick <= 0) return 0.0;
   double tick_count = usd_value / usd_per_tick;
   return tick_count * tick_size;
}
//+------------------------------------------------------------------+
//| 初始化商品信息和库存费时间窗口                                    |
//+------------------------------------------------------------------+
bool InitializeSymbolInfo()
{
   g_symbol = _Symbol;
   if(!SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE))
   {
      PrintFormat("【错误】当前图表商品 '%s' 不存在或无法交易！", g_symbol);
      return false;
   }
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   DetectSwapWindow();
   double contract_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contract_size <= 0)
   {
      PrintFormat("【错误】商品 %s 不支持足额交易，无法使用该品种", g_symbol);
      return false;
   }
   PrintFormat("【初始化成功】当前图表商品: %s | 小数位数: %d | 合约大小: %.2f | 库存费窗口: %s-%s",
               g_symbol, digits, contract_size,
               TimeToString(g_swap_window_start, TIME_MINUTES),
               TimeToString(g_swap_window_end, TIME_MINUTES));
   return true;
}
//+------------------------------------------------------------------+
//| 解析库存费时间窗口字符串 (HH:MM 格式)                              |
//+------------------------------------------------------------------+
bool ParseSwapWindowTime(string timeStr, datetime &outTime)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = (int)StringToInteger(StringSubstr(timeStr, 0, 2));
   int min = (int)StringToInteger(StringSubstr(timeStr, 3, 2));
   if(hour < 0 || hour > 23 || min < 0 || min > 59)
   {
      PrintFormat("【警告】时间格式错误: %s", timeStr);
      return false;
   }
   dt.hour = hour;
   dt.min = min;
   dt.sec = 0;
   outTime = StructToTime(dt);
   return true;
}
//+------------------------------------------------------------------+
//| 检测当前商品对应的库存费扣取时间窗口                                |
//+------------------------------------------------------------------+
void DetectSwapWindow()
{
   if(g_symbol == "XAUUSD" || g_symbol == "XAU" || g_symbol == "GOLD" ||
      g_symbol == "XAGUSD" || g_symbol == "XAG" || g_symbol == "SILVER")
   {
      g_swap_window_start = StringToTime("23:00");
      g_swap_window_end = StringToTime("00:00");
      PrintFormat("【库存费检测】%s：周三23:00-周四00:00", g_symbol);
   }
   else if(g_symbol == "USDJPY" || g_symbol == "USD/JPY")
   {
      g_swap_window_start = StringToTime("22:00");
      g_swap_window_end = StringToTime("00:00");
      PrintFormat("【库存费检测】%s：周一22:00-周二00:00", g_symbol);
   }
   else if(g_symbol == "EURUSD" || g_symbol == "EUR/USD")
   {
      g_swap_window_start = StringToTime("21:00");
      g_swap_window_end = StringToTime("21:00");
      PrintFormat("【库存费检测】%s：周日21:00-周一21:00", g_symbol);
   }
   else if(g_symbol == "GBPUSD" || g_symbol == "GBP/USD")
   {
      g_swap_window_start = StringToTime("21:00");
      g_swap_window_end = StringToTime("21:00");
      PrintFormat("【库存费检测】%s：周日21:00-周一21:00", g_symbol);
   }
   else if(StringFind(g_symbol, "BTC") >= 0 || StringFind(g_symbol, "ETH") >= 0)
   {
      g_swap_window_start = 0;
      g_swap_window_end = 0;
      PrintFormat("【库存费检测】%s：加密货币，无库存费", g_symbol);
   }
   else if(g_symbol == "NZDUSD" || g_symbol == "NZD/USD")
   {
      g_swap_window_start = StringToTime("21:00");
      g_swap_window_end = StringToTime("21:00");
      PrintFormat("【库存费检测】%s：周日21:00-周一21:00", g_symbol);
   }
   else if(g_symbol == "AUDUSD" || g_symbol == "AUD/USD")
   {
      g_swap_window_start = StringToTime("22:00");
      g_swap_window_end = StringToTime("00:00");
      PrintFormat("【库存费检测】%s：周一22:00-周二00:00", g_symbol);
   }
   else if(g_symbol == "USDCAD" || g_symbol == "USD/CAD")
   {
      g_swap_window_start = StringToTime("20:00");
      g_swap_window_end = StringToTime("20:00");
      PrintFormat("【库存费检测】%s：周日20:00-周一20:00", g_symbol);
   }
   else if(g_symbol == "USDRUB" || g_symbol == "USD/RUB")
   {
      g_swap_window_start = StringToTime("22:00");
      g_swap_window_end = StringToTime("00:00");
      PrintFormat("【库存费检测】%s：周一22:00-周二00:00", g_symbol);
   }
   else if(g_symbol == "USDCHF" || g_symbol == "USD/CHF")
   {
      g_swap_window_start = StringToTime("20:00");
      g_swap_window_end = StringToTime("20:00");
      PrintFormat("【库存费检测】%s：周日20:00-周一20:00", g_symbol);
   }
   else
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 21; dt.min = 0; dt.sec = 0;
      g_swap_window_start = StructToTime(dt);
      dt.hour = 22;
      g_swap_window_end = StructToTime(dt);
      PrintFormat("【库存费检测】%s：未在列表中，使用默认窗口（周一21:00-22:00）", g_symbol);
   }
}
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(LotShort <=0 || LotLong <=0 || LotLongReverse <=0 || LotShortReverse <=0)
   {
      Print("【参数错误】所有手数必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(SL_USD <=0 || TP_USD <=0)
   {
      Print("【参数错误】SL_USD、TP_USD必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   if(!InitializeSymbolInfo())
      return INIT_PARAMETERS_INCORRECT;
   if(!EventSetTimer(1))
   {
      Print("定时器创建失败！错误码：", GetLastError());
      return INIT_PARAMETERS_INCORRECT;
   }
   g_nextTriggerTime = CalculateNextTriggerTime(TimeTradeServer());
   g_swap_check_time = 0;
   g_currentDirection = InitialDirection;
   g_highest_equity = AccountInfoDouble(ACCOUNT_EQUITY);

   PrintFormat("EA启动【通用全品种｜周末不跳过】，商品: %s | 目标净值: %.2f | 库存费前清理: %d 分钟",
               _Symbol, TargetNetProfit, SwapAvoidBeforeMin);
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
         if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL),g_symbol) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            return PositionGetInteger(POSITION_IDENTIFIER);
         }
      }
   }
   return INVALID_POSITION_ID;
}
//+------------------------------------------------------------------+
//| 工具函数：计算下一个5分钟触发点，【不跳过周末】                      |
//+------------------------------------------------------------------+
datetime CalculateNextTriggerTime(datetime fromTime)
{
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   int baseMin = dt.min - dt.min % 5;
   int nextMinTotal = baseMin + 5;
   MqlDateTime nextDt = dt;
   nextDt.min = nextMinTotal;
   nextDt.sec = 0;
   NormalizeDateTime(nextDt);
   datetime candidate = StructToTime(nextDt);
   while(candidate <= fromTime)
   {
      candidate += 5*60;
      TimeToStruct(candidate,dt);
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
         if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), g_symbol) && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
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
         if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL), g_symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
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
   long filling = SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((filling & ORDER_FILLING_FOK) != 0)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & ORDER_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                        trade.SetTypeFilling(ORDER_FILLING_RETURN);
}
//+------------------------------------------------------------------+
//| 重置全部监控状态变量                                               |
//+------------------------------------------------------------------+
void ResetMonitorStates()
{
   g_monitor_position_id = INVALID_POSITION_ID;
   g_reverse_order_ticket = INVALID_ORDER_TICKET;
   g_pending_cancel_time = 0;
}
//+------------------------------------------------------------------+
//| 回撤止损：停止EA并清仓清单                                         |
//+------------------------------------------------------------------+
void StopEAAndClean()
{
   double currEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   double drawPct= ((g_highest_equity - currEquity)/g_highest_equity)*100.0;
   PrintFormat("【回撤保护】回撤率 %.2f%% 已达到阈值 %.2f%%，终止EA并清理仓位！",drawPct, MaxDrawdownPct);
   int closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0 && PositionSelectByTicket(posTicket))
      {
         if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL),g_symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            trade.PositionClose(posTicket);
            closedCount++;
         }
      }
   }
   int deletedCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0 && OrderSelect(orderTicket))
      {
         if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL),g_symbol) && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            trade.OrderDelete(orderTicket);
            deletedCount++;
         }
      }
   }
   ResetMonitorStates();
   PrintFormat("【回撤保护】已平仓 %d 个仓位，已撤销 %d 个委托。EA已停止运行。", closedCount, deletedCount);
}
//+------------------------------------------------------------------+
//| 计算并检查最大回撤                                                   |
//+------------------------------------------------------------------+
void CalculateMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_highest_equity < currentEquity)
   {
      g_highest_equity = currentEquity;
   }
   double drawdownPct = 0.0;
   if(g_highest_equity > 0.0)
   {
      drawdownPct = ((g_highest_equity - currentEquity) / g_highest_equity) * 100.0;
   }
   g_max_drawdown = g_highest_equity - currentEquity;
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
   CalculateMaxDrawdown();
   if(g_stop_on_drawdown) return;
   if(AccountInfoDouble(ACCOUNT_EQUITY) >= TargetNetProfit)
   {
      PrintFormat("【目标净值达成】正在全面清仓与撤单... 商品: %s", g_symbol);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
         {
            if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL),g_symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
               trade.PositionClose(posTicket);
         }
      }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong orderTicket = OrderGetTicket(i);
         if(orderTicket > 0 && OrderSelect(orderTicket))
         {
            if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL),g_symbol) && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
               trade.OrderDelete(orderTicket);
         }
      }
      ResetMonitorStates();
      g_target_reached = true;
   }
}
//+------------------------------------------------------------------+
//| 安全撤销关联的反向挂单                                           |
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
//| 下单逻辑：做空                                                   |
//+------------------------------------------------------------------+
void ExecuteShortOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
   {
      PrintFormat("【错误】获取 %s Tick失败，错误码: %d", g_symbol, GetLastError());
      return;
   }
   int digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   const double bid = tick.bid;
   double dist_sl = CalcPriceDistanceByUSD(SL_USD,LotShort);
   double dist_tp = CalcPriceDistanceByUSD(TP_USD,LotShort);
   if(dist_sl <=0 || dist_tp <=0)
   {
      Print("【价格换算错误】SL/TP美元转价格距离失败，跳过开仓");
      return;
   }
   const double sl_price = NormalizeDouble(bid + dist_sl, digits);
   const double tp_price = NormalizeDouble(bid - dist_tp, digits);

   PrintFormat("【诊断】品种: %s | Bid: %.5f | SL:%.5f TP:%.5f | SL距离:%.5f TP距离:%.5f",
               g_symbol,bid,sl_price,tp_price,dist_sl,dist_tp);

   if(trade.Sell(LotShort, g_symbol, bid, sl_price, tp_price, "Init Short"))
   {
      ulong deal_ticket = trade.ResultDeal();
      g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                              HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();

      double rev_dist_sl = dist_sl;   //复用首单SL美元换算出的价格距离
double rev_dist_tp = dist_tp;   //复用首单TP美元换算出的价格距离

double rev_entry=sl_price;
double rev_sl = NormalizeDouble(rev_entry - rev_dist_sl,digits);
double rev_tp = NormalizeDouble(rev_entry + rev_dist_tp,digits);

bool okReverse=false;
      if(rev_entry > tick.ask) // BuyStop 触发价必须>当前Ask
{
   if(trade.BuyStop(LotLongReverse, rev_entry, g_symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse BuyStop"))
   {
      g_reverse_order_ticket = trade.ResultOrder();
      okReverse=true;
   }
}
if(!okReverse)
{
   PrintFormat("【警告】反向BuyStop挂单校验失败，价格%.5f，市场Ask %.5f，错误码%d",rev_entry,tick.ask,trade.ResultRetcode());
   g_reverse_order_ticket=INVALID_ORDER_TICKET;
}
PrintFormat("【初始做空成功】持仓ID: %I64u, 反向挂单Ticket: %I64u | 反向SL距离:%.5f TP距离:%.5f", g_monitor_position_id, g_reverse_order_ticket,rev_dist_sl,rev_dist_tp);
   }
   else
   {
      PrintFormat("【初始做空失败】价格: %.5f  SL: %.5f  TP: %.5f  错误码: %d (%s)",
                  bid, sl_price, tp_price,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
//| 下单逻辑：做多                                                   |
//+------------------------------------------------------------------+
void ExecuteLongOrder()
{
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
   {
      PrintFormat("【错误】获取 %s Tick失败，错误码: %d", g_symbol, GetLastError());
      return;
   }
   int digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   const double ask = tick.ask;
   double dist_sl = CalcPriceDistanceByUSD(SL_USD,LotLong);
   double dist_tp = CalcPriceDistanceByUSD(TP_USD,LotLong);
   if(dist_sl <=0 || dist_tp <=0)
   {
      Print("【价格换算错误】SL/TP美元转价格距离失败，跳过开仓");
      return;
   }
   const double sl_price = NormalizeDouble(ask - dist_sl, digits);
   const double tp_price = NormalizeDouble(ask + dist_tp, digits);

   PrintFormat("【诊断】品种: %s | Ask: %.5f | SL:%.5f TP:%.5f | SL距离:%.5f TP距离:%.5f",
               g_symbol,ask,sl_price,tp_price,dist_sl,dist_tp);

   if(trade.Buy(LotLong, g_symbol, ask, sl_price, tp_price, "Init Long"))
   {
      ulong deal_ticket = trade.ResultDeal();
      g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                              HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID();

      double rev_dist_sl = dist_sl;
double rev_dist_tp = dist_tp;

double rev_entry=sl_price;
double rev_sl = NormalizeDouble(rev_entry + rev_dist_sl,digits);
double rev_tp = NormalizeDouble(rev_entry - rev_dist_tp,digits);

bool okReverse=false;
      if(rev_entry < tick.bid) // SellStop触发价必须 < 当前Bid
{
   if(trade.SellStop(LotShortReverse, rev_entry, g_symbol, rev_sl, rev_tp, ORDER_TIME_GTC, 0, "Reverse SellStop"))
   {
      g_reverse_order_ticket = trade.ResultOrder();
      okReverse=true;
   }
}
if(!okReverse)
{
   PrintFormat("【警告】反向SellStop挂单校验失败，价格%.5f，市场Bid %.5f，错误码%d",rev_entry,tick.bid,trade.ResultRetcode());
   g_reverse_order_ticket=INVALID_ORDER_TICKET;
}
PrintFormat("【初始做多成功】持仓ID: %I64u, 反向挂单Ticket: %I64u | 反向SL距离:%.5f TP距离:%.5f", g_monitor_position_id, g_reverse_order_ticket,rev_dist_sl,rev_dist_tp);
   }
   else
   {
      PrintFormat("【初始做多失败】价格: %.5f  SL: %.5f  TP: %.5f  错误码: %d (%s)",
                  ask, sl_price, tp_price,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
void MonitorPositionStatus()
{
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
         if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL),g_symbol) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_IDENTIFIER) == g_monitor_position_id)
         {
            isStillOpen = true;
            break;
         }
      }
   }
   if(isStillOpen) return;

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
               if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL),g_symbol) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
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
      PrintFormat("【监控通知】初始持仓止损离场，反向翻仓单已激活！新持仓ID: %I64u", newPositionID);
      g_monitor_position_id = newPositionID;
      if(ReverseDirectionAfterSL)
      {
         g_currentDirection = (g_currentDirection == DIR_SHORT) ? DIR_LONG : DIR_SHORT;
         PrintFormat("【方向更新】已反转方向为: %s", (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
      }
      g_reverse_order_ticket = INVALID_ORDER_TICKET;
   }
   else
   {
      PrintFormat("【监控通知】初始持仓(ID:%I64u)已正常止盈离场！进入 %d 秒并发保护观察期...",
                  g_monitor_position_id, CancelDelaySec);
      g_pending_cancel_time = TimeTradeServer() + CancelDelaySec;
      g_monitor_position_id = INVALID_POSITION_ID;
   }
}
//+------------------------------------------------------------------+
//| 判断当前是否在库存费规避时间段                                     |
//+------------------------------------------------------------------+
bool IsInSwapAvoidWindow(datetime checkTime)
{
   if(g_swap_window_start == 0 || g_swap_window_end == 0)
      return false;
   MqlDateTime dt;
   TimeToStruct(checkTime, dt);
   int checkHour = dt.hour;
   int checkMin = dt.min;
   MqlDateTime startDt, endDt;
   TimeToStruct(g_swap_window_start, startDt);
   TimeToStruct(g_swap_window_end, endDt);
   int startHour = startDt.hour;
   int startMin = startDt.min;
   int endHour = endDt.hour;
   int endMin = endDt.min;

   if(startHour < endHour)
   {
      int checkMinutes = checkHour * 60 + checkMin;
      int startMinutes = startHour * 60 + startMin;
      int endMinutes = endHour * 60 + endMin;
      return (checkMinutes >= startMinutes && checkMinutes < endMinutes);
   }
   else
   {
      int checkMinutes = checkHour * 60 + checkMin;
      int startMinutes = startHour * 60 + startMin;
      int endMinutes = endHour * 60 + endMin;
      return (checkMinutes >= startMinutes || checkMinutes < endMinutes);
   }
}
//+------------------------------------------------------------------+
//| 计算下一个库存费扣除时间点                                          |
//+------------------------------------------------------------------+
datetime CalculateNextSwapTime(datetime fromTime)
{
   if(g_swap_window_start == 0 || g_swap_window_end == 0)
      return fromTime + 86400;
   MqlDateTime dt;
   TimeToStruct(fromTime, dt);
   MqlDateTime startDt, endDt;
   TimeToStruct(g_swap_window_start, startDt);
   TimeToStruct(g_swap_window_end, endDt);
   int startHour = startDt.hour;
   int startMin = startDt.min;
   int endHour = endDt.hour;
   int endMin = endDt.min;
   int currentHour = dt.hour;
   int currentMin = dt.min;

   if(startHour < endHour)
   {
      int currentMinutes = currentHour * 60 + currentMin;
      int startMinutes = startHour * 60 + startMin;
      int endMinutes = endHour * 60 + endMin;
      if(currentMinutes >= endMinutes)
      {
         startDt.day++;
         return StructToTime(startDt);
      }
      else if(currentMinutes >= startMinutes)
      {
         startDt.day++;
         return StructToTime(startDt);
      }
      else
      {
         return g_swap_window_start;
      }
   }
   else
   {
      int currentMinutes = currentHour * 60 + currentMin;
      int startMinutes = startHour * 60 + startMin;
      int endMinutes = endHour * 60 + endMin;
      if(currentMinutes >= endMinutes)
      {
         startDt.day++;
         return StructToTime(startDt);
      }
      else if(currentMinutes >= startMinutes)
      {
         startDt.day++;
         return StructToTime(startDt);
      }
      else
      {
         return g_swap_window_start;
      }
   }
}
//+------------------------------------------------------------------+
//| 检查并清理盈利仓位（库存费前清理）                                   |
//+------------------------------------------------------------------+
void CheckAndCleanProfitablePositions()
{
   datetime swapCheckTime = CalculateNextSwapTime(TimeTradeServer());
   long minutesUntilSwap = (swapCheckTime - TimeTradeServer()) / 60;
   if(minutesUntilSwap < SwapAvoidBeforeMin)
   {
      bool hasProfitablePosition = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket == 0) continue;
         if(PositionSelectByTicket(posTicket))
         {
            if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL), g_symbol) &&
               PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            {
               double profit = PositionGetDouble(POSITION_PROFIT);
               if(profit > 5.0)
               {
                  hasProfitablePosition = true;
                  PrintFormat("【库存费清理】检测到盈利仓位 Ticket:%I64u, 盈利: %.2f USD，将提前平仓", posTicket, profit);
                  break;
               }
            }
         }
      }
      if(hasProfitablePosition)
      {
         PrintFormat("【库存费清理】开始清理盈利仓位和未成交委托，距离库存费扣除还有 %d 分钟", (int)minutesUntilSwap);
         int closedCount = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket == 0) continue;
            if(PositionSelectByTicket(posTicket))
            {
               if(IsSameBaseSymbol(PositionGetString(POSITION_SYMBOL), g_symbol) &&
                  PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
               {
                  if(trade.PositionClose(posTicket))
                  {
                     closedCount++;
                     PrintFormat("  已平仓 Ticket:%I64u", posTicket);
                  }
               }
            }
         }
         int deletedCount = 0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            ulong orderTicket = OrderGetTicket(i);
            if(orderTicket == 0) continue;
            if(OrderSelect(orderTicket))
            {
               if(IsSameBaseSymbol(OrderGetString(ORDER_SYMBOL), g_symbol) &&
                  OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
               {
                  if(trade.OrderDelete(orderTicket))
                  {
                     deletedCount++;
                     PrintFormat("  已撤销挂单 Ticket:%I64u", orderTicket);
                  }
               }
            }
         }
         PrintFormat("【库存费清理】完成！已平仓 %d 个仓位，已撤销 %d 个委托 | 商品: %s",
                     closedCount, deletedCount, _Symbol);
         g_swap_check_time = TimeTradeServer() + 60;
         ResetMonitorStates();
      }
      else
      {
         g_swap_check_time = swapCheckTime;
      }
   }
   else
   {
      g_swap_check_time = swapCheckTime;
   }
}
//+------------------------------------------------------------------+
//| 定时器主逻辑                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   const datetime serverNow = TimeTradeServer();
   if(g_stop_on_drawdown)
   {
      PrintFormat("【跳过】回撤保护已触发");
      return;
   }
   if(g_target_reached)
   {
      PrintFormat("【跳过】目标净值已达成，终止交易");
      return;
   }
   if(g_swap_check_time == 0)
   {
      g_swap_check_time = CalculateNextSwapTime(serverNow);
      PrintFormat("【库存费初始化】首次计算扣费时间：%s",TimeToString(g_swap_check_time,TIME_DATE|TIME_MINUTES));
   }
   if(serverNow >= g_swap_check_time)
   {
      PrintFormat("【执行】清理库存费前的盈利仓位");
      CheckAndCleanProfitablePositions();
   }
   CheckAndCloseAllPositions();
   if(g_target_reached)
   {
      PrintFormat("【跳过】目标净值已达成（在CheckAndCloseAllPositions后）");
      return;
   }
   MonitorPositionStatus();

   datetime swapExecutionTime = CalculateNextSwapTime(serverNow);
   long minutesUntilSwap = (swapExecutionTime - serverNow) / 60;
   if(minutesUntilSwap < SwapAvoidBeforeMin)
   {
      PrintFormat("【库存费避让】距离扣库存费还有 %d 分钟，避让期内不新开仓。扣费时间: %s | 商品: %s",
                  (int)minutesUntilSwap,
                  TimeToString(swapExecutionTime, TIME_DATE|TIME_MINUTES),
                  _Symbol);
      return;
   }
   if(serverNow < g_nextTriggerTime)
   {
      return;
   }
   if( (serverNow - g_nextTriggerTime) > (5*60 -10) )
   {
      PrintFormat("【触发迟到过久】本次触发已过期，跳过，重新计算下一次");
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
   }
   datetime nextAfterThis = CalculateNextTriggerTime(serverNow);
   PrintFormat("【时间检查】上次交易: %s | 距离上次交易: %d 秒 | 下次触发: %s",
               TimeToString(g_lastTradeTime, TIME_DATE|TIME_SECONDS),
               (int)(serverNow - g_lastTradeTime),
               TimeToString(nextAfterThis, TIME_DATE|TIME_MINUTES));
   if(serverNow - g_lastTradeTime < RepeatGuardMin * 60)
   {
      PrintFormat("【防重复】距离上次交易仅 %d 分钟，跳过本次执行。", (int)(serverNow - g_lastTradeTime) / 60);
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   bool hasOrder = CheckHasAnyPendingOrder();
   bool hasPos = CheckHasAnyPosition();
   PrintFormat("【跳过检查】时间: %s | 商品: %s | 有挂单: %s | 有持仓: %s | 下次触发: %s",
               TimeToString(serverNow, TIME_DATE|TIME_MINUTES),
               g_symbol,
               hasOrder ? "是" : "否",
               hasPos ? "是" : "否",
               TimeToString(nextAfterThis, TIME_DATE|TIME_MINUTES));
   if(hasOrder || hasPos)
   {
      g_nextTriggerTime = nextAfterThis;
      return;
   }
   PrintFormat("【开始执行开仓】时间: %s | 商品: %s | 当前方向: %s | 初始方向: %s",
               TimeToString(serverNow, TIME_DATE|TIME_MINUTES),
               g_symbol,
               (g_currentDirection == DIR_SHORT) ? "做空" : "做多",
               (InitialDirection == DIR_SHORT) ? "做空" : "做多");

   if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
   else                                 ExecuteLongOrder();

   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
   PrintFormat("【开仓完成】时间: %s | 上次交易: %s | 下次触发: %s",
               TimeToString(serverNow, TIME_DATE|TIME_MINUTES),
               TimeToString(g_lastTradeTime, TIME_DATE|TIME_MINUTES),
               TimeToString(g_nextTriggerTime, TIME_DATE|TIME_MINUTES));
}
