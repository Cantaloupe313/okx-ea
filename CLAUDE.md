# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an automated trading Expert Advisor (EA) system with two implementations:
- **Python OKX EA** (`okx-ea-demo.py`): Main trading bot using CCXT library to interact with OKX exchange
- **MetaTrader 5 EA** (`策略.mq5`): MT5 version with similar logic for trading XAUUSD

## Development Commands

### Python Environment Setup
```bash
# Activate virtual environment
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

### Running the EA
```bash
# Run in demo mode (default)
./start-demo.sh -x demo

# Run in live mode
./start-demo.sh -x live

# Run with custom amount
./start-demo.sh -x demo -amount 20
```

### Manual Python Execution
```bash
# Demo mode
python3 okx-ea-demo.py

# Live mode (requires API keys in .env)
python3 okx-ea-demo.py -amount <ETH_AMOUNT>

# Direct execution with environment variables
OKX_TRADE_MODE=live python3 okx-ea-demo.py
```

### Health Check
```bash
# Check if the EA is running (returns status JSON)
curl http://localhost:8080/health
```

## Architecture & Core Components

### OKX EA (okx-ea-demo.py)

**Strategy Flow**:
1. **Scheduled Execution**: Runs every 5 minutes (minutes 0,5,10,15,20,25,30,35,40,45,50,55)
2. **Pre-flight Checks**: Verifies no existing positions or open orders before placing new trades
3. **Order Placement**: Creates initial market sell/buy order with attached stop-loss/take-profit
4. **Reverse Trade Setup**: Immediately places a stop-limit order on the opposite side with 2x lot size
5. **Monitoring**: Every 30 seconds checks position status and cleans up residual algo orders

**Key Functions**:
- `detect_pos_mode()`: Detects OKX account position mode (net_mode vs long_short_mode)
- `build_order_params()`: Constructs OKX-native stop-loss/take-profit parameters
- `get_position_details()`: Returns long/short position counts accounting for position modes
- `fetch_pending_algo_orders()`: Queries untriggered conditional orders
- `monitor_and_clean_reverse_orders()`: 30-second interval cleanup that waits 10 seconds before canceling reverse orders after position closes

**Position Modes**:
- **net_mode**: Simpler; single net position tracked
- **long_short_mode**: Separate tracking for long and short positions; requires `posSide` parameter in orders

### MT5 EA (策略.mq5)

**Key Differences from Python EA**:
- Uses MQL5's `CTrade` class
- Manual timer-based execution (1-second interval)
- Calculates next trigger time (00/15/30/45 minute marks)
- Delayed order cancellation (10 seconds) after position closes to prevent race conditions
- Supports both initial short and initial long directions

## Configuration

### Environment Variables (.env)
```bash
# API Keys (demo vs live)
OKX_DEMO_API_KEY, OKX_DEMO_SECRET_KEY, OKX_DEMO_PASSWORD
OKX_LIVE_API_KEY, OKX_LIVE_SECRET_KEY, OKX_LIVE_PASSWORD

# Common Settings
PROXY_URL=http://127.0.0.1:7897           # For China users; empty for overseas
AMOUNT_ETH=10                             # Contract size (ETH)

# Trade Mode (affects sandbox/live and symbol mapping)
OKX_TRADE_MODE=demo
```

### Core Parameters
- **TP_USD** / **SL_USD**: Profit/loss trigger distance in USD
- **LOT_REVERSE_RATIO**: Reverse trade lot size multiplier (default 2x)
- **Leverage**: Set via `set_leverage_safely()` (default 50x)
- **Anti-duplicate**: Minimum 2-minute interval between executions

## Deployment

### Local Development
```bash
./start-demo.sh -x <demo|live> [-amount N]
```

### Render Cloud Deployment
Use `render.yaml` Blueprint configuration. Key settings:
- Health check: `/health` endpoint
- Auto-deploy: enabled
- Trade mode: `OKX_TRADE_MODE=demo` by default (change to `live` with real keys)
- Environment variables must be set in Render dashboard (sync: false prevents committing keys)

## Common Modifications

### Changing Trading Parameters
Modify constants at top of `okx-ea-demo.py`:
- `TP_USD`, `SL_USD` (lines 44-45)
- `LOT_REVERSE_RATIO` (line 46)
- `LEVERAGE` (line 41)
- `AMOUNT_ETH` (line 50) - or pass via `-amount` arg

### Adjusting Schedule
Edit cron expression in `run_scheduler_blocking()`:
```python
scheduler.add_job(execute_strategy, 'cron', minute='0,5,10,15,20,25,30,35,40,45,50,55', second='0')
```

### Adding New Logic
1. Create helper function with clear name (e.g., `check_safety_conditions()`)
2. Use try-except blocks with detailed error logging
3. Add position/cleanup monitoring in `monitor_and_clean_reverse_orders()`
4. Test in demo mode first with `-amount <small>` to avoid large losses
