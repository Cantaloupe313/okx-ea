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

# 策略参数（对齐 MT5 外部参数）
TP_USD = 4.0               # 止盈 (ETH 美元价格差，原 MT5 SL_USD/TP_USD)
SL_USD = 4.0               # 止损 (ETH 美元价格差)
LOT_REVERSE_RATIO = 2.0    # 反向翻仓手数倍率 (2倍)
CANCEL_DELAY_SEC = 20      # 撤单观察缓冲延迟(秒)

last_order_time = 0
pos_mode_cache = None
AMOUNT_ETH = 10.0


def parse_args():
    parser = argparse.ArgumentParser(description='OKX ETH 永续策略 (MT5 同步逻辑版)')
    env_amount = os.environ.get('AMOUNT_ETH', '10.0')
    parser.add_argument('-amount', '--amount', dest='amount',
                        type=float, default=float(env_amount),
                        help='下单数量(ETH)，默认 10 ETH')
    return parser.parse_args()


def eth_to_contracts(eth_amount):
    market = exchange.market(SYMBOL)
    contract_size = float(market.get('contractSize', 1)) or 0.1
    return eth_amount / contract_size


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


def build_order_params(position_side, sl_trigger=None, tp_trigger=None, size=None, is_close=False):
    """构建自带 OKX 原生止盈止损的附加参数"""
    params = {}
    pos_mode = detect_pos_mode()

    if pos_mode == 'long_short_mode':
        params['posSide'] = position_side

    if sl_trigger is not None or tp_trigger is not None:
        algo = {}
        if sl_trigger is not None:
            algo['slTriggerPx'] = str(round(sl_trigger, 2))
            algo['slOrdPx'] = str(round(sl_trigger, 2))

        if tp_trigger is not None:
            algo['tpTriggerPx'] = str(round(tp_trigger, 2))
            algo['tpOrdPx'] = str(round(tp_trigger, 2))

        if size is not None:
            algo['sz'] = str(int(size))

        if pos_mode == 'long_short_mode':
            algo['posSide'] = position_side
            if is_close:
                algo['reduceOnly'] = True

        params['attachAlgoOrds'] = [algo]

    return params


def set_leverage_safely():
    try:
        exchange.load_markets()
        pos_mode = detect_pos_mode()
        if pos_mode == 'long_short_mode':
            for ps in ('long', 'short'):
                try:
                    exchange.set_leverage(
                        LEVERAGE, SYMBOL,
                        params={'marginMode': 'cross', 'posSide': ps}
                    )
                except Exception as e:
                    if 'leverage is the same' not in str(e).lower() and 'already' not in str(e).lower():
                        print(f"  ⚠️ 设置 {ps} 边杠杆提示: {e}")
            print(f"[{datetime.now()}] 杠杆已设置为 {LEVERAGE}x (全仓 / {pos_mode})")
        else:
            exchange.set_leverage(LEVERAGE, SYMBOL, params={'marginMode': 'cross'})
            print(f"[{datetime.now()}] 杠杆已成功设置为 {LEVERAGE}x (全仓永续模式 / {pos_mode})")
    except Exception as e:
        print(f"【⚠️ 警告】设置杠杆或市场加载失败: {e}")


def get_position_details():
    """获取多空持仓张数详情"""
    positions = exchange.fetch_positions([SYMBOL])
    pos_mode = detect_pos_mode()
    
    result = {'long': 0.0, 'short': 0.0}
    for pos in positions:
        contracts = float(pos.get('contracts', 0) or 0)
        info_side = pos.get('info', {}).get('posSide', '').lower()
        ccxt_side = pos.get('side', '').lower()
        
        if 'long' in info_side or ccxt_side == 'long':
            result['long'] += contracts
        elif 'short' in info_side or ccxt_side == 'short':
            result['short'] += contracts
        elif pos_mode == 'net_mode' and contracts > 0:
            if ccxt_side == 'long':
                result['long'] += contracts
            else:
                result['short'] += contracts
    return result


def cancel_legacy_reverse_orders():
    """彻底对齐 MT5 CancelAssociatedPendingOrder：安全撤销遗留的反向挂单"""
    try:
        open_orders = exchange.fetch_open_orders(SYMBOL)
        positions = get_position_details()

        # 如果此时已经有了多头持仓（说明止损翻仓成功，挂单已转化为持仓）
        if positions['long'] > 0:
            print("【安全跳过】检测到反向多头已触发成交为【持仓】(止损翻仓成功)，程序不做任何平仓干预！")
            return

        # 否则撤销未成交的反向买入挂单（含常规限价单及条件触发单）
        print("开始清理遗留的未成交反向多头挂单...")
        for order in open_orders:
            if order['side'] == 'buy':
                try:
                    exchange.cancel_order(order['id'], SYMBOL)
                    print(f"【撤单成功】清理反向挂单: {order['id']}")
                except Exception as ce:
                    print(f"撤销挂单失败 {order['id']}: {ce}")

        # 清理策略/条件挂单 (Algo Orders)
        try:
            pos_mode = detect_pos_mode()
            params = {'ordType': 'conditional'}
            algo_orders = exchange.private_get_trade_orders_pending(params)
            if algo_orders.get('code') == '0':
                for a_ord in algo_orders.get('data', []):
                    if a_ord.get('side') == 'buy':
                        exchange.private_post_trade_cancel_algos({
                            'algoId': a_ord['algoId'],
                            'instId': exchange.market_id(SYMBOL)
                        })
                        print(f"【撤单成功】清理条件挂单 AlgoID: {a_ord['algoId']}")
        except Exception as e:
            print(f"检查/清理条件挂单提示: {e}")

    except Exception as e:
        print(f"清理反向单过程出现异常: {e}")


# ================= 核心策略执行 (对齐 MT5 OnTimer 流程) =================
def execute_strategy():
    global last_order_time
    now_timestamp = time.time()

    print(f"\n====== 策略触发检查: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ======")

    # 1. 防重复触发（对齐 MT5 RepeatGuardMin = 2 分钟）
    if now_timestamp - last_order_time < 120:
        print(f"【防重触发】距离上一次下单未满 2 分钟，跳过本次执行。")
        return

    try:
        open_orders = exchange.fetch_open_orders(SYMBOL)
        positions = get_position_details()
        
        # 2. 检查是否有同方向持仓或挂单 (对齐 MT5 CheckHasSameDirectionPending & CheckHasSameDirectionPosition)
        has_initial_side_pos = positions['short'] > 0
        has_initial_side_order = any(o['side'] == 'sell' for o in open_orders)
        
        if has_initial_side_pos or has_initial_side_order:
            print(f"【条件跳过】已存在空头持仓({positions['short']}张) 或 空头挂单，跳过下单。")
            return

        # 3. 观察期检查：无空头持仓，但仍残余反向买单（对应初始单止盈离场后的清理机制）
        has_reverse_side_order = any(o['side'] == 'buy' for o in open_orders)
        if positions['short'] == 0 and has_reverse_side_order:
            print(f"【监控通知】初始持仓已离场！进入 {CANCEL_DELAY_SEC} 秒观察期，防止与止损翻仓冲突...")
            time.sleep(CANCEL_DELAY_SEC)
            
            # 观察期结束后执行安全撤单
            cancel_legacy_reverse_orders()
            return

        # 4. 执行开仓（对应 MT5 ExecuteShortOrder）
        ticker = exchange.fetch_ticker(SYMBOL)
        bid_price = ticker['bid'] if ticker['bid'] else ticker['last']
        
        short_price = round(bid_price, 2)
        short_amount = eth_to_contracts(AMOUNT_ETH)

        # 设置初始空单的 TP / SL
        short_sl_trigger = round(short_price + SL_USD, 2)  # 止损价
        short_tp_trigger = round(short_price - TP_USD, 2)  # 止盈价

        print(f"【执行做空】当前 Bid 价: {short_price} | 手数: {AMOUNT_ETH} ETH ({short_amount} 张)")
        print(f"           止损价: {short_sl_trigger} | 止盈价: {short_tp_trigger}")

        short_params = build_order_params(
            position_side='short',
            sl_trigger=short_sl_trigger,
            tp_trigger=short_tp_trigger,
            size=short_amount,
            is_close=False
        )

        # 发起初始市价/限价做空单
        short_order = exchange.create_order(
            symbol=SYMBOL, type='market', side='sell',
            amount=short_amount, price=None, params=short_params
        )
        print(f"🎉 初始空单提交成功 (ID: {short_order['id']})")
        last_order_time = time.time()

        # 5. 【关键点对齐】立即同步挂出 2 倍反向 Buy Stop 翻仓单 (对应 MT5 BuyStop 挂单)
        long_price = short_sl_trigger                         # 触及空单止损价时挂单翻仓
        long_amount = short_amount * LOT_REVERSE_RATIO        # 2 倍翻仓数量
        
        long_tp_trigger = round(long_price + TP_USD, 2)       # 反向多单止盈
        long_sl_trigger = round(long_price - SL_USD, 2)       # 反向多单止损

        print(f"【预埋翻仓单】同步提交 2 倍 Buy Stop 预埋挂单...")
        print(f"             触发价(空单止损价): {long_price} | 多单止损: {long_sl_trigger} | 多单止盈: {long_tp_trigger}")

        long_params = build_order_params(
            position_side='long',
            sl_trigger=long_sl_trigger,
            tp_trigger=long_tp_trigger,
            size=long_amount,
            is_close=False
        )
        
        # OKX 预埋触发单 (stop-limit / conditional)
        long_params['stopPrice'] = str(long_price)
        long_params['orderPx'] = str(long_price)  # 市价触发可填 -1

        exchange.create_order(
            symbol=SYMBOL,
            type='stop-limit',
            side='buy',
            amount=long_amount,
            price=long_price,
            params=long_params
        )
        print("🎉 反向 2 倍 Buy Stop 条件挂单预埋成功！")

    except Exception as e:
        print(f"执行异常: {e}")


# ================= Web 服务（Render 保活） =================
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


def run_scheduler_blocking():
    set_leverage_safely()
    scheduler = BlockingScheduler(timezone='Asia/Shanghai')
    scheduler.add_job(execute_strategy, 'cron', minute='0,15,30,45', second='0')
    scheduler.start()


if __name__ == "__main__":
    args = parse_args()
    AMOUNT_ETH = float(args.amount)
    print(f"配置启动：下单数量 = {AMOUNT_ETH} ETH")

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
        scheduler.add_job(execute_strategy, 'cron', minute='0,15,30,45', second='0')
        print("OKX 策略脚本已启动...")
        try:
            scheduler.start()
        except (KeyboardInterrupt, SystemExit):
            print("策略已手动停止。")