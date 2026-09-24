//+------------------------------------------------------------------+
//|                                                    逆势收紧移动止盈&止损&顺势放大止盈&顺势加仓策略.mq5 |
//|                                                             hery | feat:自定义交易时间
//     3.3.4自定义交易时间
//     3.3.5逆势收紧移动止盈开关
//     3.3.6只要浮盈大于等于4尽早锁定利润
//     3.3.7顺势放大止盈调整移动锁利模式&初始下单方向优先面板选择的下单，其次高周期趋势决定方向
//。   3.3.8修复高周期趋势决定开仓方向不准确问题
//。   3.3.9加仓单独立管理，包含逆势收紧止盈，移动止损，早期锁利，保本损，顺势放大移动止盈&修复若干问题
//。   3.3.10修复顺势放大止盈会立即平仓
//。   3.3.11第一次开仓方向取反向调试看效果
//。   3.3.12修复早期锁利/顺势止盈/加仓跳过日志过于频繁：改为最多每1分钟打印一次
//。   3.3.13锁利触发平仓若实际盈亏>7按盈利平仓处理：初始单不挂反向，反向单下次开仓反转方向
//。   5.3.14初始单止损平仓净亏≤配置阈值(默认-18)时不再立即反向翻仓（仅初始单）
//。   5.3.15初始单止损后延迟1分钟再按价格条件决定是否反向翻仓：多单要求最新价<平仓价，空单要求最新价>平仓价
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "5.3.15"
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
   DIR_LONG  = 1,  // 初始做多
   DIR_AUTO  = 2   // 未指定方向，按高周期趋势决定
};
//===== 外部参数 =====
input ulong   InpMagicNumber     = 888151;  // EA魔术码(用于区分订单)
input ENUM_INIT_DIRECTION InitialDirection = DIR_AUTO; // 首次开仓方向：明确选择多/空时优先，否则按高周期趋势

// ★★★ 自定义交易时间段（高流动性时段）★★★
input bool   EnableCustomTradingHours = false;   // 是否启用自定义交易时间段
input int    TradingStartHour         = 20;     // 开始小时 (0-23)
input int    TradingStartMinute       = 0;      // 开始分钟 (0-59)
input int    TradingEndHour           = 2;      // 结束小时 (0-23)
input int    TradingEndMinute         = 0;      // 结束分钟 (0-59)
// 说明：支持跨日，例如 20:00 → 02:00 表示每天晚上20点到次日凌晨2点

// ★★★ 高周期趋势参数（决定第一次开仓方向）★★★
input ENUM_TIMEFRAMES HigherTF       = PERIOD_H4;   // 高周期时间框
input int             TrendMAPeriod  = 50;          // 趋势MA周期
input ENUM_MA_METHOD  TrendMAMethod  = MODE_EMA;    // 趋势MA方法
input ENUM_APPLIED_PRICE TrendPrice  = PRICE_CLOSE; // 应用价格
// ★新增：趋势过滤参数
input int    TrendConfirmBars   = 2;     // 连续确认K线根数（建议2~4）
input double TrendMinSlopePts   = 50.0;  // MA最小斜率（点数，过滤横盘，可按品种调整，30~50（根据品种点值调整，黄金可适当加大）
input double LotShort           = 0.01;     // 初始做空手数
input double LotLong            = 0.01;     // 初始做多手数
input double LotLongReverse     = 0.01;     // 做空止损反向多单手数
input double LotShortReverse    = 0.01;     // 做多止损反向空手数
input double LotScaleIn         = 0.01;     // ★新增：锁定利润时加仓手数，0跳过加仓
input bool   EnableScaleIn      = true;     // ★新增：是否启用锁定利润时加仓
input double MinBalanceForScaleIn = 200;    // ★新增：账户余额达到此值才允许顺势加仓（0=不限制）
input bool   EnableTPTighten     = true;     // ★新增：是否启用移动止盈收紧（逆势收紧）
input double TP_USD             = 22;       // 初始单移动止盈距离（逆势收紧）
input double SL_USD             = 22;       // 初始单移动止损距离
input double REV_SL_USD         = 22;       // 反向单移动止损距离
input double REV_TP_USD         = 22;       // 反向单移动止盈距离（逆势收紧）
input double SkipReverseLossThreshold = 0; // 初始单止损平仓净亏≤此值时不再立即反向翻仓（仅初始单，0=关闭此过滤）
input double BreakEvenProfit   =  0;    // 浮盈达到此值时设置保本损（价格单位，0=关闭）
input double BreakEvenOffset   = 10;     // 保本损相对开仓价的偏移量（多单+，空单-）
input double EarlyLockProfit   = 13;   // ★新增：早期锁利触发浮盈（价格单位，≥此值开始锁利,0=关闭）
input double EarlyLockOffset   = 7;   // ★新增：早期锁利偏移量（止损 = 当前价 ± 此值）
input int    IntervalMinutes    = 5;        // 开仓间隔(分钟)
input int    RepeatGuardMin     = 2;        // 防重复间隔(分钟)
input int    CancelDelaySec     = 5;        // 延迟撤单秒数（已基本不用，保留兼容）
input double TargetNetProfit    = 500;  // 目标净值(达到后全部平仓并停止)
input double MaxDrawdownPct     = 50.0;     // 最大回撤率(%)，达到后终止EA并清仓
input bool   ReverseDirectionAfterSL = true; // 初始单止损 + 反向单止盈后，是否反转方向
input bool   UseTrendFilterOnReverse = true; // 反转方向时启用高周期趋势过滤（仅当拟反转方向与趋势一致时才真正反转）
//===== 隔夜库存费规避参数 =====
input bool   AvoidSwapWednesdayOnly = false; // 是否仅在周三深夜规避库存费
input int    AvoidSwapBeforeMin     = 10;    // 距离扣除库存费前多少分钟开始扫描
input int    AvoidSwapAfterMin      = 10;    // 扣除库存费后恢复时间(分钟)
input bool   EnableWeekendTrading   = false; // 是否开启周末定时开仓
//===== 顺势移动止盈放大=====
input double TrailProfitTrigger = 20;    // 放大止盈触发浮盈阀值USD，达到后锁定利润
input double TrailProfitOffset  = 5.0;  // 达到触发阀值后，止盈与最新价的固定偏移量
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
// ★★★ 5.3.15：初始单止损后延迟1分钟按价格条件再决定是否反向翻仓 ★★★
datetime g_pending_sl_reverse_time = 0;   // >0 表示等待中，到期后检查价格条件
double   g_sl_close_price = 0.0;          // 初始单止损平仓价
bool     g_sl_was_buy = false;            // 初始单是否为多单（true=多，false=空）
//===== 虚拟止损/止盈（本地记录）=====
double   g_virtual_sl_price = 0.0;
double   g_virtual_tp_price = 0.0;
bool     g_last_close_was_tp = false;
// ★★★ 库存费前盈利平仓后，过了窗口按原方向重新开仓 ★★★
bool                 g_need_reopen_after_swap = false;
ENUM_INIT_DIRECTION  g_reopen_direction       = DIR_SHORT;
bool   g_scaled_in = false;                  // ★新增：是否已在本轮锁定时加仓
bool   g_trail_tp_triggered = false;         // 是否已首次达到放大止盈触发值
bool   g_scale_in_monitoring_error = false;
ulong  g_scale_in_position_ids[];
bool   g_scale_in_reverse_flags[];
double g_scale_virtual_sl_prices[];
double g_scale_virtual_tp_prices[];
bool   g_scale_trail_tp_triggered_flags[];
// ★★★ 高周期趋势指标句柄 ★★★
int g_trend_ma_handle = INVALID_HANDLE;
//+------------------------------------------------------------------+
//| 根据高周期趋势确定方向（更灵敏版：近期确认 + 斜率 + 当前价过滤）   |
//+------------------------------------------------------------------+
ENUM_INIT_DIRECTION GetHigherTFTrendDirection()
{
   if(g_trend_ma_handle == INVALID_HANDLE)
   {
      Print("【趋势判断】MA句柄无效，趋势计算失败，默认首次做空");
      return DIR_SHORT;
   }
   
   // 多取几根保证数据充足
   int needBars = MathMax(TrendConfirmBars + 8, 15);
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_trend_ma_handle, 0, 0, needBars, ma) < needBars)
   {
      Print("【趋势判断】复制MA缓冲失败，趋势计算失败，默认首次做空");
      return DIR_SHORT;
   }
   
   // 只使用已收盘的高周期K线，避免当前形成中的K线造成方向抖动
   double close1 = iClose(_Symbol, HigherTF, 1);
   if(close1 <= 0.0)
   {
      Print("【趋势判断】获取高周期收盘价失败，趋势计算失败，默认首次做空");
      return DIR_SHORT;
   }

   int confirmBars = MathMax(1, TrendConfirmBars);
   for(int shift = 1; shift <= confirmBars; shift++)
   {
      double confirmedClose = iClose(_Symbol, HigherTF, shift);
      if(confirmedClose <= 0.0)
      {
         PrintFormat("【趋势判断】无法获取第%d根已收盘K线，趋势计算失败，默认首次做空", shift);
         return DIR_SHORT;
      }
   }
   
   // ===== 1. 斜率（更短窗口，更灵敏）=====
   // 用最近 3~4 根MA变化，比原来短很多
   int slopeBars = MathMax(3, confirmBars);
   double maSlope = ma[1] - ma[1 + slopeBars];
   double minSlope = TrendMinSlopePts * _Point;
   
   // ===== 2. 连续确认：所有已收盘确认K线必须位于MA同一侧 =====
   bool recentBullish = true;
   bool recentBearish = true;
   for(int shift = 1; shift <= confirmBars; shift++)
   {
      double confirmedClose = iClose(_Symbol, HigherTF, shift);
      recentBullish = recentBullish && (confirmedClose > ma[shift]);
      recentBearish = recentBearish && (confirmedClose < ma[shift]);
   }
   
   ENUM_INIT_DIRECTION dir;
   
   // 做多条件：连续已收盘K线在MA上方 + 斜率向上超过阈值
   if(recentBullish && maSlope > minSlope)
   {
      dir = DIR_SHORT; // 取反向调试
   }
   // 做空条件：连续已收盘K线在MA下方 + 斜率向下超过阈值
   else if(recentBearish && maSlope < -minSlope)
   {
      dir = DIR_LONG; //取反调试
   }
   else
   {
      // 震荡或不明确 → 按要求默认首次做空
      Print("【趋势判断】高周期震荡或不明确（确认不足或斜率不足），默认首次做空");
      return DIR_SHORT;
   }
   
   PrintFormat("【高周期趋势-灵敏版】TF:%s  MA[1]:%.5f  收盘[1]:%.5f  斜率:%.1f点  确认根数:%d → 方向:%s",
               EnumToString(HigherTF), ma[1], close1,
               maSlope / _Point, confirmBars,
               (dir == DIR_LONG ? "做多" : "做空"));
               
   return dir;
}

//+------------------------------------------------------------------+
//| 判断当前服务器时间是否在自定义交易时间段内（支持跨日）             |
//+------------------------------------------------------------------+
bool IsInCustomTradingHours(datetime serverTime)
{
   if(!EnableCustomTradingHours)
      return true;   // 未启用则全天允许

   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes   = TradingStartHour * 60 + TradingStartMinute;
   int endMinutes     = TradingEndHour   * 60 + TradingEndMinute;

   // 同一天内的时间段（例如 09:00-17:00）
   if(startMinutes <= endMinutes)
   {
      return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
   }
   // 跨日时间段（例如 20:00-02:00）
   else
   {
      return (currentMinutes >= startMinutes || currentMinutes < endMinutes);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   // 创建高周期趋势MA句柄
   g_trend_ma_handle = iMA(_Symbol, HigherTF, TrendMAPeriod, 0, TrendMAMethod, TrendPrice);
   if(g_trend_ma_handle == INVALID_HANDLE)
   {
      Print("【错误】创建高周期MA失败！错误码：", GetLastError());
      return INIT_FAILED;
   }
   if(!EventSetTimer(1))
   {
      Print("定时器创建失败！错误码：", GetLastError());
      return INIT_PARAMETERS_INCORRECT;
   }
   g_nextTriggerTime = CalculateNextTriggerTime(TimeTradeServer());
   // ★★★ 第一次下单：面板明确方向优先，否则按高周期趋势决定 ★★★
   if(InitialDirection == DIR_SHORT || InitialDirection == DIR_LONG)
   {
      g_currentDirection = InitialDirection;
      PrintFormat("【首次开仓方向】使用面板配置方向：%s",
                  (g_currentDirection == DIR_LONG ? "做多" : "做空"));
   }
   else
   {
      g_currentDirection = GetHigherTFTrendDirection();
      PrintFormat("【首次开仓方向】面板未指定方向，使用高周期趋势：%s",
                  (g_currentDirection == DIR_LONG ? "做多" : "做空"));
   }
   if(g_currentDirection == DIR_SHORT)
      PrintFormat("EA启动 v5.3.15【移动止损 + 逆势收紧移动止盈 + 锁定加仓(余额过滤) + 止损后延迟1分钟按价格条件翻仓 + 反转趋势过滤 + 锁利盈利>7按止盈处理 + 重亏≤阈值跳过翻仓】规则：高周期趋势做空 | 间隔:%d分钟 | 目标净值:%.2f",
                  IntervalMinutes, TargetNetProfit);
   else
      PrintFormat("EA启动 v5.3.15【移动止损 + 逆势收紧移动止盈 + 锁定加仓(余额过滤) + 止损后延迟1分钟按价格条件翻仓 + 反转趋势过滤 + 锁利盈利>7按止盈处理 + 重亏≤阈值跳过翻仓】规则：高周期趋势做多 | 间隔:%d分钟 | 目标净值:%.2f",
                  IntervalMinutes, TargetNetProfit);
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_trend_ma_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_trend_ma_handle);
      g_trend_ma_handle = INVALID_HANDLE;
   }
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
ulong GetLatestPositionID(long expectedType = -1)
{
   ulong latestPositionId = INVALID_POSITION_ID;
   long latestPositionTime = -1;
   ulong latestPositionTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0 && PositionSelectByTicket(posTicket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            (expectedType < 0 || PositionGetInteger(POSITION_TYPE) == expectedType))
         {
            long positionTime = PositionGetInteger(POSITION_TIME_MSC);
            if(positionTime > latestPositionTime ||
               (positionTime == latestPositionTime && posTicket > latestPositionTicket))
            {
               latestPositionTime = positionTime;
               latestPositionTicket = posTicket;
               latestPositionId = PositionGetInteger(POSITION_IDENTIFIER);
            }
         }
      }
   }
   return latestPositionId;
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
//| 获取指定持仓最近一次OUT成交的盈亏（含佣金/库存费后的净利）         |
//+------------------------------------------------------------------+
double GetClosedPositionProfit(ulong position_id)
{
   if(position_id == INVALID_POSITION_ID) return 0.0;
   for(int retry = 0; retry < 6; retry++)
   {
      if(!HistorySelectByPosition(position_id))
      {
         if(retry < 5) Sleep(80 + retry * 40);
         continue;
      }
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
         // 返回净盈亏（利润 + 库存费 + 佣金）
         double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
         double swap   = HistoryDealGetDouble(deal, DEAL_SWAP);
         double commission = HistoryDealGetDouble(deal, DEAL_COMMISSION);
         return profit + swap + commission;
      }
      if(retry < 5) Sleep(80 + retry * 40);
   }
   return 0.0;
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
//| 开反向翻仓单（初始单止损且延迟1分钟价格条件满足后调用）             |
//+------------------------------------------------------------------+
void ExecuteReverseOrder()
{
   ResetTrackTPState(); // 重置止盈模式状态
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
      if(trade.Buy(LotLongReverse, _Symbol, ask, 0, 0, ""))
      {
         ulong deal_ticket = trade.ResultDeal();
         g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                                 HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID(POSITION_TYPE_BUY);
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
      if(trade.Sell(LotShortReverse, _Symbol, bid, 0, 0, ""))
      {
         ulong deal_ticket = trade.ResultDeal();
         g_monitor_position_id = (deal_ticket > 0 && HistoryDealSelect(deal_ticket)) ?
                                 HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID(POSITION_TYPE_SELL);
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
//| ★新增：锁定利润时同向加仓（跟随初始单逻辑）                        |
//+------------------------------------------------------------------+
void MarkScaleInMonitoringError()
{
   Print("【加仓监控错误】无法建立可靠的加仓持仓监控，停止后续加仓；现有仓位继续运行");
   g_scale_in_monitoring_error = true;
}

void ExecuteScaleInOrder(long posType)
{
   if(!EnableScaleIn || g_scaled_in || g_scale_in_monitoring_error || LotScaleIn <= 0.0) return;
   
   // ★新增：账户余额必须达到配置值才允许加仓
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(MinBalanceForScaleIn > 0.0 && currentBalance < MinBalanceForScaleIn)
   {
      // 最多每 1 分钟打印一次，避免刷屏
      static datetime s_lastScaleSkipLogTime = 0;
      datetime nowServer = TimeTradeServer();
      if(nowServer - s_lastScaleSkipLogTime >= 60)
      {
         PrintFormat("【加仓跳过】账户余额 %.2f < 配置阈值 %.2f，本次不加仓", currentBalance, MinBalanceForScaleIn);
         s_lastScaleSkipLogTime = nowServer;
      }
      return;
   }
   
   SetTradeFillingMode();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【加仓错误】获取Tick失败，错误码: ", GetLastError());
      return;
   }
   
   bool success = false;
   ulong positionId = INVALID_POSITION_ID;
   
   if(posType == POSITION_TYPE_BUY)
   {
      // 多单加多
      const double ask = tick.ask;
      if(trade.Buy(LotScaleIn, _Symbol, ask, 0, 0, ""))
      {
         success = true;
         PrintFormat("【锁定加仓-多】成功加仓 %.2f 手，开仓价:%.5f", LotScaleIn, ask);
      }
      else
         PrintFormat("【锁定加仓失败-多】错误码: %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else // SELL
   {
      // 空单加空
      const double bid = tick.bid;
      if(trade.Sell(LotScaleIn, _Symbol, bid, 0, 0, ""))
      {
         success = true;
         PrintFormat("【锁定加仓-空】成功加仓 %.2f 手，开仓价:%.5f", LotScaleIn, bid);
      }
      else
         PrintFormat("【锁定加仓失败-空】错误码: %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   
   if(success)
   {
      g_scaled_in = true;
      ulong dealTicket = trade.ResultDeal();
      positionId = (dealTicket > 0 && HistoryDealSelect(dealTicket)) ?
                   HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) : INVALID_POSITION_ID;

      double openPrice = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong positionTicket = PositionGetTicket(i);
         if(positionTicket > 0 && PositionSelectByTicket(positionTicket) &&
            PositionGetInteger(POSITION_IDENTIFIER) == (long)positionId)
         {
            openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            break;
         }
      }
      if(openPrice <= 0.0)
      {
         if(positionId != INVALID_POSITION_ID)
         {
            ulong unmanagedTicket = 0;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket > 0 && PositionSelectByTicket(ticket) &&
                  PositionGetString(POSITION_SYMBOL) == _Symbol &&
                  PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                  PositionGetInteger(POSITION_TYPE) == posType &&
                  PositionGetInteger(POSITION_IDENTIFIER) == (long)positionId)
               {
                  unmanagedTicket = ticket;
                  break;
               }
            }

            if(unmanagedTicket > 0 && trade.PositionClose(unmanagedTicket))
            {
               PrintFormat("【加仓保护】无法获取开仓价，已平仓异常加仓 Ticket:%I64u", unmanagedTicket);
               g_scaled_in = false;
               return;
            }
         }

         PrintFormat("【加仓保护失败】无法建立独立监控，持仓ID:%I64u", positionId);
         g_scaled_in = true;
         MarkScaleInMonitoringError();
         return;
      }

      bool isReverseScaleIn = g_monitoring_reverse_position;
      double scaleSL = isReverseScaleIn ? REV_SL_USD : SL_USD;
      double scaleTP = isReverseScaleIn ? REV_TP_USD : TP_USD;
      double scaleVirtualSL = NormalizeDouble(
         openPrice + (posType == POSITION_TYPE_BUY ? -scaleSL : scaleSL), _Digits);
      double scaleVirtualTP = NormalizeDouble(
         openPrice + (posType == POSITION_TYPE_BUY ? scaleTP : -scaleTP), _Digits);
      TrackScaleInPosition(positionId, isReverseScaleIn, scaleVirtualSL, scaleVirtualTP);
      PrintFormat("【锁定加仓完成】持仓ID:%I64u，已启用独立移动止损、逆势收紧止盈、保本损和顺势移动止盈",
                  positionId);
   }
}
//+------------------------------------------------------------------+
//| 下单逻辑（初始单）——不再挂反向单                                   |
//+------------------------------------------------------------------+
void ExecuteShortOrder()
{
   ResetTrackTPState(); // 重置止盈模式状态
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
                  HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID(POSITION_TYPE_SELL);
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
   ResetTrackTPState(); // 重置止盈模式状态
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
                  HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) : GetLatestPositionID(POSITION_TYPE_BUY);
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
bool IsTrackedScaleInPosition(ulong positionId)
{
   for(int i = 0; i < ArraySize(g_scale_in_position_ids); i++)
   {
      if(g_scale_in_position_ids[i] == positionId)
         return true;
   }
   return false;
}

void TrackScaleInPosition(ulong positionId, bool isReverse, double virtualSL, double virtualTP)
{
   if(positionId == INVALID_POSITION_ID || IsTrackedScaleInPosition(positionId))
      return;

   int count = ArraySize(g_scale_in_position_ids);
   ArrayResize(g_scale_in_position_ids, count + 1);
   ArrayResize(g_scale_in_reverse_flags, count + 1);
   ArrayResize(g_scale_virtual_sl_prices, count + 1);
   ArrayResize(g_scale_virtual_tp_prices, count + 1);
   ArrayResize(g_scale_trail_tp_triggered_flags, count + 1);
   g_scale_in_position_ids[count] = positionId;
   g_scale_in_reverse_flags[count] = isReverse;
   g_scale_virtual_sl_prices[count] = virtualSL;
   g_scale_virtual_tp_prices[count] = virtualTP;
   g_scale_trail_tp_triggered_flags[count] = false;
}

void UntrackScaleInPositionAt(int index)
{
   int lastIndex = ArraySize(g_scale_in_position_ids) - 1;
   if(index < 0 || index > lastIndex)
      return;
   if(index != lastIndex)
   {
      g_scale_in_position_ids[index] = g_scale_in_position_ids[lastIndex];
      g_scale_in_reverse_flags[index] = g_scale_in_reverse_flags[lastIndex];
      g_scale_virtual_sl_prices[index] = g_scale_virtual_sl_prices[lastIndex];
      g_scale_virtual_tp_prices[index] = g_scale_virtual_tp_prices[lastIndex];
      g_scale_trail_tp_triggered_flags[index] = g_scale_trail_tp_triggered_flags[lastIndex];
   }
   ArrayResize(g_scale_in_position_ids, lastIndex);
   ArrayResize(g_scale_in_reverse_flags, lastIndex);
   ArrayResize(g_scale_virtual_sl_prices, lastIndex);
   ArrayResize(g_scale_virtual_tp_prices, lastIndex);
   ArrayResize(g_scale_trail_tp_triggered_flags, lastIndex);
}

bool ManageScaleInPosition()
{
   for(int stateIndex = ArraySize(g_scale_in_position_ids) - 1; stateIndex >= 0; stateIndex--)
   {
      ulong positionId = g_scale_in_position_ids[stateIndex];
      ulong positionTicket = 0;
      long positionType = -1;
      double openPrice = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket) &&
            PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_IDENTIFIER) == (long)positionId)
         {
            positionTicket = ticket;
            positionType = PositionGetInteger(POSITION_TYPE);
            openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            break;
         }
      }

      if(positionTicket == 0)
      {
         UntrackScaleInPositionAt(stateIndex);
         continue;
      }

      double currentPrice = (positionType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double priceProfit = (positionType == POSITION_TYPE_BUY) ?
                        currentPrice - openPrice : openPrice - currentPrice;
      double trailSL = g_scale_in_reverse_flags[stateIndex] ? REV_SL_USD : SL_USD;
      double trailTP = g_scale_in_reverse_flags[stateIndex] ? REV_TP_USD : TP_USD;
      bool trailTPWasTriggered = g_scale_trail_tp_triggered_flags[stateIndex];
      bool hitTP = false;

      if(EarlyLockProfit > 0.0 && priceProfit >= EarlyLockProfit &&
      priceProfit < TrailProfitTrigger)
   {
      if(positionType == POSITION_TYPE_BUY)
      {
         double earlySL = NormalizeDouble(currentPrice - EarlyLockOffset, _Digits);
         double minEarlySL = NormalizeDouble(openPrice + 1.0, _Digits);
         if(earlySL < minEarlySL) earlySL = minEarlySL;
         if(earlySL > g_scale_virtual_sl_prices[stateIndex])
            g_scale_virtual_sl_prices[stateIndex] = earlySL;
      }
      else
      {
         double earlySL = NormalizeDouble(currentPrice + EarlyLockOffset, _Digits);
         double maxEarlySL = NormalizeDouble(openPrice - 1.0, _Digits);
         if(earlySL > maxEarlySL) earlySL = maxEarlySL;
         if(earlySL < g_scale_virtual_sl_prices[stateIndex] || g_scale_virtual_sl_prices[stateIndex] <= 0.0)
            g_scale_virtual_sl_prices[stateIndex] = earlySL;
      }
   }

      if(BreakEvenProfit > 0.0)
   {
      if(positionType == POSITION_TYPE_BUY)
      {
         double bePrice = NormalizeDouble(openPrice + BreakEvenOffset, _Digits);
         if(priceProfit >= BreakEvenProfit && bePrice < currentPrice &&
            g_scale_virtual_sl_prices[stateIndex] < bePrice)
            g_scale_virtual_sl_prices[stateIndex] = bePrice;
      }
      else
      {
         double bePrice = NormalizeDouble(openPrice - BreakEvenOffset, _Digits);
         if(priceProfit >= BreakEvenProfit && bePrice > currentPrice &&
            (g_scale_virtual_sl_prices[stateIndex] > bePrice || g_scale_virtual_sl_prices[stateIndex] <= 0.0))
            g_scale_virtual_sl_prices[stateIndex] = bePrice;
      }
   }

      if(priceProfit < TrailProfitTrigger && !trailTPWasTriggered)
   {
      if(positionType == POSITION_TYPE_BUY)
      {
         if(EnableTPTighten)
         {
            double candidateTP = NormalizeDouble(currentPrice + trailTP, _Digits);
            double minAllowedTP = NormalizeDouble(openPrice + 5.0, _Digits);
            if(candidateTP < g_scale_virtual_tp_prices[stateIndex])
            {
               double limitedTP = MathMax(candidateTP, minAllowedTP);
               if(limitedTP < g_scale_virtual_tp_prices[stateIndex])
                  g_scale_virtual_tp_prices[stateIndex] = limitedTP;
            }
         }
      }
      else if(EnableTPTighten)
      {
         double candidateTP = NormalizeDouble(currentPrice - trailTP, _Digits);
         double maxAllowedTP = NormalizeDouble(openPrice - 5.0, _Digits);
         if(candidateTP > g_scale_virtual_tp_prices[stateIndex])
         {
            double limitedTP = MathMin(candidateTP, maxAllowedTP);
            if(limitedTP > g_scale_virtual_tp_prices[stateIndex])
               g_scale_virtual_tp_prices[stateIndex] = limitedTP;
         }
      }
   }
      else
   {
      // 已经进入顺势追踪后，先检查上一轮追踪价，避免用本轮新价立即平仓。
      if(trailTPWasTriggered)
      {
         hitTP = (positionType == POSITION_TYPE_BUY) ?
                 (currentPrice <= g_scale_virtual_tp_prices[stateIndex]) :
                 (currentPrice >= g_scale_virtual_tp_prices[stateIndex]);
      }
      if(positionType == POSITION_TYPE_BUY)
      {
         double newTrailTP = NormalizeDouble(currentPrice - TrailProfitOffset, _Digits);
         if(!trailTPWasTriggered || newTrailTP > g_scale_virtual_tp_prices[stateIndex])
            g_scale_virtual_tp_prices[stateIndex] = newTrailTP;
      }
      else
      {
         double newTrailTP = NormalizeDouble(currentPrice + TrailProfitOffset, _Digits);
         if(!trailTPWasTriggered || newTrailTP < g_scale_virtual_tp_prices[stateIndex] ||
            g_scale_virtual_tp_prices[stateIndex] <= 0.0)
            g_scale_virtual_tp_prices[stateIndex] = newTrailTP;
      }
      g_scale_trail_tp_triggered_flags[stateIndex] = true;
   }

   if(positionType == POSITION_TYPE_BUY)
   {
      double newSL = NormalizeDouble(currentPrice - trailSL, _Digits);
      if(newSL > g_scale_virtual_sl_prices[stateIndex])
         g_scale_virtual_sl_prices[stateIndex] = newSL;
   }
   else
   {
      double newSL = NormalizeDouble(currentPrice + trailSL, _Digits);
      if(newSL < g_scale_virtual_sl_prices[stateIndex] || g_scale_virtual_sl_prices[stateIndex] <= 0.0)
         g_scale_virtual_sl_prices[stateIndex] = newSL;
   }

   bool hitSL = false;
   if(!trailTPWasTriggered && priceProfit < TrailProfitTrigger)
   {
      if(positionType == POSITION_TYPE_BUY)
         hitTP = g_scale_virtual_tp_prices[stateIndex] > 0.0 && currentPrice >= g_scale_virtual_tp_prices[stateIndex];
      else
         hitTP = g_scale_virtual_tp_prices[stateIndex] > 0.0 && currentPrice <= g_scale_virtual_tp_prices[stateIndex];
   }
   if(positionType == POSITION_TYPE_BUY)
      hitSL = g_scale_virtual_sl_prices[stateIndex] > 0.0 && currentPrice <= g_scale_virtual_sl_prices[stateIndex];
   else
      hitSL = g_scale_virtual_sl_prices[stateIndex] > 0.0 && currentPrice >= g_scale_virtual_sl_prices[stateIndex];

   if(hitTP || hitSL)
   {
      PrintFormat("【加仓虚拟平仓】触发%s | 持仓ID:%I64u | 当前价:%.5f | 虚拟TP:%.5f | 虚拟SL:%.5f",
                  hitTP ? "止盈" : "止损", positionId, currentPrice,
                  g_scale_virtual_tp_prices[stateIndex], g_scale_virtual_sl_prices[stateIndex]);
      if(trade.PositionClose(positionTicket))
      {
         PrintFormat("【加仓虚拟平仓成功】%s，生命周期结束，不执行反向翻仓",
                     hitTP ? "止盈" : "止损");
         UntrackScaleInPositionAt(stateIndex);
      }
      else
         PrintFormat("【加仓虚拟平仓失败】错误码: %d", trade.ResultRetcode());
   }
   }
   return ArraySize(g_scale_in_position_ids) > 0;
}
//+------------------------------------------------------------------+
//| 【核心】虚拟移动止损 + 双模式止盈：前期逆势收紧，达标后切换顺势放大移动止盈   |
//+------------------------------------------------------------------+
void CheckVirtualStopsAndClose()
{
   ManageScaleInPosition();
   // 日志节流：早期锁利 / 顺势移动止盈 最多每 60 秒打印一次
   static datetime s_lastEarlyLockLogTime = 0;
   static datetime s_lastTrailTPLogTime   = 0;
   const int LOG_INTERVAL_SEC = 60;
   datetime nowServer = TimeTradeServer();

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
         // 计算当前浮盈（USD价格空间，不是账户盈亏）
         double priceProfit = 0.0;
         if(posType == POSITION_TYPE_BUY)
             priceProfit = currentPrice - openPrice;
         else
             priceProfit = openPrice - currentPrice;

         // ========== ★★★ 新增：早期浮盈锁利润（≥EarlyLockProfit 且未达 TrailProfitTrigger）★★★ ==========
         // 只要浮盈 ≥ EarlyLockProfit 且仍在 TrailProfitTrigger 之前，
         // 立即把止损设到开仓价±1，之后随最新价移动（多单只能上移，空单只能下移）
         if(EarlyLockProfit > 0.0 && priceProfit >= EarlyLockProfit && priceProfit < TrailProfitTrigger)
         {
            if(posType == POSITION_TYPE_BUY)
            {
               // 多单：SL = 当前价 - EarlyLockOffset，只能上移
               double earlySL = NormalizeDouble(currentPrice - EarlyLockOffset, _Digits);
               // 第一次触发时至少设到 open + 1
               double minEarlySL = NormalizeDouble(openPrice + 1.0, _Digits);
               if(earlySL < minEarlySL) earlySL = minEarlySL;

               if(earlySL > g_virtual_sl_price)
               {
                  g_virtual_sl_price = earlySL;
                  if(g_monitoring_reverse_position)
                     g_reverse_sl_price = earlySL;
                  // 最多每 1 分钟打印一次，避免刷屏
                  if(nowServer - s_lastEarlyLockLogTime >= LOG_INTERVAL_SEC)
                  {
                     PrintFormat("【早期锁利-多】浮盈%.2f ≥%.1f 且未达%.1f，止损上移至 %.5f（锁约%.1f点）",
                                 priceProfit, EarlyLockProfit, TrailProfitTrigger, g_virtual_sl_price, priceProfit - EarlyLockOffset);
                     s_lastEarlyLockLogTime = nowServer;
                  }
               }
            }
            else // SELL
            {
               // 空单：SL = 当前价 + EarlyLockOffset，只能下移
               double earlySL = NormalizeDouble(currentPrice + EarlyLockOffset, _Digits);
               // 第一次触发时至少设到 open - 1
               double maxEarlySL = NormalizeDouble(openPrice - 1.0, _Digits);
               if(earlySL > maxEarlySL) earlySL = maxEarlySL;

               if(earlySL < g_virtual_sl_price || g_virtual_sl_price <= 0.0)
               {
                  g_virtual_sl_price = earlySL;
                  if(g_monitoring_reverse_position)
                     g_reverse_sl_price = earlySL;
                  // 最多每 1 分钟打印一次，避免刷屏
                  if(nowServer - s_lastEarlyLockLogTime >= LOG_INTERVAL_SEC)
                  {
                     PrintFormat("【早期锁利-空】浮盈%.2f ≥%.1f 且未达%.1f，止损下移至 %.5f（锁约%.1f点）",
                                 priceProfit, EarlyLockProfit, TrailProfitTrigger, g_virtual_sl_price, priceProfit - EarlyLockOffset);
                     s_lastEarlyLockLogTime = nowServer;
                  }
               }
            }
         }
         // ================================================================

         // ========== 浮盈达到配置值 → 设置保本损（开仓价 ± 偏移） ==========
         if(BreakEvenProfit > 0.0)
         {
            if(posType == POSITION_TYPE_BUY)
            {
               double floating = currentPrice - openPrice;
               double bePrice  = NormalizeDouble(openPrice + BreakEvenOffset, _Digits);  // 开仓价 + 偏移
               if(floating >= BreakEvenProfit && bePrice < currentPrice && g_virtual_sl_price < bePrice)
               {
                  g_virtual_sl_price = bePrice;
                  if(g_monitoring_reverse_position)
                     g_reverse_sl_price = g_virtual_sl_price;
                  PrintFormat("【保本】多单浮盈达到 %.2f ≥ %.2f，设置保本损至 %.5f（开仓价+%.1f）",
                              floating, BreakEvenProfit, g_virtual_sl_price, BreakEvenOffset);
               }
            }
            else // SELL
            {
               double floating = openPrice - currentPrice;
               double bePrice  = NormalizeDouble(openPrice - BreakEvenOffset, _Digits);  // 开仓价 - 偏移
               if(floating >= BreakEvenProfit && bePrice > currentPrice &&
                  (g_virtual_sl_price > bePrice || g_virtual_sl_price <= 0.0))
               {
                  g_virtual_sl_price = bePrice;
                  if(g_monitoring_reverse_position)
                     g_reverse_sl_price = g_virtual_sl_price;
                  PrintFormat("【保本】空单浮盈达到 %.2f ≥ %.2f，设置保本损至 %.5f（开仓价-%.1f）",
                              floating, BreakEvenProfit, g_virtual_sl_price, BreakEvenOffset);
               }
            }
         }
         // ================================================================

         double trailSL = g_monitoring_reverse_position ? REV_SL_USD : SL_USD;
         double trailTP = g_monitoring_reverse_position ? REV_TP_USD : TP_USD;
         bool trailTPWasTriggered = g_trail_tp_triggered;
         bool hitTP = false;

          //==== 止盈逻辑：触发前逆势收紧，触发后按固定偏移顺势移动 ==== 
         if(priceProfit < TrailProfitTrigger && !trailTPWasTriggered)
         {
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
                // ★★★ 止盈收紧开关控制 ★★★
                if(EnableTPTighten)
                {
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
             }
             else // SELL 空单
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
                // ★★★ 止盈收紧开关控制 ★★★
                if(EnableTPTighten)
                {
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
             }
         }
         else
         {
             // 已经进入顺势追踪后，先检查上一轮追踪价，避免用本轮新价立即平仓。
             if(trailTPWasTriggered)
             {
               hitTP = (posType == POSITION_TYPE_BUY) ?
                     (currentPrice <= g_virtual_tp_price) :
                     (currentPrice >= g_virtual_tp_price);
             }
             if(posType == POSITION_TYPE_BUY)
             {
                 // 多单：达到触发值后，止盈 = 最新价 - 固定偏移量，只能上移
                 double newTrailTP = NormalizeDouble(currentPrice - TrailProfitOffset, _Digits);
                if(!trailTPWasTriggered || newTrailTP > g_virtual_tp_price)
                 {
                     g_virtual_tp_price = newTrailTP;
                     if(g_monitoring_reverse_position)
                        g_reverse_tp_price = g_virtual_tp_price;
                     // 最多每 1 分钟打印一次，避免刷屏
                     if(nowServer - s_lastTrailTPLogTime >= LOG_INTERVAL_SEC)
                     {
                        PrintFormat("【顺势移动止盈-多】当前价:%.5f，止盈更新至%.5f", currentPrice, g_virtual_tp_price);
                        s_lastTrailTPLogTime = nowServer;
                     }
                 }
             }
             else // SELL
             {
                 // 空单：达到触发值后，止盈 = 最新价 + 固定偏移量，只能下移
                 double newTrailTP = NormalizeDouble(currentPrice + TrailProfitOffset, _Digits);
                if(!trailTPWasTriggered || newTrailTP < g_virtual_tp_price || g_virtual_tp_price <= 0.0)
                 {
                     g_virtual_tp_price = newTrailTP;
                     if(g_monitoring_reverse_position)
                        g_reverse_tp_price = g_virtual_tp_price;
                     // 最多每 1 分钟打印一次，避免刷屏
                     if(nowServer - s_lastTrailTPLogTime >= LOG_INTERVAL_SEC)
                     {
                        PrintFormat("【顺势移动止盈-空】当前价:%.5f，止盈更新至%.5f", currentPrice, g_virtual_tp_price);
                        s_lastTrailTPLogTime = nowServer;
                     }
                 }
             }

             g_trail_tp_triggered = true;

             // 达到触发值时仍只执行一次同向加仓，后续止盈继续移动。
             if(EnableScaleIn && !g_scaled_in)
                ExecuteScaleInOrder(posType);
         }

         // 触发前和触发后都保持移动止损逻辑。
         if(posType == POSITION_TYPE_BUY)
         {
            double newSL = NormalizeDouble(currentPrice - trailSL, _Digits);
            if(newSL > g_virtual_sl_price)
            {
               g_virtual_sl_price = newSL;
               if(g_monitoring_reverse_position)
                  g_reverse_sl_price = newSL;
            }
         }
         else
         {
            double newSL = NormalizeDouble(currentPrice + trailSL, _Digits);
            if(newSL < g_virtual_sl_price || g_virtual_sl_price <= 0.0)
            {
               g_virtual_sl_price = newSL;
               if(g_monitoring_reverse_position)
                  g_reverse_sl_price = newSL;
            }
         }
         // 检查是否触发止盈或止损
         bool hitSL = false;
         if(!trailTPWasTriggered && priceProfit < TrailProfitTrigger)
         {
            if(posType == POSITION_TYPE_BUY)
               hitTP = g_virtual_tp_price > 0.0 && currentPrice >= g_virtual_tp_price;
            else
               hitTP = g_virtual_tp_price > 0.0 && currentPrice <= g_virtual_tp_price;
         }
         if(posType == POSITION_TYPE_BUY)
            hitSL = g_virtual_sl_price > 0.0 && currentPrice <= g_virtual_sl_price;
         else
            hitSL = g_virtual_sl_price > 0.0 && currentPrice >= g_virtual_sl_price;
         if(hitTP || hitSL)
         {
            string reason = hitTP ? "虚拟移动止盈(逆势/顺势)" : "虚拟移动止损";
            PrintFormat("【虚拟平仓】触发%s | 持仓ID:%I64u | 当前价:%.5f | 虚拟TP:%.5f | 虚拟SL:%.5f",
                        reason, g_monitor_position_id, currentPrice, g_virtual_tp_price, g_virtual_sl_price);
            // 先按原逻辑设置，后面若锁利且实际盈利>7再覆盖
            g_last_close_was_tp = hitTP;
            if(trade.PositionClose(posTicket))
            {
               PrintFormat("【虚拟平仓成功】%s 已执行", reason);

               // ★ 3.3.13：锁利触发（hitSL）时检查实际盈亏，>7 按盈利平仓处理
               // ★ 3.3.14：初始单止损净亏 ≤ SkipReverseLossThreshold 时不再反向翻仓
               bool treatAsProfitableClose = false;
               bool skipReverseOnHeavyLoss = false;
               double closedProfit = 0.0;
               if(hitSL)
               {
                  closedProfit = GetClosedPositionProfit(g_monitor_position_id);
                  if(closedProfit > 7.0)
                  {
                     treatAsProfitableClose = true;
                     g_last_close_was_tp = true;   // 让反向单也能走“止盈反转方向”逻辑
                     PrintFormat("【锁利盈利平仓】实际净盈亏 %.2f > 7，按盈利平仓处理（初始单不挂反向 / 反向单下次反转方向）",
                                 closedProfit);
                  }
                  else
                  {
                     PrintFormat("【锁利/止损平仓】实际净盈亏 %.2f ≤ 7，按普通止损处理", closedProfit);
                     // 仅初始单：净亏达到或超过阈值（如 ≤ -18）则跳过反向翻仓
                     if(!g_monitoring_reverse_position &&
                        SkipReverseLossThreshold < 0.0 &&
                        closedProfit <= SkipReverseLossThreshold)
                     {
                        skipReverseOnHeavyLoss = true;
                        PrintFormat("【初始单重亏跳过翻仓】实际净盈亏 %.2f ≤ 阈值 %.2f，不再立即反向翻仓",
                                    closedProfit, SkipReverseLossThreshold);
                     }
                  }
               }

               // ===== 初始单处理 =====
               if(!g_monitoring_reverse_position)
               {
                  if(hitSL && !treatAsProfitableClose && !skipReverseOnHeavyLoss)
                  {
                     // 真正止损（含锁利但盈利≤7，且未触发重亏过滤）→ 延迟1分钟后按价格条件再决定是否反向翻仓
                     // 多单：最新价 < 平仓价 才反向；空单：最新价 > 平仓价 才反向
                     ResetTrackTPState();
                     g_monitor_position_id = INVALID_POSITION_ID;
                     g_virtual_sl_price = 0.0;
                     g_virtual_tp_price = 0.0;
                     g_sl_close_price = currentPrice;
                     g_sl_was_buy = (posType == POSITION_TYPE_BUY);
                     g_pending_sl_reverse_time = TimeTradeServer() + 60;
                     PrintFormat("【初始单止损】已平仓，延迟1分钟后检查价格条件再决定是否反向翻仓 | 平仓价:%.5f | 原方向:%s",
                                 g_sl_close_price, g_sl_was_buy ? "多" : "空");
                  }
                  else
                  {
                     // 止盈 / 锁利盈利>7 / 重亏跳过翻仓 → 只清理，不挂反向
                     ResetTrackTPState();
                     g_monitor_position_id = INVALID_POSITION_ID;
                     g_virtual_sl_price = 0.0;
                     g_virtual_tp_price = 0.0;
                     g_pending_sl_reverse_time = 0;
                     g_sl_close_price = 0.0;
                     if(treatAsProfitableClose)
                        Print("【初始单锁利盈利平仓】已平仓，不进行翻仓");
                     else if(skipReverseOnHeavyLoss)
                        Print("【初始单重亏平仓】已平仓，跳过反向翻仓");
                     else
                        Print("【初始单移动止盈】已平仓，不进行翻仓");
                  }
               }
               // 反向单：只需设置好 g_last_close_was_tp，后续 MonitorPositionStatus 会根据它决定是否反转方向
            }
            else
               PrintFormat("【虚拟平仓失败】错误码: %d", trade.ResultRetcode());
            return;
         }
      }
   }
   // ===== 2. 主仓兜底检查：只处理当前明确登记的主仓 =====
   if(g_monitor_position_id == INVALID_POSITION_ID)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0 || !PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetInteger(POSITION_IDENTIFIER) != (long)g_monitor_position_id)
         continue;
      if(IsTrackedScaleInPosition((ulong)PositionGetInteger(POSITION_IDENTIFIER)))
         continue;
      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice  = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double priceMove = (posType == POSITION_TYPE_BUY) ? (curPrice - openPrice) : (openPrice - curPrice);
      double slThreshold = g_monitoring_reverse_position ? REV_SL_USD : SL_USD;
      if(priceMove <= -slThreshold)
      {
         PrintFormat("【兜底虚拟止损】强制平仓！Ticket:%I64u 移动:%.2f <= -%.2f", pt, priceMove, slThreshold);
         g_last_close_was_tp = false;
         ulong fallbackPosId = g_monitor_position_id;
         if(trade.PositionClose(pt))
         {
            if(!g_monitoring_reverse_position)
            {
               ResetTrackTPState();
               g_monitor_position_id = INVALID_POSITION_ID;
               g_virtual_sl_price = 0.0;
               g_virtual_tp_price = 0.0;
               // ★ 3.3.14：兜底路径同样检查净亏阈值，重亏则不反向
               double closedProfitFallback = GetClosedPositionProfit(fallbackPosId);
               if(SkipReverseLossThreshold < 0.0 && closedProfitFallback <= SkipReverseLossThreshold)
               {
                  PrintFormat("【兜底初始单重亏跳过翻仓】实际净盈亏 %.2f ≤ 阈值 %.2f，不再反向翻仓",
                              closedProfitFallback, SkipReverseLossThreshold);
                  g_pending_sl_reverse_time = 0;
                  g_sl_close_price = 0.0;
               }
               else
               {
                  // ★ 5.3.15：兜底止损同样延迟1分钟后按价格条件决定是否反向
                  g_sl_close_price = curPrice;
                  g_sl_was_buy = (posType == POSITION_TYPE_BUY);
                  g_pending_sl_reverse_time = TimeTradeServer() + 60;
                  PrintFormat("【兜底初始单止损】已平仓，延迟1分钟后检查价格条件再决定是否反向翻仓 | 平仓价:%.5f | 原方向:%s",
                              g_sl_close_price, g_sl_was_buy ? "多" : "空");
               }
            }
            else
            {
               ResetTrackTPState();
               g_monitor_position_id = INVALID_POSITION_ID;
               g_virtual_sl_price = 0.0;
               g_virtual_tp_price = 0.0;
            }
         }
         return;
      }
   }
}
void ResetTrackTPState()
{
    g_scaled_in = false;                     // ★新增：重置加仓标记
   g_trail_tp_triggered = false;
}
//+------------------------------------------------------------------+
//| 5.3.15：初始单止损后延迟1分钟，按价格条件决定是否反向翻仓           |
//| 多单：最新价 < 平仓价 才反向做空；空单：最新价 > 平仓价 才反向做多   |
//+------------------------------------------------------------------+
void ProcessPendingSLReverse()
{
   if(g_pending_sl_reverse_time <= 0)
      return;
   if(TimeTradeServer() < g_pending_sl_reverse_time)
      return;

   // 到期后只检查一次
   datetime checkTime = g_pending_sl_reverse_time;
   g_pending_sl_reverse_time = 0;

   // 若期间已有持仓或挂单，则不再反向
   if(CheckHasAnyPendingOrder() || CheckHasAnyPosition())
   {
      Print("【止损延迟翻仓】到期时已存在持仓或挂单，取消本次反向翻仓");
      g_sl_close_price = 0.0;
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("【止损延迟翻仓】获取Tick失败，取消本次反向翻仓，错误码: ", GetLastError());
      g_sl_close_price = 0.0;
      return;
   }

   // 多单止损后用 bid 判断是否继续下跌；空单止损后用 ask 判断是否继续上涨
   double latestPrice = g_sl_was_buy ? tick.bid : tick.ask;
   bool conditionMet = false;
   if(g_sl_was_buy)
   {
      // 初始多单止损：要求最新价 < 平仓价，才挂反向空单
      conditionMet = (latestPrice < g_sl_close_price);
      PrintFormat("【止损延迟翻仓-多→空】平仓价:%.5f 最新bid:%.5f 条件(最新价<平仓价):%s",
                  g_sl_close_price, latestPrice, conditionMet ? "满足" : "不满足");
   }
   else
   {
      // 初始空单止损：要求最新价 > 平仓价，才挂反向多单
      conditionMet = (latestPrice > g_sl_close_price);
      PrintFormat("【止损延迟翻仓-空→多】平仓价:%.5f 最新ask:%.5f 条件(最新价>平仓价):%s",
                  g_sl_close_price, latestPrice, conditionMet ? "满足" : "不满足");
   }

   if(conditionMet)
   {
      Print("【止损延迟翻仓】价格条件满足，执行反向翻仓");
      ExecuteReverseOrder();
   }
   else
   {
      Print("【止损延迟翻仓】价格条件不满足，本次不挂反向翻仓单");
   }
   g_sl_close_price = 0.0;
}
//+------------------------------------------------------------------+
//| 监控持仓状态                                                       |
//+------------------------------------------------------------------+
void MonitorPositionStatus()
{
   CheckVirtualStopsAndClose();
   ProcessPendingSLReverse();   // ★ 5.3.15：处理初始单止损后的延迟价格条件翻仓
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
         // 拟反转后的方向
         ENUM_INIT_DIRECTION proposedDir = (g_currentDirection == DIR_SHORT) ? DIR_LONG : DIR_SHORT;
         
         if(UseTrendFilterOnReverse)
         {
            // 高周期趋势过滤：只有拟反转方向与高周期趋势一致时才真正反转
            ENUM_INIT_DIRECTION trendDir = GetHigherTFTrendDirection();
            if(proposedDir == trendDir)
            {
               g_currentDirection = proposedDir;
               PrintFormat("【方向更新+趋势过滤】初始单止损+反向单止盈 → 拟反转方向与高周期趋势一致，已反转方向为: %s",
                           (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
            }
            else
            {
               PrintFormat("【方向保持+趋势过滤】初始单止损+反向单止盈 → 拟反转方向(%s)与高周期趋势(%s)不一致，保持原方向: %s",
                           (proposedDir == DIR_SHORT) ? "做空" : "做多",
                           (trendDir == DIR_SHORT) ? "做空" : "做多",
                           (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
            }
         }
         else
         {
            // 不启用趋势过滤，直接反转
            g_currentDirection = proposedDir;
            PrintFormat("【方向更新】初始单止损 + 反向单止盈 → 已反转方向为: %s",
                        (g_currentDirection == DIR_SHORT) ? "做空" : "做多");
         }
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
      g_pending_sl_reverse_time = 0;
      g_sl_close_price = 0.0;
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
      if(!IsInCustomTradingHours(serverNow))
      {
      // 不在交易时段，继续等待
      g_nextTriggerTime = CalculateNextTriggerTime(serverNow);
      return;
      }
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
   // ★ 5.3.15：等待止损延迟翻仓期间，禁止定时新开初始单，避免与反向单冲突
   if(g_pending_sl_reverse_time > 0)
   {
      PrintFormat("【定时任务】时间: %s，正在等待止损延迟翻仓确认，跳过本次开仓。下次触发: %s",
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

   // ★★★ 自定义交易时间段过滤 ★★★
   if(!IsInCustomTradingHours(serverNow))
   {
      PrintFormat("【自定义时间段】当前时间 %s 不在允许交易窗口内（%02d:%02d - %02d:%02d），跳过开仓。下次触发: %s",
                  TimeToString(serverNow, TIME_DATE|TIME_MINUTES),
                  TradingStartHour, TradingStartMinute,
                  TradingEndHour, TradingEndMinute,
                  TimeToString(nextAfterThis, TIME_DATE|TIME_MINUTES));
      g_nextTriggerTime = nextAfterThis;
      return;
   }

   if(g_currentDirection == DIR_SHORT) ExecuteShortOrder();
   else                                 ExecuteLongOrder();
   g_lastTradeTime = serverNow;
   g_nextTriggerTime = nextAfterThis;
}
//+------------------------------------------------------------------+