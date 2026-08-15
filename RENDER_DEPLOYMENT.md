# OKX EA Render 部署落地文档

## 📋 目录
1. [Render 账号申请](#render-账号申请)
2. [GitHub 仓库准备](#github-仓库准备)
3. [Render 服务创建](#render-服务创建)
4. [环境变量配置](#环境变量配置)
5. [部署验证](#部署验证)
6. [常见问题](#常见问题)

---

## 1. Render 账号申请

### 1.1 注册步骤
1. **访问官网**：https://render.com
2. **注册账号**：
   - 点击 "Sign Up" 按钮
   - 支持 GitHub、GitLab、Bitbucket 登录（推荐）
   - 或者使用邮箱注册

3. **验证邮箱**：
   - 注册后会收到验证邮件
   - 点击邮件中的链接完成验证

### 1.2 推荐登录方式
- **GitHub 登录**（最推荐）：
  - 点击 "Continue with GitHub"
  - 授权 Render 访问你的 GitHub 账号
  - 系统会自动读取你的代码仓库

- **其他方式**：
  - 支持 GitLab、Bitbucket
  - 或使用邮箱注册

---

## 2. GitHub 仓库准备

### 2.1 确保代码已推送

```bash
# 查看当前分支
git branch

# 推送代码到 GitHub
git push origin master
```

### 2.2 确认文件完整性
确保仓库包含以下文件：
- ✅ `okx-ea.py` - 主程序文件
- ✅ `start.sh` - 启动脚本
- ✅ `requirements.txt` - Python 依赖
- ✅ `render.yaml` - Render 配置文件
- ✅ `render.yaml.example` - 配置示例（可选）
- ✅ `.env.example` - 环境变量模板

### 2.3 配置 .gitignore
确保 `.gitignore` 包含敏感文件：
```
.env
.env.local
__pycache__/
*.pyc
venv/
```

---

## 3. Render 服务创建

### 3.1 创建新服务

1. **登录 Render**：https://dashboard.render.com

2. **创建新服务**：
   - 点击右上角 "New +" 按钮
   - 选择 **"Blueprint"**（推荐）或 "Web Service"

3. **选择部署方式**：
   - **Blueprint 方式**（推荐）：
     - 自动识别 `render.yaml` 配置
     - 一键创建所有依赖服务
     - 更容易维护和更新

   - **Web Service 方式**：
     - 手动配置每个服务
     - 更灵活但需要手动操作

### 3.2 Blueprint 部署流程

**方式一：GitHub 自动创建（推荐）**
1. 在 Render 新建服务时，选择 **"Connect to GitHub"**
2. 授权 Render 访问你的仓库
3. 选择项目仓库 `okx-ea`
4. Render 会自动检测 `render.yaml` 并创建服务
5. 等待部署完成（约 3-5 分钟）

**方式二：手动上传 render.yaml**
1. 点击 "New +" → "Blueprint"
2. 选择 **"Upload a Blueprint"**
3. 上传本地的 `render.yaml` 文件
4. Render 会根据配置自动创建服务

### 3.3 验证部署状态

在 Render Dashboard 中查看：
- ✅ **Status**: `Live`（服务运行中）
- ✅ **Health**: `Healthy`（健康检查通过）
- ✅ **Logs**: 查看应用日志确认启动成功

---

## 4. 环境变量配置

### 4.1 基础配置（必填）

在 Render Dashboard 的 **"Environment"** 标签页中设置：

#### 交易模式
| 变量名 | 说明 | 默认值 | 示例 |
|--------|------|--------|------|
| `OKX_TRADE_MODE` | 交易模式：demo=模拟盘，live=实盘 | `demo` | `demo` |
| `TARGET_NETPROFIT` | 目标净值（USDT） | `100` | `100` |

#### 下单参数
| 变量名 | 说明 | 默认值 | 示例 |
|--------|------|--------|------|
| `AMOUNT_ETH` | 下单数量（ETH） | `10` | `10` |
| `OKX_INIT_SIDE` | 初始下单方向：buy=看涨，sell=看跌 | `sell` | `sell` |
| `TP_USD` | 初始单止盈价差（USD） | `4` | `4` |
| `SL_USD` | 初始单止损价差（USD） | `4` | `4` |
| `LOT_REVERSE_RATIO` | 反向翻仓倍数 | `2.0` | `2.0` |
| `LEVERAGE` | 杠杆倍数 | `50` | `50` |

### 4.2 API 密钥配置

#### 模拟盘密钥（推荐先用 demo 测试）
```
OKX_DEMO_API_KEY=你的模拟盘API密钥
OKX_DEMO_SECRET_KEY=你的模拟盘密钥
OKX_DEMO_PASSWORD=你的模拟盘密码
```

#### 实盘密钥（正式交易时配置）
```
OKX_LIVE_API_KEY=你的实盘API密钥
OKX_LIVE_SECRET_KEY=你的实盘密钥
OKX_LIVE_PASSWORD=你的实盘密码
```

#### 配置说明
- `sync: false` 表示这些变量不会提交到代码仓库
- 必须在 Render Dashboard 手动填写
- **安全提示**：实盘密钥仅在需要时配置，demo 模式足够测试

### 4.3 网络配置

| 变量名 | 说明 | 默认值 | 示例 |
|--------|------|--------|------|
| `PROXY_URL` | 代理地址（海外服务器必须留空） | `""` | `""` |

**重要**：Render 海外服务器无需代理，必须留空！

### 4.4 配置步骤

1. 进入服务详情页面
2. 点击 **"Environment"** 标签页
3. 添加上述环境变量
4. 每行一个变量，格式为 `KEY=value`
5. 点击 **"Add Variable"** 保存
6. 点击 **"Apply Changes"** 重启服务生效

---

## 5. 部署验证

### 5.1 健康检查

访问服务健康检查端点：
```bash
curl https://okx-ea.onrender.com/health
```

**预期响应**：
```json
{
  "status": "running",
  "symbol": "ETH/USDT:USDT",
  "amount_eth": 10,
  "last_order_time": 1234567890.12,
  "has_reverse_order": false
}
```

### 5.2 查看日志

在 Render Dashboard 的 **"Logs"** 标签页查看实时日志：

**成功启动的日志示例**：
```
[交易模式] 模拟盘 (sandbox)
配置启动：下单数量 = 10 ETH，模式 = demo
策略参数：
  - 初始单：止盈 = 4.0 USD，止损 = 4.0 USD
  - 反向单：使用与初始单相同的止盈/止损价差
  - 翻仓倍数 = 2.0x
目标净值 = 100 USDT
✅ [杠杆设置] 成功设置 50x 杠杆
  🔄 [后台监控] 已启动
  ℹ️  [定时器] 监控清理任务已启用，将在持仓关闭后自动撤销反向单
  📊 [策略机制] 初始单成交后将立即用止损价挂反向翻仓单
OKX 策略脚本已启动...
```

### 5.3 验证策略运行

1. **模拟盘测试**（无需真实资金）：
   ```bash
   # 确认服务正在运行
   curl https://okx-ea.onrender.com/health
   ```

2. **检查自动部署**：
   - 修改代码后，Render 会自动触发重新部署
   - 在 "Events" 标签页查看部署状态

3. **查看运行时间**：
   - Render 免费服务每晚会自动休眠 5 分钟
   - 首次唤醒可能需要 1-2 分钟

---

## 6. 常见问题

### 6.1 部署失败

#### 问题 1：构建失败
```
Error: Command failed: pip install -r requirements.txt
```

**解决方案**：
1. 检查 `requirements.txt` 格式是否正确
2. 确保所有依赖包名称正确
3. 尝试在本地运行 `pip install -r requirements.txt` 测试

#### 问题 2：依赖安装超时
```
Error: Build timeout
```

**解决方案**：
1. Render 免费版构建时间限制 15 分钟
2. 减少不必要的依赖包
3. 确保 `requirements.txt` 文件格式正确

### 6.2 服务无法启动

#### 问题 3：服务启动后立即崩溃
```
Error: API key not found
```

**解决方案**：
1. 确认在 Render Dashboard 中正确配置了所有环境变量
2. 检查 `OKX_TRADE_MODE` 值是否正确
3. 重启服务：点击 "Manual Deploy" → "Blue Build"

#### 问题 4：API 连接失败
```
Error: Cannot connect to OKX
```

**解决方案**：
1. **海外服务器无需代理**：确保 `PROXY_URL` 留空
2. 检查 OKX API 密钥是否正确
3. 确认 API 密钥具有足够的权限

### 6.3 运行时问题

#### 问题 5：策略未执行
```
Status: running，但策略未运行
```

**检查清单**：
- ✅ `OKX_TRADE_MODE` 设置为 `demo` 或 `live`
- ✅ `TARGET_NETPROFIT` 设置了目标净值
- ✅ API 密钥已正确配置
- ✅ 查看日志确认无报错

#### 问题 6：定时任务未执行
```
APScheduler 未触发
```

**原因**：Render 免费服务会自动休眠，唤醒后定时器会立即启动

**解决方案**：
- 策略会从上次检查点继续运行
- 无需手动干预

#### 问题 7：监控线程未启动
```
[监控线程] 未找到
```

**解决方案**：
1. 重启服务
2. 检查 `startCommand` 是否为 `python okx-ea.py`

### 6.4 API 密钥问题

#### 问题 8：API 密钥无效
```
Error: Invalid API key
```

**解决方案**：
1. 登录 OKX 官网（https://www.okx.com）
2. 进入 **API 管理**
3. 检查 API 密钥状态是否为 `active`
4. 确认密钥权限包含：
   - ✅ 交易权限（Trade）
   - ✅ 读取权限（Read/Market）
   - ✅ 模拟盘（如果是 demo 模式）

#### 问题 9：API 密钥过期
```
Error: API key expired
```

**解决方案**：
1. 在 OKX 重新生成 API 密钥
2. 更新 Render 环境变量中的密钥值
3. 重启服务生效

### 6.5 性能优化

#### 问题 10：健康检查超时
```
Health check failed
```

**解决方案**：
1. 确认 Flask 应用正常启动
2. 健康检查端点返回 200 状态码
3. 增加超时时间（可选）

#### 问题 11：内存不足
```
Error: Out of memory
```

**解决方案**：
1. 减少 `AMOUNT_ETH` 值
2. 降低杠杆倍数
3. 优化 Python 代码

---

## 7. 进阶配置

### 7.1 自动重新部署

在 `render.yaml` 中配置：
```yaml
autoDeploy: true
```

每次推送代码到 GitHub 时，Render 会自动触发重新部署。

### 7.2 环境变量加密

敏感信息（API 密钥）使用 `sync: false`：
```yaml
envVars:
  - key: OKX_DEMO_API_KEY
    sync: false
```

这样密钥不会提交到代码仓库，仅在 Render Dashboard 中配置。

### 7.3 监控和告警

1. **日志监控**：在 Render Dashboard 查看 Logs
2. **错误告警**：设置邮件或 Slack 通知
3. **性能监控**：配置外部监控服务（如 Datadog）

### 7.4 升级到付费版

**Render 付费版优势**：
- ⏱️ 15 分钟构建时间限制
- 🚀 更快的部署速度
- 📊 更详细的日志和分析
- 🔄 支持 24/7 全天候运行

**升级步骤**：
1. 登录 Render Dashboard
2. 进入服务详情页
3. 点击 "Change Plan"
4. 选择 "Standard" 或 "Pro" 计划

---

## 8. 维护指南

### 8.1 代码更新

```bash
# 1. 本地修改代码
vim okx-ea.py

# 2. 提交到 GitHub
git add .
git commit -m "feat: 添加新功能"
git push origin master

# 3. Render 自动重新部署
# 查看部署状态：https://dashboard.render.com
```

### 8.2 查看策略运行状态

```bash
# 健康检查
curl https://okx-ea.onrender.com/health

# 查看日志
# 登录 Render Dashboard → 选择服务 → Logs 标签页
```

### 8.3 停止/重启服务

1. **手动重启**：
   - Render Dashboard → 选择服务 → Manual Deploy → Blue Build

2. **完全停止**：
   - Render Dashboard → 选择服务 → Stop

### 8.4 日志清理

Render 免费版日志保留 30 天：
- 查看日志时建议定期清理旧日志
- 避免日志文件过大影响性能

---

## 9. 安全建议

### 9.1 API 密钥安全

- ✅ **永远不要**将 API 密钥提交到代码仓库
- ✅ 使用 `.env` 文件管理本地密钥
- ✅ Render 的 `sync: false` 确保密钥不上云
- ✅ 定期轮换 API 密钥

### 9.2 交易安全

- ✅ **先用 demo 模式测试**，确认策略逻辑正确
- ✅ **从少量资金开始**（如 1-5 ETH）
- ✅ **设置止损**，避免单次亏损过大
- ✅ **监控运行日志**，及时发现异常
- ⚠️ 实盘交易前充分测试

### 9.3 权限管理

OKX API 密钥权限建议：
```
权限：
✅ 交易权限（Trade）- 策略需要
✅ 读取权限（Read/Market）- 获取行情和账户信息
❌ 充值/提现权限 - 策略不需要，建议关闭
❌ 转账权限 - 策略不需要，建议关闭
```

---

## 10. 联系支持

### 10.1 获取帮助

- **Render 官方文档**：https://render.com/docs
- **OKX API 文档**：https://www.okx.com/docs-v5/
- **Claude Code**：https://claude.com/claude-code

### 10.2 故障报告

如遇到无法解决的问题：
1. 收集以下信息：
   - Render Dashboard 的截图（服务状态、日志）
   - 错误信息完整日志
   - 复现步骤

2. 提交到：
   - GitHub Issues：https://github.com/你的用户名/okx-ea/issues
   - 或联系项目维护者

---

## 附录：快速部署检查清单

部署前确认：
- [ ] Render 账号已注册并验证
- [ ] 代码已推送到 GitHub
- [ ] `render.yaml` 配置正确
- [ ] `.gitignore` 包含 `.env` 文件
- [ ] API 密钥已准备好（模拟盘优先）

部署后确认：
- [ ] Render Dashboard 显示服务状态为 `Live`
- [ ] 健康检查返回 `{"status": "running"}`
- [ ] 日志显示策略正常启动
- [ ] 环境变量配置正确（API 密钥、模式等）
- [ ] 策略开始执行（查看日志中的策略触发信息）

---

**文档版本**：v1.0.0
**最后更新**：2026-08-14
**适用版本**：OKX EA v1.0.0
