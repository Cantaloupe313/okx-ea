#!/bin/bash
# OKX EA 启动脚本
# 用法：
#   ./start-demo.sh -x demo              # 启动模拟盘（数量用 .env 中的 AMOUNT_ETH）
#   ./start-demo.sh -x live              # 启动实盘
#   ./start-demo.sh -x demo -amount 20   # 启动模拟盘，指定下单 20 ETH

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 加载本地 .env（包含 API 密钥，不上云，已在 .gitignore 中）
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# 解析参数：-x 模式 / -amount 数量（手动解析以支持多字符选项名）
MODE=""
AMOUNT_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x)
            MODE="$2"; shift 2 ;;
        -amount)
            AMOUNT_ARG="$2"; shift 2 ;;
        *)
            echo "用法: $0 -x demo|live [-amount N]" >&2; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "用法: $0 -x demo|live [-amount N]"
    echo "  -x demo        启动模拟盘"
    echo "  -x live        启动实盘"
    echo "  -amount N      下单数量(ETH)，可选，默认读 .env 中 AMOUNT_ETH"
    exit 1
fi

if [ "$MODE" != "demo" ] && [ "$MODE" != "live" ]; then
    echo "错误: -x 参数只支持 demo 或 live"
    exit 1
fi

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
echo "  代理:   ${PROXY_URL:-无（直连）}"
echo "========================================"

# 透传 -amount 给 Python（若指定了则覆盖环境变量）
if [ -n "$AMOUNT_ARG" ]; then
    python3 okx-ea-demo.py -amount "$AMOUNT_ARG"
else
    python3 okx-ea-demo.py
fi
