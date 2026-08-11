import os
import time
import argparse
import threading
import ccxt
from apscheduler.schedulers.blocking import BlockingScheduler
from datetime import datetime

# ================= 交易配置区域 =================
TRADE_MODE = os.environ.get('OKX_TRADE_MODE', 'demo')

API_KEY = os.environ.get('OKX_API_KEY', '')
SECRET_KEY = os.environ.get('OKX_SECRET_KEY', '')
PASSWORD = os.environ.get('OKX_PASSWORD', '')

if not API_KEY or not SECRET_KEY or not PASSWORD:
    print("【错误】未检测到 OKX API 密钥！")
    raise SystemExit(1)

PROXY_URL = os.environ.get('PROXY_URL', 'http://127.0.0.1:7897')

exchange = ccxt.okx({
    'apiKey': API_KEY,
    'secret': SECRET_KEY,
    'password': PASSWORD,
    'enableRateLimit': True,
    'timeout': 30000,
    'proxies': {'http': PROXY_URL, 'https': PROXY_URL} if PROXY_URL else None,
})

IS_DEMO = (TRADE_MODE == 'demo')
if IS_DEMO:
    exchange.set_sandbox_mode(True)
    exchange.headers['x-simulated-trading'] = '1'
    print(f"[交易模式] 模拟盘 (sandbox)")
else:
    print(f"[交易模式] 实盘 (live) ⚠️ 请确认风险")
exchange.options['defaultType'] = 'swap'

SYMBOL = 'ETH/USDT:USDT'
LEVERAGE = 50

# 策略参数
TP_USD = float(os.environ.get('TP_USD', '4.0'))      # 止盈 (ETH 美元价格差)
SL_USD = float(os.environ.get('SL_USD', '4.0'))      # 止损 (ETH 美元价格差)
LOT_REVERSE_RATIO = float(os.environ.get('LOT_REVERSE_RATIO', '2.0'))  # 反向翻仓手数倍率

last_order_time = 0
pos_mode_cache = None
AMOUNT_ETH = 10.0


def parse_args():
    parser = argparse.ArgumentParser(description='OKX ETH 永续策略 - 限价委托版')
    env_amount = os.environ.get('AMOUNT_ETH', '10.0')
    parser.add_argument('-amount', '--amount', dest='amount',
                        type=float, default=float(env_amount),
                        help='下单数量(ETH)，默认 10 ETH')
    parser.add_argument('-init-side', dest='init_side',
                        choices=['buy', 'sell'],
                        default=os.environ.get('OKX_INIT_SIDE', 'sell').lower(),
                        help='初始下单方向：buy（看涨）或 sell（看跌），默认 sell')
    parser.add_argument('-x', dest='mode',
                        choices=['demo', 'live'],
                        default=os.environ.get('OKX_TRADE_MODE', 'demo').lower(),
                        help='交易模式：demo 或 live')
    return parser.parse_args()


def eth_to_contracts(eth_amount):
    market = exchange.market(SYMBOL)
    contract_size = float(market.get('contractSize', 1)) or 0.1
    return eth_amount / contract_size


def get_position_details():
    """获取当前持仓详情（返回多头和空头张数）"""
    try:
        # 根据持仓模式获取持仓
        if detect_pos_mode() == 'long_short_mode':
            # 分离多头和空头
            all_positions = exchange.fetch_positions([SYMBOL])
            long_count = 0
            short_count = 0
            for pos in all_positions:
                if pos.get('symbol') == SYMBOL:
                    if pos.get('side') == 'long':
                        long_count += abs(float(pos.get('contracts', 0)))
                    elif pos.get('side') == 'short':
                        short_count += abs(float(pos.get('contracts', 0)))
            return {'long': long_count, 'short': short_count}
        else:
            # net_mode 模式下，正数多头，负数空头
            positions = exchange.fetch_positions([SYMBOL])
            long_count = 0
            short_count = 0
            for pos in positions:
                if pos.get('symbol') == SYMBOL:
                    contracts = float(pos.get('contracts', 0))
                    if contracts > 0:
                        long_count += contracts
                    else:
                        short_count += abs(contracts)
            return {'long': long_count, 'short': short_count}
    except Exception as e:
        print(f"⚠️ [获取持仓] 异常: {e}")
        return {'long': 0, 'short': 0}


def detect_pos_mode():
    global pos_mode_cache
    if pos_mode_cache is not None:
        return pos_mode_cache
    try:
        import requests, hmac, hashlib, base64
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
        }
        if IS_DEMO:
            hdrs['x-simulated-trading'] = '1'
        proxies = {'http': PROXY_URL, 'https': PROXY_URL} if PROXY_URL else None
        r = requests.get('https://www.okx.com' + path, headers=hdrs, proxies=proxies, timeout=15).json()
        if r.get('code') == '0' and r.get('data'):
            pos_mode_cache = r['data'][0].get('posMode', 'net_mode')
        else:
            pos_mode_cache = 'long_short_mode'
    except Exception:
        pos_mode_cache = 'long_short_mode'
    print(f"[持仓模式检测] 当前账户: {pos_mode_cache}")
    return pos_mode_cache


def check_has_active_trades():
    """检查是否有未成交挂单或已成交持仓"""
    try:
        positions = get_position_details()
        open_orders = exchange.fetch_open_orders(SYMBOL)

        has_positions = (positions['long'] > 0 or positions['short'] > 0)
        has_open_orders = len(open_orders) > 0

        if has_positions or has_open_orders:
            reasons = []
            if has_positions:
                reasons.append(f"存在持仓 (多头:{positions['long']}张 / 空头:{positions['short']}张)")
            if has_open_orders:
                reasons.append(f"存在未成交挂单 ({len(open_orders)}笔)")
            print(f"  ⚠️ 跳过下单：{', '.join(reasons)}，等待下一次定时检查。")
            return True

        return False
    except Exception as e:
        print(f"  ⚠️ 检查交易状态异常: {e}")
        return False


def place_limit_order(side, price, amount, tp_trigger=None, sl_trigger=None):
    """下单限价委托（可附带止盈止损）"""
    params = {}
    pos_mode = detect_pos_mode()

    if pos_mode == 'long_short_mode':
        params['posSide'] = side

    # 附带止盈止损
    if tp_trigger is not None or sl_trigger is not None:
        algo = {}
        if sl_trigger is not None:
            algo['slTriggerPx'] = str(round(sl_trigger, 2))
            algo['slOrdPx'] = str(round(sl_trigger, 2))

        if tp_trigger is not None:
            algo['tpTriggerPx'] = str(round(tp_trigger, 2))
            algo['tpOrdPx'] = str(round(tp_trigger, 2))

        if pos_mode == 'long_short_mode':
            algo['posSide'] = side

        params['attachAlgoOrds'] = [algo]

    try:
        order = exchange.create_order(
            symbol=SYMBOL,
            type='limit',
            side=side,
            amount=amount,
            price=str(price),
            params=params
        )
        print(f"  📋 限价委托提交成功 (ID: {order['id']}, 价格: {price})")
        return order
    except Exception as e:
        print(f"  ⚠️ 下单失败: {e}")
        return None


def execute_strategy():
    global last_order_time
    now_timestamp = time.time()

    print(f"\n====== 策略触发检查: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ======")

    if now_timestamp - last_order_time < 120:
        print(f"  ⚠️ 距离上一次下单未满 2 分钟，跳过本次执行。")
        return

    # 1. 检查是否有活跃交易
    if check_has_active_trades():
        return

    # 2. 获取最新价格并计算委托价格
    try:
        ticker = exchange.fetch_ticker(SYMBOL)
        current_price = ticker['last']

        init_side = args.init_side
        print(f"  💰 当前最新价: {current_price}")
        print(f"  🎯 初始方向: {init_side}")

        # 初始限价委托：买在当前价-0.01，卖在当前价+0.01
        if init_side == 'buy':
            entry_price = round(current_price - 0.01, 2)
            amount = eth_to_contracts(AMOUNT_ETH)

            # 设置止盈止损
            tp_trigger = round(entry_price + TP_USD, 2)
            sl_trigger = round(entry_price - SL_USD, 2)

            print(f"  📊 下单参数：看涨 | 价格: {entry_price} | 数量: {AMOUNT_ETH} ETH ({amount} 张)")
            print(f"  🎯 止盈: {tp_trigger} (价差 {TP_USD} USD) | 止损: {sl_trigger} (价差 {SL_USD} USD)")

            order = place_limit_order('buy', entry_price, amount, tp_trigger, sl_trigger)

            if order:
                last_order_time = time.time()
                print("  ✅ 初始开仓成功！等待成交。")

        else:  # sell
            entry_price = round(current_price + 0.01, 2)
            amount = eth_to_contracts(AMOUNT_ETH)

            # 设置止盈止损
            tp_trigger = round(entry_price - TP_USD, 2)
            sl_trigger = round(entry_price + SL_USD, 2)

            print(f"  📊 下单参数：看跌 | 价格: {entry_price} | 数量: {AMOUNT_ETH} ETH ({amount} 张)")
            print(f"  🎯 止盈: {tp_trigger} (价差 {TP_USD} USD) | 止损: {sl_trigger} (价差 {SL_USD} USD)")

            order = place_limit_order('sell', entry_price, amount, tp_trigger, sl_trigger)

            if order:
                last_order_time = time.time()
                print("  ✅ 初始开仓成功！等待成交。")

    except Exception as e:
        print(f"  ⚠️ 策略执行异常: {e}")


def fetch_pending_algo_orders():
    """
    获取所有未成交的条件单（止盈止损委托）
    """
    try:
        # OKX 使用 attachAlgoOrds 参数创建条件单
        # 这里获取所有已创建的条件单
        all_orders = exchange.fetch_orders(SYMBOL)
        algo_orders = []

        for order in all_orders:
            # 检查订单是否为条件单（有止盈止损参数）
            if order.get('info', {}).get('attachAlgoOrds'):
                algo_orders.append(order)

        return algo_orders
    except Exception as e:
        print(f"  ⚠️ [获取条件单] 异常: {e}")
        return []


def cancel_all_algo_orders():
    """
    撤销所有条件单
    """
    try:
        algo_orders = fetch_pending_algo_orders()
        cancel_count = 0

        for order in algo_orders:
            try:
                # 撤销条件单需要使用特定的 API
                # OKX 的 algoOrder API
                params = {}
                if detect_pos_mode() == 'long_short_mode':
                    params['ordType'] = 'conditional'
                    params['posSide'] = order.get('info', {}).get('attachAlgoOrds', [{}])[0].get('posSide', 'long')

                exchange.cancel_order(order['id'], SYMBOL, params)
                cancel_count += 1
            except Exception as e:
                print(f"      ⚠️ 撤销条件单失败: {order['id']} - {e}")

        print(f"      ✅ 成功撤销 {cancel_count} 笔条件单")
    except Exception as e:
        print(f"  ⚠️ [撤销条件单] 异常: {e}")


def monitor_and_cancel_all_orders():
    """
    监控平仓状态，延迟3秒后撤销所有未成交委托
    """
    try:
        positions = get_position_details()

        # 条件：多空都没有持仓
        if positions['long'] == 0.0 and positions['short'] == 0.0:
            open_orders = exchange.fetch_open_orders(SYMBOL)
            algo_orders = fetch_pending_algo_orders()

            total_orders = open_orders + algo_orders
            if total_orders:
                print(f"\n  🔍 [状态检测] 当前无活跃持仓，存在 {len(open_orders)} 笔普通挂单 + {len(algo_orders)} 笔条件单")
                print(f"  ⏳ [延迟处理] 触发 3 秒撤单倒计时...")
                time.sleep(3)

                # 再次确认没有新持仓
                double_check_pos = get_position_details()
                if double_check_pos['long'] == 0.0 and double_check_pos['short'] == 0.0:
                    # 撤销所有未成交委托
                    success_count = 0
                    failed_count = 0

                    if open_orders:
                        print(f"  🗑️  [撤销普通挂单] 正在撤销 {len(open_orders)} 笔普通挂单...")
                        for order in open_orders:
                            try:
                                exchange.cancel_order(order['id'], SYMBOL)
                                success_count += 1
                            except Exception as e:
                                failed_count += 1
                                print(f"      ⚠️ 撤销订单失败: {order['id']} - {e}")

                    if algo_orders:
                        print(f"  🗑️  [撤销条件单] 正在撤销 {len(algo_orders)} 笔条件单...")
                        cancel_all_algo_orders()
                        success_count += len(algo_orders)

                    print(f"  🎉 [清理完成] 成功撤销 {success_count} 笔，失败 {failed_count} 笔委托。")
    except Exception as e:
        import traceback
        print(f"  ⚠️ 监控异常: {e}")
        # traceback.print_exc()


def create_web_app():
    from flask import Flask, jsonify
    app = Flask(__name__)

    @app.route('/')
    @app.route('/health')
    def health():
        return jsonify({
            'status': 'running',
            'symbol': SYMBOL,
            'amount_eth': AMOUNT_ETH,
            'last_order_time': last_order_time,
        })

    return app


def set_leverage_safely():
    """安全设置杠杆倍数"""
    try:
        result = exchange.set_leverage(LEVERAGE, SYMBOL)
        if result['code'] == '0':
            print(f"✅ [杠杆设置] 成功设置 {LEVERAGE}x 杠杆")
        else:
            print(f"⚠️ [杠杆设置] 失败: {result.get('msg', 'Unknown error')}")
    except Exception as e:
        print(f"⚠️ [杠杆设置] 异常: {e}")


def run_scheduler_blocking():
    set_leverage_safely()
    scheduler = BlockingScheduler(timezone='Asia/Shanghai')

    # 核心策略：每 5 分钟检查一次（00分、05分...）
    scheduler.add_job(execute_strategy, 'cron', minute='0,5,10,15,20,25,30,35,40,45,50,55', second='0')

    # 监控：每 10 秒检查一次，延迟 3 秒后撤单
    scheduler.add_job(
        monitor_and_cancel_all_orders, 'interval', seconds=10,
        max_instances=2, coalesce=True, misfire_grace_time=120
    )

    scheduler.start()


if __name__ == "__main__":
    args = parse_args()
    AMOUNT_ETH = float(args.amount)
    print(f"配置启动：下单数量 = {AMOUNT_ETH} ETH，模式 = {args.mode}")
    print(f"策略参数：止盈 = {TP_USD} USD，止损 = {SL_USD} USD，翻仓倍数 = {LOT_REVERSE_RATIO}x")

    # 设置交易模式
    os.environ['OKX_TRADE_MODE'] = args.mode

    # 更新 API 密钥
    if args.mode == 'demo':
        os.environ['OKX_API_KEY'] = os.environ.get('OKX_DEMO_API_KEY', '')
        os.environ['OKX_SECRET_KEY'] = os.environ.get('OKX_DEMO_SECRET_KEY', '')
        os.environ['OKX_PASSWORD'] = os.environ.get('OKX_DEMO_PASSWORD', '')
    else:
        os.environ['OKX_API_KEY'] = os.environ.get('OKX_LIVE_API_KEY', '')
        os.environ['OKX_SECRET_KEY'] = os.environ.get('OKX_LIVE_SECRET_KEY', '')
        os.environ['OKX_PASSWORD'] = os.environ.get('OKX_LIVE_PASSWORD', '')

    render_mode = bool(os.environ.get('PORT') or os.environ.get('RENDER'))

    if render_mode:
        scheduler_thread = threading.Thread(target=run_scheduler_blocking, daemon=True)
        scheduler_thread.start()

        port = int(os.environ.get('PORT', 8080))
        app = create_web_app()
        print(f"OKX 策略已启动，Flask 保活服务监听 0.0.0.0:{port}")
        app.run(host='0.0.0.0', port=port, threaded=True)
    else:
        set_leverage_safely()
        scheduler = BlockingScheduler(timezone='Asia/Shanghai')

        # 两处启动区域同步更新任务注册
        scheduler.add_job(execute_strategy, 'cron', minute='0,5,10,15,20,25,30,35,40,45,50,55', second='0')
        scheduler.add_job(
            monitor_and_cancel_all_orders, 'interval', seconds=10,
            max_instances=1, coalesce=True, misfire_grace_time=60
        )

        print("OKX 策略脚本已启动...")
        try:
            scheduler.start()
        except (KeyboardInterrupt, SystemExit):
            print("策略已手动停止。")