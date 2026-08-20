#!/bin/bash
# OKX EA 启动脚本
# 用法：
#   ./start.sh -x demo              # 启动模拟盘（数量用 .env 中的 AMOUNT_ETH）
#   ./start.sh -x live              # 启动实盘
#   ./start.sh -x demo -amount 20 -init-side sell  # 启动模拟盘，指定下单 20 ETH

source venv/bin/activate
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 加载本地 .env（包含 API 密钥，不上云，已在 .gitignore 中）
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# 解析参数：-x 模式 / -amount 数量 / -init-side 初始方向（手动解析以支持多字符选项名）
MODE=""
AMOUNT_ARG=""
INIT_SIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x)
            MODE="$2"; shift 2 ;;
        -amount)
            AMOUNT_ARG="$2"; shift 2 ;;
        -init-side)
            INIT_SIDE="$2"; shift 2 ;;
        *)
            echo "用法: $0 -x demo|live [-amount N] [-init-side buy|sell]" >&2; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "用法: $0 -x demo|live [-amount N] [-init-side buy|sell]"
    echo "  -x demo        启动模拟盘"
    echo "  -x live        启动实盘"
    echo "  -amount N      下单数量(ETH)，可选，默认读 .env 中 AMOUNT_ETH"
    echo "  -init-side     初始下单方向，可选：buy（看涨）或 sell（看跌），默认 sell"
    exit 1
fi

if [ "$MODE" != "demo" ] && [ "$MODE" != "live" ]; then
    echo "错误: -x 参数只支持 demo 或 live"
    exit 1
fi

# 校验 -init-side 参数
if [ -n "$INIT_SIDE" ] && [ "$INIT_SIDE" != "buy" ] && [ "$INIT_SIDE" != "sell" ]; then
    echo "错误: -init-side 参数只支持 buy 或 sell"
    exit 1
fi

export OKX_INIT_SIDE="${INIT_SIDE:-sell}"

# 根据模式选择对应的 API 密钥并导出为统一变量名
if [ "$MODE" = "demo" ]; then
    export OKX_API_KEY="$OKX_DEMO_API_KEY"
    export OKX_SECRET_KEY="$OKX_DEMO_SECRET_KEY"
    export OKX_PASSWORD="$OKX_DEMO_PASSWORD"
else
    export OKX_API_KEY="$OKX_LIVE_API_KEY"
    export OKX_SECRET_KEY="$OKX_LIVE_SECRET_KEY"
    export OKX_PASSWORD="$OKX_LIVE_PASSWORD"
fi

export OKX_TRADE_MODE="$MODE"

# -amount 优先级最高，覆盖 .env 中的 AMOUNT_ETH
if [ -n "$AMOUNT_ARG" ]; then
    export AMOUNT_ETH="$AMOUNT_ARG"
fi

# 校验密钥是否已配置
if [ -z "$OKX_API_KEY" ] || [ -z "$OKX_SECRET_KEY" ] || [ -z "$OKX_PASSWORD" ]; then
    echo "【错误】未检测到 $MODE 模式的 API 密钥！"
    echo "请在 .env 文件中配置 OKX_${MODE^^}_API_KEY / OKX_${MODE^^}_SECRET_KEY / OKX_${MODE^^}_PASSWORD"
    exit 1
fi

echo "========================================"
echo "  OKX EA 启动"
echo "  模式:   $MODE"
echo "  数量:   ${AMOUNT_ETH:-10} ETH"
echo "  止盈:   ${TP_USD:-4.0} USD"
echo "  止损:   ${SL_USD:-4.0} USD"
echo "  代理:   ${PROXY_URL:-无（直连）}"
echo "========================================"

# 透传 -amount 和 -init-side 给 Python（若指定了则覆盖环境变量）
python3 -u okx-ea.py -amount "${AMOUNT_ARG:-}" -init-side "${INIT_SIDE:-}"
