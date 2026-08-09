
import time
import argparse
import ccxt
from apscheduler.schedulers.blocking import BlockingScheduler
from datetime import datetime

# ================= 模拟盘配置区域 =================
API_KEY = "1c5edca6-441a-4f1b-9343-40b38645f76e"      # 必须在模拟盘页面生成的KEY
SECRET_KEY = "B03EDED738DBF5943C98DF9DBA062AED"
PASSWORD = "As12345678@"

# 本地代理（国内直连 okx.com 会超时，需走 Clash/V2Ray 等）
# Clash Verge 默认混合端口 7897；不用代理时设为 None
PROXY_URL = 'http://127.0.0.1:7897'

exchange = ccxt.okx({
    'apiKey': API_KEY,
    'secret': SECRET_KEY,
    'password': PASSWORD,
    'enableRateLimit': True,
    'proxies': {'http': PROXY_URL, 'https': PROXY_URL} if PROXY_URL else None,
})

# === 核心：开启 OKX 模拟盘模式并锁定永续合约路由 ===
exchange.set_sandbox_mode(True)
# 显式注入 x-simulated-trading header，双重保险（ccxt.set_sandbox_mode 虽会自动加，但某些版本漏加会导致 50123）
exchange.headers['x-simulated-trading'] = '1'
exchange.options['defaultType'] = 'swap'  # 显式锁死为永续合约类型

SYMBOL = 'ETH/USDT:USDT'
LEVERAGE = 50
# =================================================

# 全局变量：记录上一次成功下初始单的时间（用于2分钟防重复）
last_order_time = 0
# 全局：账户持仓模式缓存（net_mode / long_short_mode）
pos_mode_cache = None
# 全局：下单数量（单位：ETH），由命令行 -amount 传入，默认 10 ETH
AMOUNT_ETH = 10.0


def parse_args():
    """解析命令行参数：-amount 指定下单 ETH 数量"""
    parser = argparse.ArgumentParser(description='OKX 模拟盘 ETH 永续策略')
    # 注意：argparse 中 -amount 这种单杠多字符选项需显式注册
    parser.add_argument('-amount', '--amount', dest='amount',
                        type=float, default=10.0,
                        help='下单数量(ETH)，默认 10 ETH。例: -amount 10 表示下单 10 ETH')
    return parser.parse_args()


def eth_to_contracts(eth_amount):
    """将 ETH 数量转换为 OKX 合约张数。
    OKX ETH/USDT:USDT 永续 1 张 = 0.1 ETH，故 10 ETH = 100 张。
    """
    market = exchange.market(SYMBOL)
    contract_size = float(market.get('contractSize', 1)) or 1.0
    return eth_amount / contract_size


def detect_pos_mode():
    """探测账户持仓模式并缓存，返回 'net_mode' 或 'long_short_mode'"""
    global pos_mode_cache
    if pos_mode_cache is not None:
        return pos_mode_cache
    try:
        # ccxt 没有直接封装查 posMode，直接走私有接口
        import requests, hmac, hashlib, base64, json
        from datetime import datetime as _dt, timezone
        ts = _dt.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
        path = '/api/v5/account/config'
        msg = ts + 'GET' + path + ''
        sign = base64.b64encode(hmac.new(SECRET_KEY.encode(), msg.encode(), hashlib.sha256).digest()).decode()
        hdrs = {
            'OK-ACCESS-KEY': API_KEY,
            'OK-ACCESS-SIGN': sign,
            'OK-ACCESS-TIMESTAMP': ts,
            'OK-ACCESS-PASSPHRASE': PASSWORD,
            'x-simulated-trading': '1',
        }
        proxies = {'http': PROXY_URL, 'https': PROXY_URL} if PROXY_URL else None
        r = requests.get('https://www.okx.com' + path, headers=hdrs, proxies=proxies, timeout=15).json()
        if r.get('code') == '0' and r.get('data'):
            pos_mode_cache = r['data'][0].get('posMode', 'net_mode')
        else:
            pos_mode_cache = 'long_short_mode'  # 兜底：模拟盘默认双向
    except Exception:
        pos_mode_cache = 'long_short_mode'
    print(f"[持仓模式检测] 当前账户: {pos_mode_cache}")
    return pos_mode_cache


def build_order_params(side, position_side, sl_trigger=None, tp_trigger=None):
    """根据持仓模式构建 create_order params：
    - long_short_mode 必须显式带 posSide
    - 止盈止损附带 reduceOnly 保证平仓
    """
    params = {}
    pos_mode = detect_pos_mode()

    if pos_mode == 'long_short_mode':
        params['posSide'] = position_side  # 'long' 或 'short'

    if sl_trigger is not None or tp_trigger is not None:
        if pos_mode == 'long_short_mode':
            close_side = 'buy' if position_side == 'short' else 'sell'
            extra_for_algo = {'posSide': position_side, 'reduceOnly': True}
        else:
            close_side = 'buy' if side == 'sell' else 'sell'
            extra_for_algo = {}

        if sl_trigger is not None:
            params['stopLoss'] = {
                'type': 'limit',
                'triggerPrice': sl_trigger,
                'price': sl_trigger,
                'side': close_side,
                **extra_for_algo,
            }
        if tp_trigger is not None:
            params['takeProfit'] = {
                'type': 'limit',
                'triggerPrice': tp_trigger,
                'price': tp_trigger,
                'side': close_side,
                **extra_for_algo,
            }
    return params


def has_any_position():
    """统一处理 net_mode / long_short_mode 的持仓查询"""
    positions = exchange.fetch_positions([SYMBOL])
    pos_mode = detect_pos_mode()
    for pos in positions:
        contracts = 0
        if pos.get('contracts'):
            contracts = float(pos['contracts'])
        # ccxt 在 long_short_mode 下会给 2 条 record（long / short），都可能是 0
        if contracts > 0:
            print(f"检查到当前已有 ETH 持仓: {contracts} 合约, info: {pos.get('info', {}).get('posSide', pos.get('side'))}")
            return True
    return False


def set_leverage_safely():
    try:
        exchange.load_markets()

        # 不同持仓模式下，set_leverage 需要的 posSide 不同
        pos_mode = detect_pos_mode()
        if pos_mode == 'long_short_mode':
            # 双向模式下需分 long / short 两边分别设置
            for ps in ('long', 'short'):
                try:
                    exchange.set_leverage(
                        LEVERAGE, SYMBOL,
                        params={'marginMode': 'cross', 'posSide': ps}
                    )
                except Exception as e:
                    if 'leverage is the same' not in str(e).lower() and 'already' not in str(e).lower():
                        print(f"  ⚠️  设置 {ps} 边杠杆提示: {e}")
            print(f"[{datetime.now()}] 杠杆已设置为 {LEVERAGE}x (全仓 / {pos_mode})")
        else:
            exchange.set_leverage(LEVERAGE, SYMBOL, params={'marginMode': 'cross'})
            print(f"[{datetime.now()}] 杠杆已成功设置为 {LEVERAGE}x (全仓永续模式 / {pos_mode})")
    except Exception as e:
        print(f"【⚠️ 警告】设置杠杆或市场加载失败: {e}")
        print("请检查：1. 模拟盘 API Key 是否填错；2. 若持续报 50123 请重新保存 OKX 后台 API Key 交易权限。")

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
        # 2. 检查现有的 ETH 持仓状态（兼容双向/单向模式）
        if has_any_position():
            print("【条件跳过】当前存在 ETH 已成交持仓，跳过本次下单，等待下一次周期。")
            return

        # 3. 检查并撤销所有 ETH 未成交的挂单
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
        short_price = round(current_price - 0.01, 2)
        # 按 ETH 数量换算为合约张数（OKX ETH 永续 1 张 = 0.1 ETH）
        short_amount = eth_to_contracts(AMOUNT_ETH)

        print(f"[初始空单] 当前市价: {current_price} -> 计划以 {short_price} 挂限价做空 {AMOUNT_ETH} ETH (={short_amount} 张合约)")

        # 5. 挂出初始限价空单并附加限价止盈止损
        short_sl_trigger = round(short_price + 2, 2)
        short_tp_trigger = round(short_price - 2, 2)

        short_params = build_order_params(
            side='sell',
            position_side='short',
            sl_trigger=short_sl_trigger,
            tp_trigger=short_tp_trigger,
        )

        short_order = exchange.create_order(
            symbol=SYMBOL, type='limit', side='sell',
            amount=short_amount, price=short_price, params=short_params
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

        # 7. 开始监听是否触发了"止损"
        print("初始空单已成交。进入局部盘口监控，等待止损或止盈...")

        while True:
            ticker = exchange.fetch_ticker(SYMBOL)
            now_price = ticker['last']

            if now_price >= short_sl_trigger:
                print(f"【警报】检测到市场价 {now_price} 已触及空单止损线 {short_sl_trigger}！")

                time.sleep(1.5)

                # 8. 反向翻仓：下限价看涨做多
                long_price = round(short_sl_trigger + 0.01, 2)
                # 翻仓数量 = 初始空单张数 × 2
                long_amount = short_amount * 2

                long_tp_trigger = round(long_price + 2, 2)
                long_sl_trigger = round(long_price - 2, 2)

                long_params = build_order_params(
                    side='buy',
                    position_side='long',
                    sl_trigger=long_sl_trigger,
                    tp_trigger=long_tp_trigger,
                )

                print(f"[反向翻仓] 正在挂出限价做多单，价格: {long_price}, 数量: {long_amount} 张合约")
                try:
                    long_order = exchange.create_order(
                        symbol=SYMBOL, type='limit', side='buy',
                        amount=long_amount, price=long_price, params=long_params
                    )
                    print(f"成功翻仓做多！多单ID: {long_order['id']}，附带限价止损 {long_sl_trigger}，止盈 {long_tp_trigger}")
                except Exception as e:
                    print(f"翻仓下单失败: {e}")

                break

            if now_price <= short_tp_trigger:
                print(f"检测到价格 {now_price} 已触及止盈线 {short_tp_trigger}，空单正常止盈，无需翻仓。")
                break

            time.sleep(2)

    except Exception as e:
        print(f"执行过程中发生异常: {e}")
        if '50123' in str(e) or '50124' in str(e):
            print("  → 🔴 这是 OKX 后台权限问题！解决方法：")
            print("     1. 打开 OKX 模拟盘 API 管理页面")
            print("     2. 点击这个 API Key 的【编辑】按钮")
            print("     3. 先【取消勾选交易】→ 保存 → 再【重新勾选交易】→ 再保存")
            print("     4. 或者【删除后重新创建】一个新的 API Key（推荐）")
            print("     5. 交易市场建议选【全部】避免细粒度子权限遗漏")

# ================= 定时任务配置 =================
if __name__ == "__main__":
    # 解析命令行参数：-amount 指定下单 ETH 数量
    args = parse_args()
    AMOUNT_ETH = float(args.amount)
    print(f"启动配置：下单数量 = {AMOUNT_ETH} ETH")

    # 启动时先执行一次配置检查
    set_leverage_safely()

    scheduler = BlockingScheduler(timezone='Asia/Shanghai')
    scheduler.add_job(execute_strategy, 'cron', minute='0,15,30,45', second='0')

    print("安全增强版 OKX 策略脚本已启动...")
    try:
        scheduler.start()
    except (KeyboardInterrupt, SystemExit):
        print("策略已手动停止。")
