import os
import sys
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
TP_USD = float(os.environ.get('TP_USD', '4.0'))      # 初始单止盈 (ETH 美元价格差)
SL_USD = float(os.environ.get('SL_USD', '4.0'))      # 初始单止损 (ETH 美元价格差)
REVERSE_TP_USD = TP_USD  # 反向单止盈价差（使用与初始单相同的TP_USD）
REVERSE_SL_USD = SL_USD  # 反向单止损价差（使用与初始单相同的SL_USD）
LOT_REVERSE_RATIO = float(os.environ.get('LOT_REVERSE_RATIO', '2.0'))  # 反向翻仓手数倍率

last_order_time = 0
last_order_id = None  # 记录最后下单的ID
last_order_params = {}  # 记录最后下单的参数（价格、方向、止损价等）
pos_mode_cache = None
AMOUNT_ETH = 10.0
target_net_profit = float(os.environ.get('TARGET_NETPROFIT', '0.0'))
has_achieved_target = False
has_reverse_order = False  # 标记是否已开反向单
monitor_thread_running = True  # 控制监控线程的运行/停止


def get_account_info():
    """获取账户信息（总权益、余额、盈亏）"""
    try:
        account = exchange.fetch_balance()
        balance = float(account.get('total', {}).get('USDT', 0))
        unrealized_pnl = 0.0

        # 使用 'info' 字段中的 totalUnrealizedPL 来获取未实现盈亏
        if 'info' in account and 'data' in account['info']:
            for acc in account['info']['data']:
                if acc.get('state') == 'live':
                    unrealized_pnl = float(acc.get('totalUnrealizedPL', 0))
                    break

        return {
            'balance': balance,
            'unrealized_pnl': unrealized_pnl,
            'achieved': balance >= target_net_profit,
        }
    except Exception as e:
        print(f"  ⚠️ [获取账户信息] 异常: {e}")
        return {'balance': 0, 'unrealized_pnl': 0, 'achieved': False}


def close_all_positions():
    """平仓所有持仓"""
    try:
        positions = get_position_details()
        close_count = 0

        if positions['long'] > 0 or positions['short'] > 0:
            print(f"\n  🚪 [平仓操作] 当前有持仓需要平仓:")
            print(f"     多头: {positions['long']} 张")
            print(f"     空头: {positions['short']} 张")

            # 平多仓
            if positions['long'] > 0:
                try:
                    market = exchange.market(SYMBOL)
                    price = exchange.fetch_ticker(SYMBOL)['last']
                    amount = positions['long']

                    # 使用市价单平仓
                    params = {}
                    pos_mode = detect_pos_mode()
                    if pos_mode == 'long_short_mode':
                        params['posSide'] = 'long'

                    order = exchange.create_order(
                        symbol=SYMBOL,
                        type='market',
                        side='sell',
                        amount=amount,
                        params=params
                    )
                    close_count += 1
                    print(f"     ✅ 平多仓成功 (ID: {order['id']})")
                except Exception as e:
                    print(f"     ❌ 平多仓失败: {e}")

            # 平空仓
            if positions['short'] > 0:
                try:
                    market = exchange.market(SYMBOL)
                    price = exchange.fetch_ticker(SYMBOL)['last']
                    amount = positions['short']

                    params = {}
                    pos_mode = detect_pos_mode()
                    if pos_mode == 'long_short_mode':
                        params['posSide'] = 'short'

                    order = exchange.create_order(
                        symbol=SYMBOL,
                        type='market',
                        side='buy',
                        amount=amount,
                        params=params
                    )
                    close_count += 1
                    print(f"     ✅ 平空仓成功 (ID: {order['id']})")
                except Exception as e:
                    print(f"     ❌ 平空仓失败: {e}")

            # 等待 3 秒后再次检查
            print(f"  ⏳ [等待] 平仓操作延迟 3 秒后确认...")
            time.sleep(3)

            # 再次获取持仓确认
            final_positions = get_position_details()
            if final_positions['long'] == 0 and final_positions['short'] == 0:
                print(f"  ✅ [平仓完成] 所有持仓已平仓")
                return True
            else:
                print(f"  ⚠️ [平仓异常] 仍有持仓: 多头 {final_positions['long']} 空头 {final_positions['short']}")
                return False
        else:
            print(f"  ℹ️  [平仓操作] 当前无持仓")
            return True
    except Exception as e:
        print(f"  ⚠️ [平仓操作] 异常: {e}")
        return False


def cancel_all_orders():
    """撤单所有未成交委托"""
    global last_order_id, has_reverse_order
    last_order_id = None
    has_reverse_order = False
    try:
        print(f"\n  🗑️  [撤单操作] 开始撤单...")

        # 获取所有挂单
        open_orders = exchange.fetch_open_orders(SYMBOL)
        algo_orders = fetch_pending_algo_orders()
        total_orders = open_orders + algo_orders

        if not total_orders:
            print(f"  ℹ️  [撤单完成] 无未成交委托")
            return True

        cancel_count = 0
        failed_count = 0

        # 撤普通挂单
        for order in open_orders:
            try:
                params = {}
                pos_mode = detect_pos_mode()
                if pos_mode == 'long_short_mode':
                    # 获取订单信息以确定 posSide
                    order_info = exchange.fetch_order(order['id'], SYMBOL)
                    if order_info.get('info', {}).get('posSide'):
                        params['posSide'] = order_info['info']['posSide']

                exchange.cancel_order(order['id'], SYMBOL, params)
                cancel_count += 1
            except Exception as e:
                failed_count += 1

        # 撤条件单
        for order in algo_orders:
            try:
                params = {}
                if order.get('is_trigger_algo'):
                    params['trigger'] = True
                exchange.cancel_order(order['id'], SYMBOL, params)
                cancel_count += 1
            except Exception as e:
                failed_count += 1

        print(f"  ✅ [撤单完成] 成功撤单 {cancel_count} 笔，失败 {failed_count} 笔")
        return True
    except Exception as e:
        print(f"  ⚠️ [撤单操作] 异常: {e}")
        return False


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
    """获取当前持仓详情（返回多头和空头张数），带重试和更稳健的参数"""
    max_retries = 3
    for attempt in range(max_retries):
        try:
            # 明确指定 instType，避免部分环境下解析问题
            params = {'instType': 'SWAP'}
            
            if detect_pos_mode() == 'long_short_mode':
                all_positions = exchange.fetch_positions([SYMBOL], params=params)
                long_count = 0.0
                short_count = 0.0
                for pos in all_positions:
                    if pos.get('symbol') == SYMBOL:
                        contracts = abs(float(pos.get('contracts') or 0))
                        if pos.get('side') == 'long':
                            long_count += contracts
                        elif pos.get('side') == 'short':
                            short_count += contracts
                return {'long': long_count, 'short': short_count}
            else:
                # net_mode
                positions = exchange.fetch_positions([SYMBOL], params=params)
                long_count = 0.0
                short_count = 0.0
                for pos in positions:
                    if pos.get('symbol') == SYMBOL:
                        contracts = float(pos.get('contracts') or 0)
                        if contracts > 0:
                            long_count += contracts
                        elif contracts < 0:
                            short_count += abs(contracts)
                return {'long': long_count, 'short': short_count}

        except Exception as e:
            error_msg = str(e)
            print(f"⚠️ [获取持仓] 第 {attempt + 1}/{max_retries} 次异常: {error_msg}")
            
            # 如果是最后一次还失败，打印更详细信息
            if attempt == max_retries - 1:
                import traceback
                traceback.print_exc()
                return {'long': 0, 'short': 0}
            
            # 短暂等待后重试
            time.sleep(1.5)
    
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
    """检查是否有未成交挂单或已成交持仓（包括反向单）"""
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
        # 在 long_short_mode 下，posSide 必须使用 'long' 或 'short'，而不是 'buy'/'sell'
        params['posSide'] = 'long' if side == 'buy' else 'short'

    # 附带止盈止损
    if tp_trigger is not None or sl_trigger is not None:
        algo = {}
        if sl_trigger is not None:
            algo['slTriggerPx'] = str(round(sl_trigger, 2))
            algo['slOrdPx'] = str(round(sl_trigger, 2))

        if tp_trigger is not None:
            algo['tpTriggerPx'] = str(round(tp_trigger, 2))
            algo['tpOrdPx'] = str(round(tp_trigger, 2))

        # 注意：条件单不需要设置 posSide，OKX API 不支持
        # posSide 只用于主订单，条件单会自动跟随主订单的方向

        params['attachAlgoOrds'] = [algo]

    try:
        # 调试信息
        print(f"    📝 下单参数: side={side}, price={price}, amount={amount}, posSide={params.get('posSide')}")
        if 'attachAlgoOrds' in params:
            algo = params['attachAlgoOrds'][0]
            print(f"    📝 条件单参数: slTriggerPx={algo.get('slTriggerPx')}, slOrdPx={algo.get('slOrdPx')}")
            print(f"    📝 tpTriggerPx={algo.get('tpTriggerPx')}, tpOrdPx={algo.get('tpOrdPx')}")

        order = exchange.create_order(
            symbol=SYMBOL,
            type='limit',
            side=side,
            amount=amount,
            price=str(price),
            params=params
        )
        print(f"  📋 限价委托提交成功 (ID: {order['id']}, 价格: {price})")

        # 记录订单参数，用于后续反向开仓
        global last_order_id, last_order_params, has_reverse_order
        last_order_id = order['id']
        last_order_params = {
            'side': side,
            'price': price,
            'tp_trigger': tp_trigger,
            'sl_trigger': sl_trigger
        }
        has_reverse_order = False

        return order
    except Exception as e:
        print(f"  ⚠️ 下单失败: {e}")
        import traceback
        traceback.print_exc()
        return None


def monitor_initial_order_filled():
    """
    实时监控初始单是否成交（后台线程调用）
    成交后立即用止损价挂反向翻仓单
    """
    global last_order_id, has_reverse_order, monitor_thread_running

    if last_order_id is None or has_reverse_order:
        return False

    try:
        # 获取订单状态
        order = exchange.fetch_order(last_order_id, SYMBOL)
        status = order.get('status')

        # 检查订单是否已成交
        if status == 'closed':
            print(f"\n  ✅ [检测] 初始单已成交！")
            print(f"     订单ID: {last_order_id}")
            
            # 尝试从交易所订单详情获取真实的止损价和止盈价，防止本地缓存丢失或不准确
            sl_trigger = None
            tp_trigger = None
            info = order.get('info', {})
            algos = info.get('attachAlgoOrds', [])

            # 兼容 attachAlgoOrds 是单个对象或列表的情况
            algo_list = [algos] if not isinstance(algos, list) else algos

            for algo in algo_list:
                if isinstance(algo, dict):
                    sl_val = algo.get('slTriggerPx')
                    tp_val = algo.get('tpTriggerPx')
                    if sl_val:
                        sl_trigger = float(sl_val)
                        print(f"     [交易所数据] 成功获取初始单附加止损价: {sl_trigger}")
                    if tp_val:
                        tp_trigger = float(tp_val)
                        print(f"     [交易所数据] 成功获取初始单附加止盈价: {tp_trigger}")

            # 兜底1：如果交易所数据没有，则使用本地参数
            if sl_trigger is None:
                sl_trigger = last_order_params.get('sl_trigger')
                if sl_trigger:
                    print(f"     [本地缓存] 成功获取初始单附加止损价: {sl_trigger}")

            # 兜底2：如果止盈价没有，使用本地缓存
            if tp_trigger is None:
                tp_trigger = last_order_params.get('tp_trigger')
                if tp_trigger:
                    print(f"     [本地缓存] 成功获取初始单附加止盈价: {tp_trigger}")

            # 兜底3：如果都没有，根据初始单实际成交方向和成交均价/委托价计算一个默认止损价和止盈价
            if sl_trigger is None:
                side = order.get('side') or last_order_params.get('side')
                filled_price = order.get('average') or order.get('price') or last_order_params.get('price')
                if filled_price and side:
                    filled_price = float(filled_price)
                    # 初始单止损价：卖单是委托价+SL_USD，买单是委托价-SL_USD
                    sl_trigger = round(filled_price + SL_USD if side == 'sell' else filled_price - SL_USD, 2)
                    # 初始单止盈价：卖单是委托价-TP_USD，买单是委托价+TP_USD
                    tp_trigger = round(filled_price - TP_USD if side == 'sell' else filled_price + TP_USD, 2)
                    print(f"     [兜底计算] 使用成交均价计算止损价: {sl_trigger}, 止盈价: {tp_trigger}")

            if sl_trigger is None:
                print(f"  ❌ [反向开仓] 无法获取初始单的止损价，取消反向开仓")
                last_order_id = None
                return False

            print(f"     初始方向: {order.get('side') or last_order_params.get('side')}")
            print(f"     初始止损价: {sl_trigger}")
            print(f"  🔄 [反向开仓] 创建计划委托（条件单）...")

            # 立即创建计划委托（条件单）
            # 计划委托会在价格达到触发价时自动转换为限价单
            init_side = order.get('side') or last_order_params.get('side')
            reverse_side = 'buy' if init_side == 'sell' else 'sell'
            reverse_amount = eth_to_contracts(AMOUNT_ETH * LOT_REVERSE_RATIO)

            # 反向单开仓价等于初始单止损价
            reverse_price = sl_trigger

            # 反向单止盈价：反向开仓价 + TP_USD
            # 反向单止损价：反向开仓价 - SL_USD
            reverse_tp = round(reverse_price + TP_USD, 2)
            reverse_sl = round(reverse_price - REVERSE_SL_USD, 2)

            print(f"     反向方向: {reverse_side}")
            print(f"     反向数量: {AMOUNT_ETH * LOT_REVERSE_RATIO} ETH ({reverse_amount} 张)")
            print(f"     触发价: {sl_trigger} (初始单止损价)")
            print(f"     反向止盈: {reverse_tp} (价差 +{TP_USD} USD) | 止损: {reverse_sl} (价差 -{SL_USD} USD)")

            try:
                # 使用 OKX 的算法订单（algo order）创建带有止盈止损的触发单
                # 根据 OKX API，trigger 订单必须通过 attachAlgoOrds 附带止盈止损
                pos_mode = detect_pos_mode()
                algo_params = {
                    'tdMode': 'cross',
                    'triggerPrice': str(sl_trigger),      # 触发价
                    'orderPrice': str(sl_trigger),        # 触发后下单价格（限价）
                    # 关键：用 attachAlgoOrds 附带止盈止损（与初始限价单一致）
                    'attachAlgoOrds': [{
                        'tpTriggerPx': str(reverse_tp),
                        'tpOrdPx': str(reverse_tp),       # 限价止盈；若要市价可改为 '-1'
                        'slTriggerPx': str(reverse_sl),
                        'slOrdPx': str(reverse_sl),       # 限价止损；若要市价可改为 '-1'
                    }],
                }

                # 在 long_short_mode 下，posSide 必须指定
                if pos_mode == 'long_short_mode':
                    algo_params['posSide'] = 'long' if reverse_side == 'buy' else 'short'

                reverse_order = exchange.create_order(
                    symbol=SYMBOL,
                    type='trigger',
                    side=reverse_side,
                    amount=reverse_amount,
                    price=str(sl_trigger),
                    params=algo_params
                )

                if reverse_order:
                    print(f"  📋 算法订单创建成功 (ID: {reverse_order['id']})")
                    has_reverse_order = True
                    print(f"  ✅ [反向开仓] 算法订单已设置")
                    print(f"     💡 当价格达到 {sl_trigger} 时，将自动触发反向开仓")
                    print(f"     💡 算法订单已包含止盈: {reverse_tp} 和止损: {reverse_sl}")
                else:
                    print(f"  ⚠️ [反向开仓] 返回 None")
            except Exception as e:
                print(f"  ⚠️ [反向开仓] 触发单创建失败: {e}")
                import traceback
                traceback.print_exc()

            return True
        elif status in ['canceled', 'rejected', 'expired']:
            print(f"  ⚠️ [监控] 初始单已失效 (状态: {status})，停止监控该订单。")
            last_order_id = None
            return False
        else:
            # 订单未成交，继续监控
            return False
    except ccxt.OrderNotFound as e:
        print(f"  ⚠️ [监控] 订单 {last_order_id} 未找到，停止监控: {e}")
        last_order_id = None
    except Exception as e:
        # 不打印网络超时等普通异常，避免日志过多
        pass
    return False


def restore_state_from_exchange():
    """在脚本启动或状态丢失时，从交易所恢复初始单的监控状态"""
    global last_order_id, last_order_params, has_reverse_order
    try:
        # 如果已经有监控的订单，不需要恢复
        if last_order_id is not None:
            return

        # 1. 检查是否有持仓。如果当前有持仓，可能已经过了初始单监控阶段
        positions = get_position_details()
        has_positions = (positions['long'] > 0 or positions['short'] > 0)
        if has_positions:
            return

        # 2. 获取所有未成交挂单
        open_orders = exchange.fetch_open_orders(SYMBOL)
        if not open_orders:
            return

        # 寻找我们的初始限价单
        target_amount = eth_to_contracts(AMOUNT_ETH)
        initial_order_info = None

        for order in open_orders:
            # 优先匹配下单数量
            order_contracts = float(order.get('contracts', 0) or 0)
            # 数量差非常小则认为匹配（容忍浮点数误差）
            if abs(order_contracts - target_amount) < 0.001:
                # 获取订单的完整详情以获取可能存在的附带条件单
                try:
                    full_order = exchange.fetch_order(order['id'], SYMBOL)
                    info = full_order.get('info', {})
                    if info.get('attachAlgoOrds'):
                        initial_order_info = full_order
                        break
                except Exception:
                    pass

        # 兜底：如果没匹配到数量，但只有一个挂单，尝试对其获取详情
        if not initial_order_info and len(open_orders) == 1:
            try:
                full_order = exchange.fetch_order(open_orders[0]['id'], SYMBOL)
                info = full_order.get('info', {})
                if info.get('attachAlgoOrds'):
                    initial_order_info = full_order
            except Exception:
                pass

        if initial_order_info:
            # 找到了挂单中的初始单，恢复监控状态
            last_order_id = initial_order_info['id']
            
            # 解析附加条件单中的止损和止盈
            sl_trigger = None
            tp_trigger = None
            algos = initial_order_info.get('info', {}).get('attachAlgoOrds', [])
            if isinstance(algos, list) and len(algos) > 0:
                sl_val = algos[0].get('slTriggerPx')
                tp_val = algos[0].get('tpTriggerPx')
                if sl_val: sl_trigger = float(sl_val)
                if tp_val: tp_trigger = float(tp_val)

            last_order_params = {
                'side': initial_order_info['side'],
                'price': float(initial_order_info['price']) if initial_order_info.get('price') else None,
                'tp_trigger': tp_trigger,
                'sl_trigger': sl_trigger
            }
            has_reverse_order = False
            print(f"  🔍 [状态恢复] 成功从交易所恢复初始单监控: ID={last_order_id}, 方向={last_order_params['side']}, 止损={sl_trigger}, 止盈={tp_trigger}")

    except Exception as e:
        print(f"  ⚠️ [恢复状态] 异常: {e}")


def execute_strategy():
    global last_order_time, has_achieved_target

    # 尝试从交易所恢复监控状态
    restore_state_from_exchange()

    now_timestamp = time.time()

    print(f"\n====== 策略触发检查: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ======")

    # 0. 检查是否已达到目标净值
    account_info = get_account_info()
    if account_info['achieved']:
        if not has_achieved_target:
            has_achieved_target = True

            print(f"\n{'='*60}")
            print(f"🎉 恭喜！已达到目标净值！")
            print(f"{'='*60}")
            print(f"📊 账户信息:")
            print(f"   总余额: {account_info['balance']:.2f} USDT")
            print(f"   目标净值: {target_net_profit:.2f} USDT")
            print(f"{'='*60}")

            # 停止监控线程
            monitor_thread_running = False
            print(f"\n  🛑 [监控线程] 正在停止监控线程...")

            # 1. 平仓所有持仓
            print(f"\n📋 步骤 1/3: 平仓所有持仓...")
            close_all_positions()

            # 2. 撤单所有未成交委托（仅在达到目标时）
            print(f"\n📋 步骤 2/3: 撤单所有未成交委托...")
            cancel_all_orders()

            # 3. 终止定时器（清空所有定时任务）
            print(f"\n📋 步骤 3/3: 终止定时器...")
            print(f"{'='*60}")
            print(f"🏁 策略已安全终止！")
            print(f"{'='*60}")
            print(f"✅ 任务完成清单:")
            print(f"   1. ✅ 所有持仓已平仓")
            print(f"   2. ✅ 所有委托已撤销")
            print(f"   3. ✅ 定时器已停止，不再执行新任务")
            print(f"   4. ✅ 监控线程已停止")
            print(f"{'='*60}")
            print(f"💡 如需重新启动策略，请:")
            print(f"   - 修改 .env 中的 TARGET_NETPROFIT 值")
            print(f"   - 重启脚本")
            print(f"{'='*60}\n")

            # 退出程序
            sys.exit(0)
        else:
            print(f"  📊 当前净值: {account_info['balance']:.2f} USDT / 目标: {target_net_profit:.2f} USDT")
            if account_info['balance'] > 0:
                progress = (account_info['balance'] / target_net_profit) * 100
                print(f"  📈 进度: {progress:.1f}%")
            else:
                print(f"  📉 当前余额为 0，继续等待")
            print(f"  ⏸️  策略已终止，定时器已停止")
            return

    # 显示当前净值进度
    print(f"  📊 当前净值: {account_info['balance']:.2f} USDT / 目标: {target_net_profit:.2f} USDT")
    if account_info['balance'] > 0:
        progress = (account_info['balance'] / target_net_profit) * 100
        print(f"  📈 进度: {progress:.1f}%")
    else:
        print(f"  📉 当前余额为 0，继续等待")

    if now_timestamp - last_order_time < 120:
        print(f"  ⚠️ 距离上一次下单未满 2 分钟，跳过本次执行。")
        print(f"  💡 [反向开仓] 后台监控线程将持续检查，初始单成交后将立即开反向单")
        return

    # 1. 检查是否有活跃交易（持仓或未成交委托）
    if check_has_active_trades():
        return

    # 2. 获取最新价格并计算委托价格
    try:
        ticker = exchange.fetch_ticker(SYMBOL)
        current_price = float(ticker['last'])

        init_side = args.init_side
        print(f"  💰 当前最新价: {current_price}")
        print(f"  🎯 初始方向: {init_side}")

        # 初始限价委托：买在当前价-0.01，卖在当前价+0.01
        if init_side == 'buy':
            raw_price = current_price - 0.01
            entry_price = float(exchange.price_to_precision(SYMBOL, raw_price))
            amount = eth_to_contracts(AMOUNT_ETH)

            # 设置止盈止损
            tp_trigger = float(exchange.price_to_precision(SYMBOL, entry_price + TP_USD))
            sl_trigger = float(exchange.price_to_precision(SYMBOL, entry_price - SL_USD))

            print(f"  📊 下单参数：看涨 | 价格: {entry_price} | 数量: {AMOUNT_ETH} ETH ({amount} 张)")
            print(f"  🎯 止盈: {tp_trigger} (价差 {TP_USD} USD) | 止损: {sl_trigger} (价差 {SL_USD} USD)")

            order = place_limit_order('buy', entry_price, amount, tp_trigger, sl_trigger)

            if order:
                last_order_time = time.time()
                print("  ✅ 初始开仓成功！等待成交。")
                print(f"     [DEBUG] 初始单设置 - 开仓价: {entry_price}, 止盈: {tp_trigger}, 止损: {sl_trigger}")

        else:  # sell
            raw_price = current_price + 0.01
            entry_price = float(exchange.price_to_precision(SYMBOL, raw_price))
            amount = eth_to_contracts(AMOUNT_ETH)

            # 设置止盈止损
            tp_trigger = float(exchange.price_to_precision(SYMBOL, entry_price - TP_USD))
            sl_trigger = float(exchange.price_to_precision(SYMBOL, entry_price + SL_USD))

            print(f"  📊 下单参数：看跌 | 价格: {entry_price} | 数量: {AMOUNT_ETH} ETH ({amount} 张)")
            print(f"  🎯 止盈: {tp_trigger} (价差 {TP_USD} USD) | 止损: {sl_trigger} (价差 {SL_USD} USD)")

            order = place_limit_order('sell', entry_price, amount, tp_trigger, sl_trigger)

            if order:
                last_order_time = time.time()
                print("  ✅ 初始开仓成功！等待成交。")
                print(f"     [DEBUG] 初始单设置 - 开仓价: {entry_price}, 止盈: {tp_trigger}, 止损: {sl_trigger}")

    except Exception as e:
        print(f"  ⚠️ 策略执行异常: {e}")


def fetch_pending_algo_orders():
    """
    获取所有未成交的条件单（包含附带止盈止损的普通单，以及独立的条件单/触发单）
    """
    algo_orders = []
    try:
        # 1. 获取所有普通挂单，并筛选出其中附带 attachAlgoOrds 的挂单
        open_orders = exchange.fetch_open_orders(SYMBOL)
        for order in open_orders:
            if order.get('info', {}).get('attachAlgoOrds'):
                algo_orders.append(order)
    except Exception as e:
        print(f"  ⚠️ [获取附带条件单] 异常: {e}")

    try:
        # 2. 获取 OKX 独立的触发单/条件单 (trigger: True)
        params = {'trigger': True}
        open_algo_orders = exchange.fetch_open_orders(SYMBOL, params=params)
        for order in open_algo_orders:
            order['is_trigger_algo'] = True
            algo_orders.append(order)
    except Exception as e:
        print(f"  ⚠️ [获取独立条件单] 异常: {e}")

    return algo_orders


def cancel_all_algo_orders():
    """
    撤销所有条件单
    """
    try:
        algo_orders = fetch_pending_algo_orders()
        cancel_count = 0

        for order in algo_orders:
            try:
                params = {}
                if order.get('is_trigger_algo'):
                    params['trigger'] = True
                exchange.cancel_order(order['id'], SYMBOL, params)
                cancel_count += 1
            except Exception as e:
                print(f"      ⚠️ 撤销条件单失败: {order['id']} - {e}")

        print(f"      ✅ 成功撤销 {cancel_count} 笔条件单")
    except Exception as e:
        print(f"  ⚠️ [撤销条件单] 异常: {e}")


def monitor_and_cancel_all_orders():
    """
    监控平仓状态，延迟10秒后撤销所有未成交委托
    """
    global has_reverse_order
    try:
        positions = get_position_details()

        # 条件：必须已经下了反向单，且多空都没有持仓才进行自动清理（避免误撤销处于等待成交状态的初始单）
        if has_reverse_order and positions['long'] == 0.0 and positions['short'] == 0.0:
            open_orders = exchange.fetch_open_orders(SYMBOL)
            algo_orders = fetch_pending_algo_orders()

            total_orders = open_orders + algo_orders
            if total_orders:
                print(f"\n  🔍 [状态检测] 当前无活跃持仓，存在 {len(open_orders)} 笔普通挂单 + {len(algo_orders)} 笔条件单")
                print(f"  ⏳ [延迟处理] 触发 10 秒撤单倒计时...")
                time.sleep(10)

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

                    global last_order_id
                    last_order_id = None
                    has_reverse_order = False

                    print(f"  🎉 [清理完成] 成功撤销 {success_count} 笔，失败 {failed_count} 笔委托。")
    except Exception as e:
        import traceback
        print(f"  ⚠️ 监控异常: {e}")
        # traceback.print_exc()


def monitor_order_filled_thread():
    """
    后台监控线程：实时监控初始单是否成交
    成交后立即用止损价挂反向翻仓单
    """
    global monitor_thread_running

    print(f"  🔄 [监控线程] 已启动，开始监控初始单成交状态...")

    while monitor_thread_running:
        try:
            # 每 1 秒检查一次初始单状态
            monitor_initial_order_filled()
            time.sleep(1)
        except Exception as e:
            if monitor_thread_running:
                print(f"  ⚠️ [监控线程] 异常: {e}")
            time.sleep(5)  # 异常时等待 5 秒

    print(f"  🛑 [监控线程] 已停止")


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
            'has_reverse_order': has_reverse_order,
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

    # 启动后台监控线程
    global monitor_thread_running
    monitor_thread_running = True
    monitor_thread = threading.Thread(target=monitor_order_filled_thread, daemon=True)
    monitor_thread.start()
    print(f"  🔄 [后台监控] 已启动")

    scheduler = BlockingScheduler(timezone='Asia/Shanghai')

    # 核心策略：每 15 分钟检查一次（00分、15分、30分、45分）
    job = scheduler.add_job(execute_strategy, 'cron', minute='0,15,30,45', second='0')

    # 监控：每 30 秒检查一次，在持仓完全平仓后延迟清理未成交的反向委托
    scheduler.add_job(
        monitor_and_cancel_all_orders, 'interval', seconds=30,
        max_instances=2, coalesce=True, misfire_grace_time=120
    )

    print("  ℹ️  [定时器] 监控清理任务已启用，将在持仓关闭后自动撤销反向单")
    print("  📊 [策略机制] 初始单成交后将立即用止损价挂反向翻仓单")
    scheduler.start()


if __name__ == "__main__":
    args = parse_args()
    AMOUNT_ETH = float(args.amount)
    print(f"配置启动：下单数量 = {AMOUNT_ETH} ETH，模式 = {args.mode}")
    print(f"策略参数：")
    print(f"  - 初始单：止盈 = {TP_USD} USD，止损 = {SL_USD} USD")
    print(f"  - 反向单：使用与初始单相同的止盈/止损价差")
    print(f"  - 翻仓倍数 = {LOT_REVERSE_RATIO}x")
    print(f"目标净值 = {target_net_profit} USDT")

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

        # 启动后台监控线程
        monitor_thread_running = True
        monitor_thread = threading.Thread(target=monitor_order_filled_thread, daemon=True)
        monitor_thread.start()
        print(f"  🔄 [后台监控] 已启动")

        scheduler = BlockingScheduler(timezone='Asia/Shanghai')

        # 核心策略：每 15 分钟检查一次
        scheduler.add_job(execute_strategy, 'cron', minute='0,15,30,45', second='0')

        # 监控：每 30 秒检查一次，在持仓完全平仓后延迟清理未成交的反向委托
        scheduler.add_job(
            monitor_and_cancel_all_orders, 'interval', seconds=30,
            max_instances=2, coalesce=True, misfire_grace_time=120
        )

        print("OKX 策略脚本已启动...")
        try:
            scheduler.start()
        except (KeyboardInterrupt, SystemExit):
            print("策略已手动停止。")