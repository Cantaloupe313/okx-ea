import time
import ccxt
from apscheduler.schedulers.blocking import BlockingScheduler
from datetime import datetime

# ================= 配置区域 =================
API_KEY = "你的OKX_API_KEY"
SECRET_KEY = "你的OKX_SECRET_KEY"
PASSWORD = "你的OKX_API_PASSPHRASE"


# 本地代理（国内直连 okx.com 会超时，需走 Clash/V2Ray 等）
# Clash Verge 默认混合端口 7897；不用代理时设为 None
PROXY_URL = 'http://127.0.0.1:7897'


exchange = ccxt.okx({
    'apiKey': API_KEY,
    'secret': SECRET_KEY,
    'password': PASSWORD,
    'enableRateLimit': True,
    'options': {'defaultType': 'swap'},  # 永续合约
    'proxies': {'http': PROXY_URL, 'https': PROXY_URL} if PROXY_URL else None,
})

SYMBOL = 'ETH/USDT:USDT'
LEVERAGE = 100

# 全局变量：记录上一次成功下初始单的时间（用于2分钟防重复）
last_order_time = 0

def set_leverage_safely():
    try:
        exchange.set_leverage(LEVERAGE, SYMBOL)
        print(f"[{datetime.now()}] 杠杆已设置为 {LEVERAGE}x (单向持仓模式)")
    except Exception as e:
        print(f"设置杠杆提示: {e}")

# ================= 辅助函数：等待限价单成交 =================
def wait_for_order_filled(order_id, timeout=600):
    """循环轮询，直到订单完全成交或超时"""
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            order = exchange.fetch_order(order_id, SYMBOL)
            status = order['status']
            if status == 'closed': # closed 代表完全成交
                return order
            elif status == 'canceled':
                print(f"订单 {order_id} 已被取消。")
                return None
            time.sleep(1) 
        except Exception as e:
            print(f"轮询订单状态出错: {e}")
            time.sleep(2)
    print(f"订单 {order_id} 在 {timeout} 秒内未成交，放弃监听。")
    return None

# ================= 核心策略执行 =================
def execute_strategy():
    global last_order_time
    now_timestamp = time.time()
    
    print(f"\n====== 策略触发检查: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ======")
    
    # 1. 检查2分钟内防止重复下单
    if now_timestamp - last_order_time < 120:
        print(f"【防重触发】距离上一次下单未满 2 分钟，跳过本次执行。")
        return

    try:
        # 2. 检查现有的 ETH 持仓状态
        # 单向持仓模式下，fetch_positions 正常返回当前仓位
        positions = exchange.fetch_positions([SYMBOL])
        has_position = False
        for pos in positions:
            # contracts 或者是 size 大于 0 代表有实际持仓
            if pos['contracts'] and float(pos['contracts']) > 0:
                has_position = True
                print(f"检查到当前已有 ETH 持仓: {pos['contracts']} 个币，方向: {pos['side']}")
                break
        
        if has_position:
            print("【条件跳过】当前存在 ETH 已成交持仓，跳过本次下单，等待下一次周期。")
            return

        # 3. 检查并撤销所有 ETH 未成交的挂单 (包括限价单和策略委托单)
        print("检查是否存在未成交挂单...")
        open_orders = exchange.fetch_open_orders(SYMBOL)
        if open_orders:
            print(f"发现 {len(open_orders)} 笔未成交挂单，正在执行撤单...")
            for order in open_orders:
                try:
                    exchange.cancel_order(order['id'], SYMBOL)
                    print(f"成功撤单: {order['id']}")
                except Exception as ce:
                    print(f"撤单失败 {order['id']}: {ce}")
        else:
            print("无可撤销的未成交挂单。")

        # 4. 获取市价并计算初始空单限价
        ticker = exchange.fetch_ticker(SYMBOL)
        current_price = ticker['last']
        short_price = round(current_price - 0.02, 2)
        short_amount = 10
        
        print(f"[初始空单] 当前市价: {current_price} -> 计划以 {short_price} 挂限价做空 {short_amount} ETH")
        
        # 5. 挂出初始限价空单并附加限价止盈止损
        short_sl_trigger = round(short_price + 2, 2)
        short_tp_trigger = round(short_price - 2, 2)
        
        params = {
            'stopLoss': {
                'type': 'limit',                  
                'triggerPrice': short_sl_trigger, 
                'price': short_sl_trigger,        
            },
            'takeProfit': {
                'type': 'limit',                  
                'triggerPrice': short_tp_trigger, 
                'price': short_tp_trigger,        
            }
        }
        
        short_order = exchange.create_order(
            symbol=SYMBOL, type='limit', side='sell', 
            amount=short_amount, price=short_price, params=params
        )
        short_id = short_order['id']
        print(f"成功挂出初始空单(ID: {short_id})，附带限价止损 {short_sl_trigger}，限价止盈 {short_tp_trigger}")
        
        # 更新成功下单时间，防止2分钟内多重触发
        last_order_time = time.time()

        # 6. 监听初始空单的成交情况
        print("等待初始空单在市场成交...")
        filled_short = wait_for_order_filled(short_id, timeout=600)
        if not filled_short or not (float(filled_short['filled']) > 0):
            print("初始空单未能成交或已被撤销，结束本次监听。")
            return

        # 7. 开始监听是否触发了“止损”
        print("初始空单已成交。进入局部盘口监控，等待止损或止盈...")
        
        while True:
            ticker = exchange.fetch_ticker(SYMBOL)
            now_price = ticker['last']
            
            # 如果市场价格达到或超过了空单的止损触发价，代表止损已激活
            if now_price >= short_sl_trigger:
                print(f"【警报】检测到市场价 {now_price} 已触及空单止损线 {short_sl_trigger}！")
                
                # 稍作停顿等待交易所内部撮合与风控结算完成
                time.sleep(1.5) 
                
                # 8. 反向翻仓：下限价看涨做多
                long_price = round(short_sl_trigger + 0.02, 2)
                long_amount = 11
                
                long_tp_trigger = round(long_price + 2, 2)
                long_sl_trigger = round(long_price - 2, 2)
                
                long_params = {
                    'stopLoss': {
                        'type': 'limit',
                        'triggerPrice': long_sl_trigger,
                        'price': long_sl_trigger,
                    },
                    'takeProfit': {
                        'type': 'limit',
                        'triggerPrice': long_tp_trigger,
                        'price': long_tp_trigger,
                    }
                }
                
                print(f"[反向翻仓] 正在挂出限价做多单，价格: {long_price}, 数量: {long_amount} ETH")
                try:
                    long_order = exchange.create_order(
                        symbol=SYMBOL, type='limit', side='buy', 
                        amount=long_amount, price=long_price, params=long_params
                    )
                    print(f"成功翻仓做多！多单ID: {long_order['id']}，附带限价止损 {long_sl_trigger}，止盈 {long_tp_trigger}")
                except Exception as e:
                    print(f"翻仓下单失败: {e}")
                
                break 
                
            # 如果检测到价格已经跌破了止盈线，说明是正常止盈出局，无需翻仓
            if now_price <= short_tp_trigger:
                print(f"检测到价格 {now_price} 已触及止盈线 {short_tp_trigger}，空单正常止盈，无需翻仓。")
                break
                
            time.sleep(2) # 每 2 秒监控一次盘口

    except Exception as e:
        print(f"执行过程中发生异常: {e}")

# ================= 定时任务配置 =================
if __name__ == "__main__":
    set_leverage_safely()
    
    scheduler = BlockingScheduler(timezone='Asia/Shanghai')
    # 配置每小时的 00, 15, 30, 45 分钟触发
    scheduler.add_job(execute_strategy, 'cron', minute='0,15,30,45', second='0')
    
    print("安全增强版 OKX 策略脚本已启动...")
    try:
        scheduler.start()
    except (KeyboardInterrupt, SystemExit):
        print("策略已手动停止。")