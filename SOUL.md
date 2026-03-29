# Auto-Claude

> GOAL.md 驱动的 Claude Code 自主迭代引擎

## 核心理念

用户写一个 `GOAL.md` 放在项目根目录，定义项目目标和功能清单。
Auto-Claude 让 CC 自主迭代，每轮评分，直到达标。

```
用户写 GOAL.md → CC 读取并开始工作 → 评分 → 未达标继续 → 达标停止
```

## 两种使用模式

### 无头模式（-p）
```bash
python3 runner.py --project ~/projects/twitter-clone
```
runner.py 读 GOAL.md，启动 CC stream-json 进程，自动续命，TG 消息桥接。

### 交互模式（CLI）
```bash
cd ~/projects/twitter-clone
claude
> 请阅读 GOAL.md 并开始工作
```
CC hooks 自动生效：scoring prompt 评分，stop-hook.sh 续命。

两种模式共享同一套 hooks 和 prompts。

## 架构

```
用户项目/
├── GOAL.md                  ← 用户编写：目标 + 功能清单 + 行为规则
└── .auto-claude/
    └── results.jsonl        ← 每轮评分自动追加

auto-claude/
├── scripts/runner.py        ← 无头模式引擎
├── hooks/stop-hook.sh       ← 续命控制（两种模式都用）
├── prompts/
│   ├── scoring.md           ← 通用评分（读 GOAL.md）
│   ├── continue.md          ← 续命指令（含评分趋势）
│   └── teammate-idle.md
├── templates/GOAL.example.md ← GOAL.md 模板
├── channel/                  ← TG daemon
├── config/                   ← Hook 注册 + 环境变量
└── lib/                      ← 状态管理 + 日志
```

## 评分系统

scoring.md 定义 10 个通用维度，每项 0-10 分：

| # | 维度 | 说明 |
|---|------|------|
| 1 | 目标达成度 | 逐条核对 GOAL.md 功能清单 |
| 2 | UI/UX 质量 | 有 UI 标杆则对标，无则检查一致性 |
| 3 | 响应式 | 三断点适配 |
| 4 | 运行时稳定性 | 控制台零报错 |
| 5 | 代码质量 | 零编译错误，类型安全 |
| 6 | 测试覆盖 | 核心逻辑有测试 |
| 7 | 错误处理 | 三态处理 |
| 8 | 安全性 | 环境变量、校验、认证 |
| 9 | 文档 | README + .env.example |
| 10 | 可运行性 | 一键能跑 |

评分前必须跑 build/test/start。每轮结果追加到 `results.jsonl`。

## 迭代循环

```
CC 工作 → 想停止 → scoring prompt 评分
    │
    ├─ < 目标分 → CC 继续改进
    │
    └─ >= 目标分 → stop-hook.sh
                      │
                      ├─ 未达续命上限 → block + 注入续命指令（含评分趋势）
                      │
                      └─ 达续命上限 → 放行停止
```

续命指令包含评分趋势：
```
上一轮评分：67/100
趋势：53 → 61 → 67
最低维度：UI/UX质量, 测试覆盖
优先改进最低维度。
```

## Git 管理

- CC 每完成一批改动后 git commit
- 评分后自动 commit：`[auto-claude] round N: score X/100`
- 不 reset — 评分趋势驱动改进方向

## Telegram 双向通信

daemon.ts 常驻进程，Unix socket API。

- 通知：续命、完成、错误事件推送到 TG
- 双向：用户从 TG 发消息 → runner.py 轮询注入 CC stdin
- 多 session：TG 群组 Topics 隔离
