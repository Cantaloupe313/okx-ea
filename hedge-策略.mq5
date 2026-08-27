//+------------------------------------------------------------------+
//|                                          TimedHedgeEA.mq5        |
//|                                  定时对冲开仓 + 回撤/库存费保护    |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.3.0"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- 输入参数
input group "=== 基础交易参数 ==="
input double   InpLotSize          = 0.01;      // 开仓手数
input double   InpSL_Distance      = 10.0;      // 止损距离（价格，例如 10 = 10美元）
input double   InpTP_Distance      = 25.0;      // 止盈距离（价格，例如 25 = 25美元）
input int      InpMagicNumber      = 20250825;  // 魔术号

input group "=== 风险控制参数 ==="
input double   InpDrawdownPercent  = 5.0;       // 回撤率（%），达到后全平+撤单+停止EA
input double   InpMinProfitToClose = 5.0;       // 库存费前清理时，单仓最小盈利（账户货币）

input group "=== 时间控制参数 ==="
input int      InpMinutesBeforeSwap = 30;       // 距离扣除库存费前多少分钟开始扫描
input int      InpAntiRepeatMinutes = 4;        // 防止重复开仓时间（分钟）

//--- 全局变量
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

datetime       lastOpenTime     = 0;            // 上次开仓时间
double         maxEquity        = 0;            // 最高权益（用于计算回撤）
bool           isClosing        = false;        // 正在全平标志，防止重复触发
bool           g_tradingEnabled = true;         // 回撤触发后永久禁止交易

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);   // 根据经纪商可改为 FOK 或 RETURN
   
   maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradingEnabled = true;
   
   Print("TimedHedgeEA 初始化完成 v1.3.0（库存费时间自动获取 + 自动滑点 + 回撤强制停止）");
   Print("止损间距=", InpSL_Distance, "  止盈间距=", InpTP_Distance);
   Print("回撤保护阈值=", InpDrawdownPercent, "%  达到后将全平并卸载EA");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("TimedHedgeEA 已卸载，原因代码: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 更新最高权益
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > maxEquity)
      maxEquity = equity;
   
   // 1. 回撤检查（优先级最高）
   CheckDrawdown();
   
   // 如果已经因回撤禁用，后续逻辑全部跳过
   if(!g_tradingEnabled)
      return;
   
   // 2. 库存费前清理检查
   CheckBeforeSwap();
   
   // 3. 定时开仓检查
   CheckTimedOpen();
}

//+------------------------------------------------------------------+
//| 回撤检查                                                         |
//+------------------------------------------------------------------+
void CheckDrawdown()
{
   if(isClosing || !g_tradingEnabled)
      return;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(maxEquity <= 0)
      return;
   
   double drawdown = (maxEquity - equity) / maxEquity * 100.0;
   
   if(drawdown >= InpDrawdownPercent)
   {
      Print("========== 回撤保护触发 ==========");
      Print("最高权益: ", DoubleToString(maxEquity, 2),
            "  当前权益: ", DoubleToString(equity, 2),
            "  回撤: ", DoubleToString(drawdown, 2), "%");
      Print("开始全平仓 + 撤销挂单，并停止EA运行");
      
      CloseAllAndCancel();
      
      // 永久禁用交易并卸载EA
      g_tradingEnabled = false;
      maxEquity = equity;
      
      // 强制停止EA（真正卸载）
      ExpertRemove();
   }
}

//+------------------------------------------------------------------+
//| 库存费前清理检查（自动获取日切换时间）                           |
//+------------------------------------------------------------------+
void CheckBeforeSwap()
{
   if(isClosing || !g_tradingEnabled)
      return;
   
   datetime currentDayOpen = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDayOpen == 0)
      return;
   
   datetime nextSwapTime = currentDayOpen + PeriodSeconds(PERIOD_D1);
   int minutesToSwap = (int)((nextSwapTime - TimeCurrent()) / 60);
   
   if(minutesToSwap > InpMinutesBeforeSwap || minutesToSwap < 0)
      return;
   
   bool hasProfitable = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() != InpMagicNumber) continue;
         if(posInfo.Symbol() != _Symbol) continue;
         
         double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         if(profit > InpMinProfitToClose)
         {
            hasProfitable = true;
            break;
         }
      }
   }
   
   if(hasProfitable)
   {
      Print("距离库存费时间还有 ", minutesToSwap, " 分钟，发现盈利仓位 > ", InpMinProfitToClose,
            "，开始全平仓并撤销挂单");
      CloseAllAndCancel();
   }
}

//+------------------------------------------------------------------+
//| 检查是否存在本EA同品种的持仓或挂单                               |
//+------------------------------------------------------------------+
bool HasExistingPositionsOrOrders()
{
   // 检查已成交持仓
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
            return true;
      }
   }
   
   // 检查未成交委托（挂单）
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Magic() == InpMagicNumber && orderInfo.Symbol() == _Symbol)
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| 定时开仓检查                                                     |
//+------------------------------------------------------------------+
void CheckTimedOpen()
{
   if(isClosing || !g_tradingEnabled)
      return;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // 每5分钟的整点（00,05,10...）
   if(dt.min % 5 != 0)
      return;
   
   // 只在秒数 < 5 时触发一次
   if(dt.sec > 5)
      return;
   
   // 防重复开仓时间检查
   if(lastOpenTime > 0)
   {
      int secondsPassed = (int)(TimeCurrent() - lastOpenTime);
      if(secondsPassed < InpAntiRepeatMinutes * 60)
         return;
   }
   
   // 检查同品种是否已有持仓或挂单
   if(HasExistingPositionsOrOrders())
   {
      // Print("已存在同品种持仓或挂单，跳过本次定时开仓，等待下次");
      return;
   }
   
   // 开仓
   OpenBuyAndSell();
}

//+------------------------------------------------------------------+
//| 同时开多空并设置止盈止损（按价格距离计算）                         |
//+------------------------------------------------------------------+
void OpenBuyAndSell()
{
   // 自动滑点
   int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int autoSlippage  = currentSpread + 30;
   trade.SetDeviationInPoints(autoSlippage);
   
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double slDistance = InpSL_Distance;
   double tpDistance = InpTP_Distance;
   
   // 多单
   double sl_buy = NormalizeDouble(ask - slDistance, digits);
   double tp_buy = NormalizeDouble(ask + tpDistance, digits);
   
   // 空单
   double sl_sell = NormalizeDouble(bid + slDistance, digits);
   double tp_sell = NormalizeDouble(bid - tpDistance, digits);
   
   // 开多
   bool buyOk = trade.Buy(InpLotSize, _Symbol, ask, sl_buy, tp_buy, "TimedHedge Buy");
   if(buyOk)
      Print("开多成功  手数=", InpLotSize, "  开仓价=", ask, "  SL=", sl_buy, "  TP=", tp_buy);
   else
      Print("开多失败  错误=", GetLastError(), "  ", trade.ResultRetcodeDescription());
   
   // 开空
   bool sellOk = trade.Sell(InpLotSize, _Symbol, bid, sl_sell, tp_sell, "TimedHedge Sell");
   if(sellOk)
      Print("开空成功  手数=", InpLotSize, "  开仓价=", bid, "  SL=", sl_sell, "  TP=", tp_sell);
   else
      Print("开空失败  错误=", GetLastError(), "  ", trade.ResultRetcodeDescription());
   
   if(buyOk || sellOk)
   {
      lastOpenTime = TimeCurrent();
      Print("定时对冲开仓完成，下次允许开仓时间：",
            TimeToString(lastOpenTime + InpAntiRepeatMinutes * 60));
   }
}

//+------------------------------------------------------------------+
//| 全平仓 + 撤销所有挂单（更安全版本）                              |
//+------------------------------------------------------------------+
void CloseAllAndCancel()
{
   isClosing = true;
   
   // ---------- 1. 先收集所有需要平仓的持仓 ticket ----------
   ulong posTickets[];
   ArrayResize(posTickets, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() != InpMagicNumber) continue;
         if(posInfo.Symbol() != _Symbol) continue;
         
         ulong ticket = posInfo.Ticket();
         int size = ArraySize(posTickets);
         ArrayResize(posTickets, size + 1);
         posTickets[size] = ticket;
      }
   }
   
   // 执行平仓
   for(int i = 0; i < ArraySize(posTickets); i++)
   {
      ulong ticket = posTickets[i];
      if(!trade.PositionClose(ticket))
         Print("平仓失败 ticket=", ticket, " 错误=", GetLastError(), "  ", trade.ResultRetcodeDescription());
      else
         Print("已平仓 ticket=", ticket);
   }
   
   // ---------- 2. 先收集所有需要撤销的挂单 ticket ----------
   ulong orderTickets[];
   ArrayResize(orderTickets, 0);
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Magic() != InpMagicNumber) continue;
         if(orderInfo.Symbol() != _Symbol) continue;
         
         ulong ticket = orderInfo.Ticket();
         int size = ArraySize(orderTickets);
         ArrayResize(orderTickets, size + 1);
         orderTickets[size] = ticket;
      }
   }
   
   // 执行撤单
   for(int i = 0; i < ArraySize(orderTickets); i++)
   {
      ulong ticket = orderTickets[i];
      if(!trade.OrderDelete(ticket))
         Print("撤单失败 ticket=", ticket, " 错误=", GetLastError(), "  ", trade.ResultRetcodeDescription());
      else
         Print("已撤销挂单 ticket=", ticket);
   }
   
   // 重置
   maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   isClosing = false;
   
   Print("全平仓 + 撤单操作完成");
}
//+------------------------------------------------------------------+