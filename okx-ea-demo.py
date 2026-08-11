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
TP_USD = 4.0               # 止盈 (ETH 美元价格差)
SL_USD = 4.0               # 止损 (ETH 美元价格差)
LOT_REVERSE_RATIO = 2.0    # 反向翻仓手数倍率 (2倍)

last_order_time = 0
pos_mode_cache = None
AMOUNT_ETH = 10.0


def parse_args():
    parser = argparse.ArgumentParser(description='OKX ETH 永续策略 (MT5 同步逻辑版)')
    env_amount = os.environ.get('AMOUNT_ETH', '10.0')
    parser.add_argument('-amount', '--amount', dest='amount',
                        type=float, default=float(env_amount),
                        help='下单数量(ETH)，默认 10 ETH')
    parser.add_argument('-init-side', dest='init_side',
                        choices=['buy', 'sell'],
                        default=os.environ.get('OKX_INIT_SIDE', 'sell').lower(),
                        help='初始下单方向：buy（看涨）或 sell（看跌），默认 sell')
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


def cancel_all_algo_orders():
    """撤销所有残留策略/条件单的辅助函数"""
    try:
        inst_id = exchange.market_id(SYMBOL)
        algo_orders = fetch_pending_algo_orders()
        if algo_orders:
            print(f"【清理残留】检测到 {len(algo_orders)} 笔条件挂单，正在撤销...")
            cancel_params = [{'algoId': o['algoId'], 'instId': inst_id} for o in algo_orders]
            exchange.private_post_trade_cancel_algos(cancel_params)
            time.sleep(1) # 等待撤单生效
    except Exception as e:
        print(f"⚠️ 撤销条件挂单异常: {e}")


def fetch_pending_algo_orders():
    """查询该品种所有的未成交条件/策略委托单 (Algo Orders)

    说明：通过 attachAlgoOrds 附加的止盈止损单在 OKX 中属于 conditional 类型，
    因此只查询 conditional 即可，避免多次 API 调用加剧代理/限流压力。
    """
    algo_orders = []
    try:
        inst_id = exchange.market_id(SYMBOL)
        res = exchange.private_get_trade_orders_algo_pending({
            'instId': inst_id,
            'ordType': 'conditional'
        })
        if res.get('code') == '0' and res.get('data'):
            algo_orders.extend(res['data'])
    except Exception as e:
        print(f"  ⚠️ 查询条件挂单异常: {e}")
    return algo_orders


def monitor_and_clean_reverse_orders():
    """
    【新增高频监控逻辑】
    如果检测到当前没有多/空持仓，但是有未触发的反向条件单，
    说明初始单已经通过止盈触发平仓了，按照要求延迟 10 秒撤销条件单。
    """
    try:
        positions = get_position_details()
        # 条件：多空都没有持仓
        if positions['long'] == 0.0 and positions['short'] == 0.0:
            algo_orders = fetch_pending_algo_orders()
            if algo_orders:
                print(f" 🔍 [状态检测] 当前无活跃持仓，但存在 {len(algo_orders)} 笔翻仓条件单。")
                print(f" ⏳ [延迟处理] 触发 10 秒撤单倒计时...")
                time.sleep(10)
                
                # 再次确认这 10 秒内没有产生新持仓（排除刚好到了 5 分钟定时新开仓的极端重叠情况）
                double_check_pos = get_position_details()
                if double_check_pos['long'] == 0.0 and double_check_pos['short'] == 0.0:
                    cancel_all_algo_orders()
                    print(" 🎉 [清理完成] 残余翻仓单已成功被清空。")
    except Exception as e:
        print(f" ⚠️ 自动监控巡检异常: {e}")


def execute_strategy():
    global last_order_time
    now_timestamp = time.time()

    print(f"\n====== 策略触发检查: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ======")

    if now_timestamp - last_order_time < 120:
        print(f"【防重触发】距离上一次下单未满 2 分钟，跳过本次执行。")
        return

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
                reasons.append(f"存在普通未成交委托 ({len(open_orders)}笔)")
            print(f"【跳过下单】[{SYMBOL}] " + "，".join(reasons) + "。等待下一次定时检查。")
            return

        cancel_all_algo_orders()

        ticker = exchange.fetch_ticker(SYMBOL)
        bid_price = ticker['bid'] if ticker['bid'] else ticker['last']

        # 根据 -init-side 参数决定初始下单方向
        init_side = args.init_side
        if init_side == 'buy':
            # 看涨开仓：先开多单，再埋反向空单
            print(f"【全新开仓】当前 Bid 价: {bid_price} | 方向: 看涨 | 手数: {AMOUNT_ETH} ETH")

            # 1. 市价开多单
            long_price = round(bid_price, 2)
            long_amount = eth_to_contracts(AMOUNT_ETH)

            long_sl_trigger = round(long_price - SL_USD, 2)
            long_tp_trigger = round(long_price + TP_USD, 2)

            long_params = build_order_params(
                position_side='long',
                sl_trigger=long_sl_trigger,
                tp_trigger=long_tp_trigger,
                size=long_amount,
                is_close=False
            )

            long_order = exchange.create_order(
                symbol=SYMBOL, type='market', side='buy',
                amount=long_amount, price=None, params=long_params
            )
            print(f"🎉 初始多单提交成功 (ID: {long_order['id']})")
            last_order_time = time.time()

            # 2. 预埋 2 倍 Sell Stop 翻仓单
            short_price = long_tp_trigger  # 在 TP 处埋空单
            short_amount = long_amount * LOT_REVERSE_RATIO
            short_tp_trigger = round(short_price - TP_USD, 2)
            short_sl_trigger = round(short_price + SL_USD, 2)

            short_params = build_order_params(
                position_side='short',
                sl_trigger=short_sl_trigger,
                tp_trigger=short_tp_trigger,
                size=short_amount,
                is_close=False
            )
            short_params['stopPrice'] = str(short_price)
            short_params['orderPx'] = str(short_price)

            exchange.create_order(
                symbol=SYMBOL,
                type='stop-limit',
                side='sell',
                amount=short_amount,
                price=short_price,
                params=short_params
            )
            print("🎉 反向 2 倍 Sell Stop 条件挂单预埋成功！")

        else:  # 默认 sell 方向
            # 看跌开仓：先开空单，再埋反向多单
            print(f"【全新开仓】当前 Bid 价: {bid_price} | 方向: 看跌 | 手数: {AMOUNT_ETH} ETH ({long_amount} 张)")

            short_price = round(bid_price, 2)
            short_amount = eth_to_contracts(AMOUNT_ETH)

            short_sl_trigger = round(short_price + SL_USD, 2)
            short_tp_trigger = round(short_price - TP_USD, 2)

            short_params = build_order_params(
                position_side='short',
                sl_trigger=short_sl_trigger,
                tp_trigger=short_tp_trigger,
                size=short_amount,
                is_close=False
            )

            short_order = exchange.create_order(
                symbol=SYMBOL, type='market', side='sell',
                amount=short_amount, price=None, params=short_params
            )
            print(f"🎉 初始空单提交成功 (ID: {short_order['id']})")
            last_order_time = time.time()

            # 预埋 2 倍 Buy Stop 翻仓单
            long_price = short_sl_trigger
            long_amount = short_amount * LOT_REVERSE_RATIO
            long_tp_trigger = round(long_price + TP_USD, 2)
            long_sl_trigger = round(long_price - SL_USD, 2)

            long_params = build_order_params(
                position_side='long',
                sl_trigger=long_sl_trigger,
                tp_trigger=long_tp_trigger,
                size=long_amount,
                is_close=False
            )
            long_params['stopPrice'] = str(long_price)
            long_params['orderPx'] = str(long_price)

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
    
    # 核心策略：每 5 分钟执行一次检查开仓
    scheduler.add_job(execute_strategy, 'cron', minute='0,5,10,15,20,25,30,35,40,45,50,55', second='0')
    
    # 新增监控：每 30 秒巡检一次，负责在止盈后延迟 10s 撤回翻仓条件单
    scheduler.add_job(
        monitor_and_clean_reverse_orders, 'interval', seconds=30,
        max_instances=1, coalesce=True, misfire_grace_time=60
    )
    
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
        
        # 两处启动区域同步更新任务注册
        scheduler.add_job(execute_strategy, 'cron', minute='0,5,10,15,20,25,30,35,40,45,50,55', second='0')
        scheduler.add_job(
            monitor_and_clean_reverse_orders, 'interval', seconds=30,
            max_instances=1, coalesce=True, misfire_grace_time=60
        )
        
        print("OKX 策略脚本已启动...")
        try:
            scheduler.start()
        except (KeyboardInterrupt, SystemExit):
            print("策略已手动停止。")