#!/bin/bash


# 2. 激活虚拟环境
source venv/bin/activate

# 3. 运行 OKX 策略脚本，透传所有命令行参数
#    例: ./start-demo.bash -amount 10   表示下单 10 ETH
python okx-ea-demo.py "$@"

# 4. 保持窗口开启（可选，方便报错时看日志）
deactivate