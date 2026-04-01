# SleepShip Skills

本文件是 SleepShip agent 的操作手册。当用户要求你用 sleepship 启动或管理一个项目时，按以下流程执行。

---

## Phase 1: 需求梳理

在写任何代码之前，先跟用户充分沟通。

### 1.1 理解需求

向用户确认以下信息：

- **项目目标**：要构建什么？解决什么问题？
- **核心功能清单**：逐条列出，每条必须具体可测试
- **技术栈偏好**：前端/后端/数据库/第三方服务
- **质量标准**：demo（能跑通）/ mvp（日常可用）/ pmf（生产级）
- **成功标准**：怎么算"做完了"？

### 1.2 收集资产

向用户索要项目运行和端到端测试所需的资产。这些资产对自动化测试至关重要：

**常见资产类型：**

| 项目类型 | 需要的资产 |
|---------|-----------|
| 链上项目 | 钱包私钥、RPC endpoint、测试网代币、合约地址 |
| SaaS / Web 应用 | 第三方 API key（Stripe、OpenAI、SendGrid 等） |
| Telegram Bot | Bot token、测试群 chat ID |
| 数据库项目 | 连接字符串、seed 数据 |
| OAuth 项目 | Client ID/Secret、回调 URL |

**存放位置：** 所有资产存入 `PROJECT/.sleepship/.asset/`

```
.sleepship/
└── .asset/
    ├── .env                # 环境变量（API keys、secrets）
    ├── wallet.json         # 钱包/凭证文件
    └── seed-data/          # 测试用种子数据
```

**注意：** `.sleepship/` 目录已在 `.gitignore` 中，资产不会被提交到 git。

### 1.3 落实文档

把沟通结果写入项目根目录的以下文件：

- **`GOAL.md`** — 项目目标、功能清单、技术栈、成功标准、规则
- **`scoring.md`** — 评分维度（可从 sleepship 默认模板复制，根据项目调整）

文档写完后，让用户确认再继续。

---

## Phase 2: 启动项目

需求确认、资产到位后，启动 runner：

```bash
python3 /path/to/sleepship/runner.py --project PROJECT_DIR
```

启动后记录：
- Session ID
- 启动时间
- 项目目录

---

## Phase 3: 监控循环

项目启动后，进入监控循环。这是 SleepShip 的核心运行模式：

```
┌─────────────────────────────────┐
│                                 │
│   sleep 600（等待 10 分钟）       │
│           ↓                     │
│   检查项目状态                    │
│   - runner 是否还在运行？         │
│   - 最新的 review 分数是多少？    │  
│   - 有没有报错或卡住？            │
│           ↓                     │
│   向用户汇报结果                  │
│   - 当前轮次 / 总轮次            │
│   - 最新分数及变化趋势            │
│   - 遇到的问题（如有）            │
│           ↓                     │
│   继续 sleep 600                │
│                                 │
└─────────────────────────────────┘
```

### 监控要做的事

每次 sleep 醒来后：

1. **检查 runner 进程** — 是否还活着
2. **读取最新 review** — `PROJECT/.sleepship/reviews.jsonl` 最后一行
3. **读取 session 状态** — `PROJECT/.sleepship/session.json` 的 turn_count
4. **检查日志** — `PROJECT/.sleepship/{SESSION_ID}.log` 末尾有无异常
5. **汇报给用户** — 简洁汇总：轮次、分数、趋势、问题
6. **如果结束了** — 汇报最终结果，告诉用户项目完成或需要人工介入

### 汇报模板

```
📊 SleepShip 状态报告
━━━━━━━━━━━━━━━━━━
项目：{project_name}
轮次：{turn_count} / {max_turns}
最新分数：{score} / {target_score}
趋势：{上次分数} → {本次分数}（{+/-变化}）
状态：{运行中 / 已完成 / 已停止 / 异常}

{如有问题，简述问题和建议}
```

### 异常处理

| 情况 | 处理 |
|------|------|
| runner 进程挂了 | 尝试 `--resume` 恢复，汇报给用户 |
| 分数连续 3 轮不涨 | 提醒用户可能需要调整 GOAL.md 或人工介入 |
| 分数倒退 | 立即汇报，建议查看最近改动 |
| 达到 max-turns 仍未通过 | 汇报最终分数，建议下一步行动 |

---

## 完整流程总结

```
用户说"帮我搞一个 XX 项目"
        ↓
Phase 1: 需求梳理
  ├── 跟用户沟通，理清需求
  ├── 索要资产 → .sleepship/.asset/
  └── 落实 GOAL.md + scoring.md → 用户确认
        ↓
Phase 2: 启动项目
  └── runner.py --project .
        ↓
Phase 3: 监控循环
  └── sleep 600 → 检查状态 → 汇报 → sleep 600 → ...
        ↓
项目完成或需要人工介入
```
