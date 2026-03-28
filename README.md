# auto-claude

> Extend Claude Code's continuous working capability with smart hooks and Telegram integration.

Auto-Claude 是一组 Claude Code (CC) 的 Hook 脚本和可选的 MCP Channel 服务，让 CC 在完成阶段性工作后自动判断是否继续、通过 Telegram 推送关键事件、并支持从 Telegram 反向与 CC 对话。它不是独立应用，而是基于 CC Hook 系统的插件式增强。

---

## 核心能力

| 能力 | 说明 |
|------|------|
| **智能续命** | Stop Hook 拦截 CC 停止事件，结合 Subagent 生命周期和续命计数，自动决定是否注入继续指令 |
| **Telegram 通知** | 任务完成、错误、续命等关键事件通过 Telegram Bot 推送，无需额外服务 |
| **双向 Channel** | 可选的 MCP Server，支持从 Telegram 群组/Topic 向 CC 发送指令并接收回复 |

---

## 快速开始

```bash
# 1. Clone
git clone https://github.com/Kiyliy/auto-claude.git

# 2. 在 Claude Code 中运行安装技能
/auto-claude-install
```

安装技能会自动完成：创建 `~/.auto-claude/` 目录、交互式配置 Telegram 凭据、注册 Hook 到 settings.json、验证安装结果。

---

## 工作原理

### 智能续命

CC 主代理每次停止时触发 Stop Hook，接收包含 `session_id`、`stop_hook_active` 等字段的 JSON。Hook 按以下逻辑决策：

```
CC 停止
  |
  v
stop_hook_active = true ?
  |                |
  YES              NO
  |                |
  v                v
连续 block 计数+1   读取 session 状态
  |                |
  v                v
>= MAX_CONSECUTIVE   有活跃 subagent?
_BLOCKS (默认10)?    |          |
  |        |        YES         NO
  YES      NO       |          |
  |        |        v          v
  v        |     放行 Stop   续命次数 >= MAX
强制放行    |     (等待完成)  _CONTINUATIONS?
重置计数    |                  |        |
           |                 YES       NO
           v                  |        |
        继续正常判断 --------->|        v
                              v     Block Stop
                           放行 Stop  注入继续指令
                           发送通知   count++
```

**关键参数：**

- `MAX_CONSECUTIVE_BLOCKS` -- 连续 block 上限（默认 10）。CC 被 block 后再次停止时 `stop_hook_active=true`，计数累加；未达上限则可继续 block，达到上限则强制放行一轮。这意味着 CC 可以一口气连续干 10 轮不停歇。
- `MAX_CONTINUATIONS` -- 单 session 总续命上限（默认 20）。达到后彻底停止并通知。

**Subagent 生命周期追踪：**

| Hook | 触发时机 | 动作 |
|------|---------|------|
| `SubagentStart` | 子代理启动 | `active_subagents++`，记录启动时间 |
| `SubagentStop` | 子代理完成 | `active_subagents--`，可选通知 |
| `TeammateIdle` | 队友进入空闲 | Prompt Hook 判断是否真正完成，未完成则拒绝空闲 |

Session 状态持久化在 `~/.auto-claude/state/{session_id}.json`，通过 `lib/state.sh` 读写。

### Telegram 通知

**单向通知（始终可用）**

Hook 脚本通过 `hooks/notify.sh` 直接调用 Telegram Bot API。无需额外服务，只需 `curl` 和正确的 Bot Token / Chat ID。

通知事件：

| 事件 | 内容 | 默认 |
|------|------|------|
| Stop（最终放行） | 任务完成，用时 X 分钟，续命 N 次 | 开启 |
| StopFailure | CC 出错，需人工介入 | 开启 |
| 续命触发 | 自动续命第 N 次 | `NOTIFY_ON_CONTINUE` 控制 |
| SubagentStop | 子代理完成 | `NOTIFY_ON_SUBAGENT` 控制 |
| 续命上限 | 续命次数达到上限，已停止 | 开启 |

**双向 Channel（可选）**

基于 MCP Server 的双向通信。启用后 Telegram 消息会注入 CC 会话，CC 可直接回复。支持 Telegram 群组 Topics 做多 session 隔离。

`notify.sh` 会自动检测 Channel daemon 是否在线（通过 Unix socket `~/.auto-claude/channel.sock`），在线走 socket，离线回退到直连 Telegram API。

### 多 Session 支持

Channel 服务作为常驻 daemon 运行，每个 CC session 映射到一个 Telegram Topic。不同 session 的消息互不干扰，适合同时运行多个 CC 实例的场景。

---

## 配置

`~/.auto-claude/config.env` 变量列表：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TG_BOT_TOKEN` | -- | Telegram Bot Token，必填 |
| `TG_CHAT_ID` | -- | 接收通知的 Chat ID，必填 |
| `MAX_CONTINUATIONS` | `20` | 单 session 最大续命次数 |
| `MAX_CONSECUTIVE_BLOCKS` | `10` | 连续 block 上限，值越大一口气干更多轮 |
| `NOTIFY_ON_SUBAGENT` | `false` | 子代理完成时是否通知（并行多时建议关闭） |
| `NOTIFY_ON_CONTINUE` | `true` | 每次续命时是否通知 |
| `CHANNEL_SOCKET` | `~/.auto-claude/channel.sock` | Channel daemon Unix socket 路径 |
| `STATE_DIR` | `~/.auto-claude/state` | 状态文件目录 |
| `LOG_DIR` | `~/.auto-claude/logs` | 日志目录 |

---

## 安装细节

### 手动安装

```bash
# 创建目录
mkdir -p ~/.auto-claude/{state,logs}

# 复制并编辑配置
cp auto-claude/config/config.env.example ~/.auto-claude/config.env
vim ~/.auto-claude/config.env

# 设置权限
chmod +x auto-claude/hooks/*.sh
```

### Hook 注册

将以下内容合并到 `.claude/settings.local.json`（路径替换为实际绝对路径）：

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/auto-claude/hooks/stop-hook.sh"
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/auto-claude/hooks/subagent-start.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/auto-claude/hooks/subagent-stop.sh"
          }
        ]
      }
    ],
    "TeammateIdle": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "prompt",
            "prompt": "检查这个 teammate 是否完成了分配的任务。未完成返回 {\"ok\": false, \"reason\": \"...\"}, 已完成返回 {\"ok\": true}。"
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/auto-claude/hooks/notify.sh error"
          }
        ]
      }
    ]
  }
}
```

### Channel 服务（可选）

```bash
cd auto-claude/channel
npm install
```

注册 MCP Server（合并到 `.claude/settings.local.json`）：

```json
{
  "mcpServers": {
    "auto-claude-telegram": {
      "command": "npx",
      "args": ["tsx", "/path/to/auto-claude/channel/src/index.ts"]
    }
  }
}
```

CC 启动时会自动拉起 Channel 服务。

---

## 项目结构

```
auto-claude/
├── hooks/                   # Hook 脚本
│   ├── stop-hook.sh         # 主控：智能续命决策
│   ├── subagent-start.sh    # 子代理启动追踪
│   ├── subagent-stop.sh     # 子代理完成追踪
│   └── notify.sh            # Telegram 通知封装
├── lib/                     # 共享库
│   ├── state.sh             # 状态文件读写 (jq + flock)
│   └── log.sh               # 日志接口
├── config/                  # 配置模板
│   ├── settings.json        # Hook 注册示例
│   └── config.env.example   # 环境变量模板
├── skills/                  # CC 技能
│   └── install/SKILL.md     # /auto-claude-install
├── channel/                 # MCP Channel Server (可选)
│   ├── src/
│   ├── package.json
│   └── tsconfig.json
├── SOUL.md                  # 设计文档
└── README.md
```

---

## FAQ

### Hook 没触发？

1. 运行 `/hooks` 确认 Hook 已注册
2. 检查脚本权限：`chmod +x hooks/*.sh`
3. 确认 settings.json 中使用的是绝对路径
4. 查看日志：`tail -f ~/.auto-claude/logs/auto-claude.log`

### 出现无限循环？

三层保护：`consecutive_blocks`（连续上限，默认 10 次后放行）、`max_continuations`（总上限，默认 20 次后停止）、`session_id` 字符白名单防路径穿越。手动恢复：

```bash
rm ~/.auto-claude/state/*.json
```

### Telegram 收不到通知？

```bash
# 手动测试连通性
source ~/.auto-claude/config.env
curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TG_CHAT_ID}" -d text="test"
```

确认 Token/Chat ID 正确、服务器能访问 `api.telegram.org`、bot 未被 block。

### 如何查看日志？

```bash
tail -f ~/.auto-claude/logs/auto-claude.log        # 实时
grep "\[ERROR\]" ~/.auto-claude/logs/auto-claude.log  # 按级别
```

日志格式：`[timestamp] [LEVEL] [hook_name] message`

---

## 前置条件

| 依赖 | 说明 |
|------|------|
| Claude Code | CLI 已安装 (`claude --version`) |
| jq | JSON 处理 (`apt install jq` / `brew install jq`) |
| curl | 调用 Telegram API（通常系统自带） |
| Node.js | 仅 Channel 服务需要 |

---

## License

MIT -- see [LICENSE](LICENSE)
