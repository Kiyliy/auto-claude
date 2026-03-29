# Auto-Claude

> Claude Code 持续工作增强套件

## 解决什么问题

1. **CC 干完活就停了** — 自动评分，不达标就继续干
2. **CC 干完活不告诉你** — Telegram 推送关键事件
3. **想给 CC 发指令但它在后台跑** — Telegram 双向通信

## 架构

```
┌─────────────────────────────────────────────────┐
│                  runner.py                       │
│  stream-json 模式持久 CC 进程                     │
│  stdin 注入 / stdout 解析 / 自动续命              │
└──────┬──────────────────────┬────────────────────┘
       │ stdin                │ stdout (stream-json)
       ▼                     ▼
┌─────────────────────────────────────────────────┐
│              Claude Code (-p mode)               │
│                                                  │
│  Stop event:                                     │
│    1. prompt hook → scoring.md (Haiku 评分)       │
│    2. command hook → stop-hook.sh (续命控制)       │
│                                                  │
│  TeammateIdle event:                             │
│    prompt hook → teammate-idle.md                │
│                                                  │
│  StopFailure event:                              │
│    command hook → 通知 daemon                     │
└──────┬──────────────────────────────────────────┘
       │ curl --unix-socket
       ▼
┌─────────────────────────────────────────────────┐
│           channel/daemon.ts                      │
│  Unix socket HTTP API + Telegram long-polling    │
│  Session 注册 / Topic 隔离 / 消息队列             │
└──────┬──────────────────────┬────────────────────┘
       │                     │
       ▼                     ▼
   Telegram Bot API      runner.py (轮询 /messages)
```

## 两层续命机制

**第一层：Hook 级别（每次 Stop 触发）**
1. scoring prompt (Haiku) 评估项目质量 → 不达 90 分则 CC 继续改进
2. stop-hook.sh 追踪续命次数 → 未达上限则 block + 注入续命指令
3. 连续 block 上限（MAX_CONSECUTIVE_BLOCKS=10）后放行一轮 → CC 产出 result

**第二层：Runner 级别（每次 result 后）**
1. runner.py 收到 result event → 发送 "继续改进项目" → 新一轮开始
2. TG 消息轮询 → 用户消息优先注入
3. 心跳检测 → 10 分钟无活动发送唤醒

## 核心文件

```
auto-claude/
├── scripts/
│   ├── runner.py              # 主运行器（stream-json 模式）
│   └── inject-prompts.sh      # 将 prompts/ 注入 settings.json
├── hooks/
│   └── stop-hook.sh           # 续命控制（计数 + 通知）
├── prompts/
│   ├── scoring.md             # 质量评分（Stop prompt hook）
│   ├── continue.md            # 续命指令模板（stop-hook.sh 读取）
│   └── teammate-idle.md       # 队友完成检查（TeammateIdle prompt hook）
├── channel/
│   └── src/
│       ├── daemon.ts          # TG daemon（HTTP API + long-polling）
│       ├── config.ts          # 配置加载
│       └── telegram.ts        # TG Bot API
├── config/
│   ├── settings.json          # Hook 注册模板
│   ├── config.env.example     # 环境变量模板
│   └── mcp-config.example.json
├── lib/
│   ├── state.sh               # Session 状态（续命计数）
│   └── log.sh                 # 日志
├── SOUL.md
├── README.md
└── LICENSE
```

## 评分系统

scoring.md 定义 10 个维度，每项 0-10 分，满分 100，目标 90：

| 维度 | 重点检查 |
|------|---------|
| 功能完整性 | 需求逐条核对，无死链 |
| 前端质量 | 布局/响应式/交互/视觉一致性 |
| 运行时稳定性 | 控制台零报错，刷新正常 |
| 代码质量 | 零 lint 警告，类型安全 |
| 测试覆盖 | 核心 API + E2E 主流程 |
| 错误处理 | loading/error/empty 三态 |
| 安全性 | 环境变量/输入校验/认证 |
| 文档 | README + .env.example + API |
| 数据层 | Schema 合理，有索引 |
| 可运行性 | 一键能跑 |

额外扣分：需求未对齐 -5/项，核心流程不通 -20，无法启动 -30。

评分前 **必须** 跑 build、测试、启动验证。

## Stop Hook 工作流

```
CC 即将停止
    │
    ▼
scoring prompt (Haiku 评分)
    │
    ├─ score < 90 → CC 继续改进（prompt hook 拒绝停止）
    │
    └─ score >= 90 → stop-hook.sh 运行
                        │
                        ├─ 连续 block >= 10 → 放行（reset 计数）
                        │
                        ├─ 总续命 >= 20 → 放行 + 通知
                        │
                        └─ 未达上限 → block (exit 2)
                            注入 continue.md 到 stderr
```

## Daemon HTTP API

Unix socket: `~/.auto-claude/channel.sock`

| Method | Path | 说明 |
|--------|------|------|
| GET | /health | 健康检查 |
| POST | /notify | 发送 TG 通知 |
| POST | /sessions | 注册 session（创建 Topic） |
| GET | /sessions | 列出所有 session |
| DELETE | /sessions/:id | 注销 session（关闭 Topic） |
| GET | /sessions/:id/messages?timeout=30 | 长轮询消息 |
| POST | /sessions/:id/reply | 回复到 TG |
| POST | /inject/:id | 测试注入消息 |

## 配置

`~/.auto-claude/config.env`:

| 变量 | 默认 | 说明 |
|------|------|------|
| TG_BOT_TOKEN | -- | Telegram Bot Token |
| TG_CHAT_ID | -- | 接收通知的 Chat ID |
| MAX_CONTINUATIONS | 20 | 总续命上限 |
| MAX_CONSECUTIVE_BLOCKS | 10 | 连续 block 上限 |
| NOTIFY_ON_CONTINUE | true | 每次续命是否通知 |
| CHANNEL_SOCKET | ~/.auto-claude/channel.sock | Daemon socket 路径 |
