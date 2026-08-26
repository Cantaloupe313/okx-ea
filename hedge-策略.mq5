//+------------------------------------------------------------------+
//|                                          TimedHedgeEA.mq5        |
//|                                  定时对冲开仓 + 回撤/库存费保护    |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.2.0"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- 输入参数
input group "=== 基础交易参数 ==="
input double   InpLotSize          = 0.01;      // 开仓手数
input double   InpSL_Distance = 10.0;   // 止损距离（价格，例如 10 = 10美元）
input double   InpTP_Distance = 25.0;   // 止盈距离（价格，例如 25 = 25美元）
input int      InpMagicNumber      = 20250825;  // 魔术号

input group "=== 风险控制参数 ==="
input double   InpDrawdownPercent  = 5.0;       // 回撤率（%），达到后全平+撤单
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

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);   // 根据经纪商可改为 FOK 或 RETURN
   
   maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   Print("TimedHedgeEA 初始化完成（库存费时间自动获取 + 自动滑点）");
   Print("止损间距=", InpSL_Distance, " 点，止盈间距=", InpTP_Distance, " 点");
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
   
   // 1. 回撤检查
   CheckDrawdown();
   
   // 2. 库存费前清理检查（自动获取时间）
   CheckBeforeSwap();
   
   // 3. 定时开仓检查
   CheckTimedOpen();
}

//+------------------------------------------------------------------+
//| 回撤检查                                                         |
//+------------------------------------------------------------------+
void CheckDrawdown()
{
   if(isClosing) return;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(maxEquity <= 0) return;
   
   double drawdown = (maxEquity - equity) / maxEquity * 100.0;
   
   if(drawdown >= InpDrawdownPercent)
   {
      Print("回撤达到 ", DoubleToString(drawdown, 2), "% ，开始全平仓并撤销挂单");
      CloseAllAndCancel();
      maxEquity = equity;  // 重置最高权益，避免连续触发
   }
}

//+------------------------------------------------------------------+
//| 库存费前清理检查（自动获取日切换时间）                           |
//+------------------------------------------------------------------+
void CheckBeforeSwap()
{
   if(isClosing) return;
   
   // 自动获取下一个日线切换时间（通常就是库存费收取时间）
   datetime currentDayOpen = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDayOpen == 0) return;  // 数据未就绪
   
   datetime nextSwapTime = currentDayOpen + PeriodSeconds(PERIOD_D1);  // 下一个日切换时刻
   
   // 计算距离下次库存费还有多少分钟
   int minutesToSwap = (int)((nextSwapTime - TimeCurrent()) / 60);
   
   // 只在设定的时间窗口内检查（0 ~ InpMinutesBeforeSwap 分钟）
   if(minutesToSwap > InpMinutesBeforeSwap || minutesToSwap < 0)
      return;
   
   // 检查是否有任何持仓盈利 > InpMinProfitToClose
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
      Print("距离自动获取的库存费时间还有 ", minutesToSwap, 
            " 分钟，发现盈利仓位 > ", InpMinProfitToClose, 
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
   if(isClosing) return;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // 每5分钟的整点（00,05,10...）
   if(dt.min % 5 != 0) return;
   
   // 只在秒数 < 5 时触发一次（避免同一分钟多次触发）
   if(dt.sec > 5) return;
   
   // 防重复开仓时间检查
   if(lastOpenTime > 0)
   {
      int secondsPassed = (int)(TimeCurrent() - lastOpenTime);
      if(secondsPassed < InpAntiRepeatMinutes * 60)
         return;
   }
   
   // ★ 新增：检查同品种是否已有持仓或挂单，有则跳过本次开仓
   if(HasExistingPositionsOrOrders())
   {
      // 可选日志，避免刷屏可注释掉
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
   // ===== 自动滑点 =====
   int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int autoSlippage  = currentSpread + 30;
   trade.SetDeviationInPoints(autoSlippage);
   // ========================
   
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits= (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // 直接使用输入值作为价格距离（单位：美元）
   double slDistance = InpSL_Distance;   // 例如 10
   double tpDistance = InpTP_Distance;   // 例如 25
   
   // 多单
   double sl_buy = NormalizeDouble(ask - slDistance, digits);
   double tp_buy = NormalizeDouble(ask + tpDistance, digits);
   
   // 空单
   double sl_sell = NormalizeDouble(bid + slDistance, digits);
   double tp_sell = NormalizeDouble(bid - tpDistance, digits);
   
   // 开多
   bool buyOk = trade.Buy(InpLotSize, _Symbol, ask, sl_buy, tp_buy, "TimedHedge Buy");
   if(buyOk)
      Print("开多成功  手数=", InpLotSize, 
            "  开仓价=", ask,
            "  SL=", sl_buy, "  TP=", tp_buy);
   else
      Print("开多失败  错误=", GetLastError(), "  ", trade.ResultRetcodeDescription());
   
   // 开空
   bool sellOk = trade.Sell(InpLotSize, _Symbol, bid, sl_sell, tp_sell, "TimedHedge Sell");
   if(sellOk)
      Print("开空成功  手数=", InpLotSize, 
            "  开仓价=", bid,
            "  SL=", sl_sell, "  TP=", tp_sell);
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
//| 全平仓 + 撤销所有挂单                                            |
//+------------------------------------------------------------------+
void CloseAllAndCancel()
{
   isClosing = true;
   
   // 1. 平掉所有本EA的持仓
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() != InpMagicNumber) continue;
         if(posInfo.Symbol() != _Symbol) continue;
         
         ulong ticket = posInfo.Ticket();
         if(!trade.PositionClose(ticket))
            Print("平仓失败 ticket=", ticket, " 错误=", GetLastError());
         else
            Print("已平仓 ticket=", ticket);
      }
   }
   
   // 2. 撤销所有本EA的挂单
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Magic() != InpMagicNumber) continue;
         if(orderInfo.Symbol() != _Symbol) continue;
         
         ulong ticket = orderInfo.Ticket();
         if(!trade.OrderDelete(ticket))
            Print("撤单失败 ticket=", ticket, " 错误=", GetLastError());
         else
            Print("已撤销挂单 ticket=", ticket);
      }
   }
   
   // 重置最高权益
   maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   isClosing = false;
   
   Print("全平仓 + 撤单操作完成");
}
//+------------------------------------------------------------------+