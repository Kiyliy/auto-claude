# auto-claude

> Claude Code 持续工作增强套件 — 评分驱动的自动迭代 + Telegram 双向通信

## 核心能力

| 能力 | 说明 |
|------|------|
| **评分驱动迭代** | Stop Hook 触发 Haiku 评分（10 维度，满分 100），未达 90 分自动继续改进 |
| **智能续命** | 续命计数 + 连续 block 计数，防无限循环，达上限自动停止 |
| **Telegram 通知** | 续命、完成、错误等事件通过 Telegram Bot 推送 |
| **Telegram 双向** | 从 Telegram 向 CC 发指令并接收回复，支持群组 Topics 多 session 隔离 |

## 快速开始

```bash
# 1. Clone
git clone https://github.com/Kiyliy/auto-claude.git
cd auto-claude

# 2. 配置
mkdir -p ~/.auto-claude/{state,logs}
cp config/config.env.example ~/.auto-claude/config.env
# 编辑 config.env，填写 TG_BOT_TOKEN 和 TG_CHAT_ID

# 3. 注入评分 prompt 到 settings.json
bash scripts/inject-prompts.sh

# 4. 启动 Telegram daemon
cd channel && npm install && cd ..
npx tsx channel/src/daemon.ts &

# 5. 运行
python3 scripts/runner.py
```

## 工作原理

### 两层续命

**Hook 层**（每次 CC 想停时触发）：
1. `scoring.md` prompt hook — Haiku 评估 10 个维度，< 90 分则拒绝停止
2. `stop-hook.sh` command hook — 续命计数 + block/allow 控制

**Runner 层**（stream-json 模式）：
- CC 产出 result → runner.py 自动发送下一条指令
- TG 消息轮询 → 用户消息优先注入 CC
- 心跳检测 → 10 分钟无活动自动唤醒

### 评分维度

| # | 维度 | 要点 |
|---|------|------|
| 1 | 功能完整性 | 需求逐条核对，无死链 |
| 2 | 前端质量 | 布局/响应式/交互/视觉一致性 |
| 3 | 运行时稳定性 | 控制台零报错，刷新正常 |
| 4 | 代码质量 | 零 lint 警告，类型安全 |
| 5 | 测试覆盖 | 核心 API + E2E 主流程 |
| 6 | 错误处理 | loading/error/empty 三态 |
| 7 | 安全性 | 环境变量/输入校验/认证 |
| 8 | 文档 | README + .env.example + API |
| 9 | 数据层 | Schema + 索引 + 种子数据 |
| 10 | 可运行性 | 一键安装启动 |

目标 90 分。评分前必须跑 build、测试、启动验证。

## 项目结构

```
auto-claude/
├── scripts/
│   ├── runner.py              # 主运行器（stream-json 模式）
│   └── inject-prompts.sh      # 注入 prompts/ 到 settings.json
├── hooks/
│   └── stop-hook.sh           # 续命控制器
├── prompts/
│   ├── scoring.md             # 质量评分 prompt（可自定义）
│   ├── continue.md            # 续命指令模板
│   └── teammate-idle.md       # 队友完成检查
├── channel/
│   └── src/
│       ├── daemon.ts          # TG daemon
│       ├── config.ts          # 配置
│       └── telegram.ts        # TG API
├── config/
│   ├── settings.json          # Hook 注册模板
│   ├── config.env.example     # 环境变量
│   └── mcp-config.example.json
├── lib/
│   ├── state.sh               # Session 状态
│   └── log.sh                 # 日志
└── LICENSE
```

## 配置

`~/.auto-claude/config.env`:

| 变量 | 默认 | 说明 |
|------|------|------|
| `TG_BOT_TOKEN` | -- | Telegram Bot Token（必填） |
| `TG_CHAT_ID` | -- | Chat ID（必填） |
| `MAX_CONTINUATIONS` | 20 | 总续命上限 |
| `MAX_CONSECUTIVE_BLOCKS` | 10 | 连续 block 上限 |
| `NOTIFY_ON_CONTINUE` | true | 续命时是否通知 |

## 自定义评分标准

编辑 `prompts/scoring.md`，修改维度和权重，然后：

```bash
bash scripts/inject-prompts.sh
```

## Daemon API

Unix socket `~/.auto-claude/channel.sock`:

```bash
# 健康检查
curl --unix-socket ~/.auto-claude/channel.sock http://localhost/health

# 发送通知
curl --unix-socket ~/.auto-claude/channel.sock -X POST http://localhost/notify \
  -H 'Content-Type: application/json' \
  -d '{"message":"test","event_type":"info"}'

# 注册 session
curl --unix-socket ~/.auto-claude/channel.sock -X POST http://localhost/sessions \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"abc123"}'
```

## 前置条件

| 依赖 | 说明 |
|------|------|
| Claude Code | `claude --version` |
| jq | `apt install jq` |
| Python 3 | runner.py |
| Node.js | channel daemon |

## License

MIT
