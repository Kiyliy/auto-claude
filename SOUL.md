# Auto-Claude

> Claude Code 持续工作增强套件 — 让 CC 不停下来、干完活自己汇报

## 项目定位

基于 Claude Code 的 Hook 系统和 Channel 机制，提供**开箱即用的配置和脚本**，解决两个核心问题：

1. **CC 干完活就停了** — 自动检测完成状态，唤醒继续
2. **CC 干完活不告诉你** — 通过 Telegram 推送关键事件通知

不是一个独立应用，而是一组 CC 插件/配置/Hook 脚本的集合。

---

## 工作模式

所有工作以 **Agent Team → Subagents** 模式进行：
- 主代理（Lead）负责任务编排和分发
- 子代理（Subagents / Teammates）执行具体任务
- Hook 监听整个 Agent Team 的生命周期事件

---

## 模块一：Auto-Continue（自动续命）

### 问题

CC 主代理完成当前轮次后会停下来等用户输入。在 Agent Team 模式下，当所有 subagent/teammate 都完成且主代理也停下来时，整个工作流就中断了。

### 方案

利用 CC 的 **Stop Hook** + **SubagentStop Hook** + **TeammateIdle Hook** 组合，实现智能续命：

```
主代理 Stop
    ↓
检查: 是否还有活跃的 subagent/teammate?
    ├─ 有 → 放行 Stop（等它们完成）
    └─ 没有 → 检查任务完成状态
                ├─ 全部完成 → 放行 Stop，触发通知
                └─ 还有未完成 → Block Stop，注入"继续下一步"
```

### 核心 Hook 设计

#### 1. Stop Hook（主控）

**事件**: `Stop`
**类型**: `command` (shell 脚本)
**逻辑**:

```
输入 JSON (stdin):
  - session_id
  - transcript_path
  - stop_hook_active  ← 关键：防止无限循环
  - cwd

处理流程:
  1. 读取 stop_hook_active
     - 如果 true → 说明已经续命过一次，这次放行（exit 0）
     - 如果 false → 继续判断

  2. 读取状态文件（~/.auto-claude/state/{session_id}.json）
     - 检查是否有未完成的 subagent（通过 SubagentStop 事件维护的计数）
     - 检查是否有未完成的 task（通过 TaskCompleted 事件维护的列表）

  3. 判断是否需要续命
     - 所有 subagent 已完成 + 有 pending task → Block + 注入续命指令
     - 所有 subagent 已完成 + 无 pending task → 放行（工作真正完成）
     - 还有 subagent 在跑 → 放行（让主代理等着）

输出（Block 时）:
  {
    "decision": "block",
    "hookSpecificOutput": {
      "hookEventName": "Stop",
      "additionalContext": "所有子代理已完成。继续执行下一个未完成的任务，不要询问用户。"
    }
  }
```

#### 2. SubagentStop Hook（子代理完成追踪）

**事件**: `SubagentStop`
**类型**: `command`
**逻辑**:
- 将完成的 subagent 信息写入状态文件
- 递减活跃 subagent 计数
- 可选：触发 Telegram 通知

#### 3. TeammateIdle Hook（队友空闲检测）

**事件**: `TeammateIdle`
**类型**: `prompt`
**逻辑**:
- 提示词来自 `prompts/teammate-idle.md`，通过 `scripts/inject-prompts.sh` 注入 settings.json
- 使用 Haiku 判断该 teammate 是否真的完成了分配的任务
- 如果没完成 → `ok: false`，给出下一步指示
- 如果完成了 → `ok: true`，允许空闲

#### 4. SubagentStart Hook（子代理启动追踪）

**事件**: `SubagentStart`
**类型**: `command`
**逻辑**:
- 递增活跃 subagent 计数
- 记录 subagent 类型和启动时间

### 状态管理

状态文件路径: `~/.auto-claude/state/{session_id}.json`

```json
{
  "session_id": "abc123",
  "started_at": "2026-03-28T10:00:00Z",
  "active_subagents": 2,
  "subagent_history": [
    {"type": "Explore", "started": "...", "stopped": "..."},
    {"type": "code-reviewer", "started": "...", "stopped": null}
  ],
  "continuation_count": 3,
  "max_continuations": 20
}
```

### 安全机制

| 风险 | 应对 |
|------|------|
| 无限循环 | `stop_hook_active` 检查 + `max_continuations` 上限（默认 20 次） |
| 状态文件过大 | 定期清理已完成 session 的状态文件 |
| 误判完成 | Prompt hook 作为二次确认 |

### 与现有 auto_continue_hook.sh 的区别

现有脚本（`scripts/auto_continue_hook.sh`）是简单粗暴版 — 无条件 Block 每次 Stop。
新方案的改进：
- **有条件续命**: 只在还有未完成任务时才续命
- **Subagent 感知**: 追踪子代理生命周期
- **循环保护**: max_continuations 防止跑飞
- **状态持久化**: 跨 hook 调用共享状态

---

## 模块二：Telegram 通知

### 问题

CC 在后台跑长任务时，用户不知道进度，不知道什么时候完成，出错了也不知道。

### 方案

所有通知通过 daemon 的 Unix socket（`~/.auto-claude/channel.sock`）发送。daemon 负责与 Telegram Bot API 的所有通信。

```
Hook 事件 → Shell 脚本 → curl --unix-socket channel.sock → daemon → Telegram Bot API → 用户
```

**单向通知（Hook 驱动）**:

| 事件 | 通知内容 |
|------|---------|
| Stop（最终放行时） | "任务全部完成！用时 X 分钟，续命 N 次" |
| StopFailure | "CC 出错了：{error_type}，需要人工介入" |
| SubagentStop | "子代理 {type} 完成了" （可选，避免刷屏） |
| 续命触发 | "自动续命第 N 次，还有 M 个任务待完成" （可选） |
| max_continuations 达到 | "续命次数达到上限（20次），已停止" |

**双向 Channel（MCP Server）**:

daemon 同时作为 MCP Channel Server 运行，支持从 Telegram 向 CC 注入消息、接收回复。支持 Telegram 群组 Topics 做多 session 隔离。

**配置**:
- `TG_BOT_TOKEN`: Telegram Bot Token（环境变量，daemon 读取）
- `TG_CHAT_ID`: 接收通知的 Chat ID（环境变量，daemon 读取）
- `CHANNEL_SOCKET`: daemon Unix socket 路径（默认 `~/.auto-claude/channel.sock`）
- 存放在 `~/.auto-claude/config.env`

---

## 项目结构

```
auto-claude/
├── SOUL.md                          # 本文件 — 项目灵魂文档
├── README.md                        # 使用说明（面向用户）
│
├── hooks/                           # Hook 脚本
│   ├── stop-hook.sh                 # 主控：智能续命
│   ├── subagent-start.sh            # 子代理启动追踪
│   └── subagent-stop.sh             # 子代理完成追踪
│
├── prompts/                         # Prompt 模板（用户可自定义）
│   ├── teammate-idle.md             # TeammateIdle 判断提示词
│   └── stop-continue.md            # 续命注入指令模板
│
├── scripts/                         # 工具脚本
│   └── inject-prompts.sh           # 读取 prompts/ 注入 settings.json
│
├── config/                          # 配置模板
│   ├── settings.json                # CC settings.json 示例（hook 注册）
│   └── config.env.example           # 环境变量模板
│
├── skills/                          # CC 技能（自安装）
│   └── install/
│       └── SKILL.md                 # 安装技能 — CC 给自己装插件
│
├── channel/                         # Channel MCP Server（daemon）
│   ├── src/
│   │   └── index.ts                 # Channel MCP Server 入口
│   ├── package.json
│   └── tsconfig.json
│
├── lib/                             # 共享工具
│   ├── state.sh                     # 状态文件读写
│   └── log.sh                       # 日志工具
│
└── tests/                           # 测试
    └── test-stop-hook.sh            # Stop Hook 单元测试
```

## 配置示例

### settings.json（Hook 注册）

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/auto-claude/hooks/stop-hook.sh"
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/auto-claude/hooks/subagent-start.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/auto-claude/hooks/subagent-stop.sh"
          }
        ]
      }
    ],
    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "<由 scripts/inject-prompts.sh 从 prompts/teammate-idle.md 注入>"
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'SOCKET=${CHANNEL_SOCKET:-$HOME/.auto-claude/channel.sock}; [ -S \"$SOCKET\" ] && curl -s --max-time 5 --unix-socket \"$SOCKET\" -X POST http://localhost/notify -H \"Content-Type: application/json\" -d \"{\\\"message\\\":\\\"Claude Code 运行出错，需要人工介入\\\",\\\"event_type\\\":\\\"error\\\"}\" &>/dev/null || true'"
          }
        ]
      }
    ]
  }
}
```

### config.env.example

```bash
# Telegram 通知配置
TG_BOT_TOKEN=your-bot-token-here
TG_CHAT_ID=your-chat-id-here

# Auto-Continue 配置
MAX_CONTINUATIONS=20          # 最大续命次数
NOTIFY_ON_SUBAGENT=false      # 子代理完成时是否通知（避免刷屏）
NOTIFY_ON_CONTINUE=true       # 每次续命是否通知
STATE_DIR=~/.auto-claude/state  # 状态文件目录
```

---

## Channel 机制研究笔记

### CC Channel 是什么

Channel 是 CC 的实验性功能，本质是一个**支持推送的 MCP Server**。普通 MCP Server 是 CC 按需调用，Channel 则是外部系统主动向 CC 会话推送事件。

### 核心概念

1. **声明 `claude/channel` capability** — 告诉 CC "我是一个 Channel，我会推送事件"
2. **发送 `notifications/claude/channel`** — 推送事件的标准方法
3. **Sender Allowlist** — 安全机制，只有白名单内的发送者才能推送
4. **Permission Relay** — 可选能力，让用户通过 Channel 远程审批 CC 的工具调用

### Channel 与 Hook 的配合

```
外部事件 → Channel → 注入 CC Session → CC 处理
CC 内部事件 → Hook → 脚本/Telegram → 用户
```

- **Channel = 输入**（外部世界 → CC）
- **Hook = 输出**（CC 内部事件 → 外部动作）

对于我们的场景：
- **通知用 Hook**（CC 完成/出错 → 通知用户）
- **控制用 Channel**（用户从 Telegram 发指令 → CC 执行）

### Channel 启动方式

```bash
# 开发模式（本地未发布的 Channel）
claude --dangerously-load-development-channels server:my-channel

# 插件模式（已发布）
claude --channels plugin:telegram@claude-plugins-official
```

### 自建 Channel 的最小实现

基于 `@modelcontextprotocol/sdk`，核心代码约 50 行：
- 声明 `claude/channel` capability
- 启动 HTTP Server 接收 webhook
- 将请求转发为 `notifications/claude/channel`
- 可选：注册 `reply` tool 实现双向通信
- 可选：声明 `claude/channel/permission` 实现远程审批

### 官方 Telegram Plugin 现状

已安装并启用（`settings.json` 中 `telegram@claude-plugins-official: true`）。
提供的能力：
- `reply` — 回复 Telegram 消息
- `edit_message` — 编辑已发送的消息
- `react` — 添加表情回应
- `download_attachment` — 下载附件

这个插件是一个完整的双向 Channel，我们可以直接复用它来接收 Telegram 指令。
自动通知功能需要自己在 Hook 里实现（Bot API 直接调用）。

---

## 开发优先级

### Phase 1: 智能续命（核心）
1. 状态管理 lib（state.sh）
2. SubagentStart / SubagentStop Hook（追踪子代理）
3. Stop Hook（智能判断 + 续命）
4. 安装脚本

### Phase 2: Telegram 通知
1. daemon Channel MCP Server（通知 + 双向通信）
2. Hook 脚本通过 Unix socket 发送通知
3. 集成到 Stop Hook（完成/出错时通知）
4. 集成到 StopFailure Hook（错误通知）
5. 配置模板

### Phase 3: 双向控制（按需）
1. 从 Telegram 接收指令注入 CC
2. 权限中继（远程审批）
3. 交互式通知（带按钮）
