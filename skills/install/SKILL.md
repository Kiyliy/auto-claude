---
name: auto-claude-install
description: |
  安装和配置 Auto-Claude 套件。自动注册 Hook、创建目录结构、配置 Telegram 通知。
  用 Claude Code 给自己装插件 — CC 读取配置模板，合并到自己的 settings 里。
  Use when: "安装 auto-claude", "install auto-claude", "配置续命 hook",
  "setup auto-continue", "配置 telegram 通知"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

# Auto-Claude 安装技能

你正在帮用户安装 Auto-Claude 套件。按以下步骤执行：

## 第一步：定位项目目录

找到 auto-claude 项目根目录。它应该包含 `hooks/`、`lib/`、`config/` 和 `SOUL.md`。

```bash
# 从当前工作目录或已知位置查找
AUTO_CLAUDE_DIR=$(find "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")" -maxdepth 3 -type f -name "SOUL.md" -path "*/auto-claude/*" -exec dirname {} \; 2>/dev/null | head -1)
echo "AUTO_CLAUDE_DIR: ${AUTO_CLAUDE_DIR:-NOT_FOUND}"
```

如果找不到，用 AskUserQuestion 问用户 auto-claude 目录在哪里。

## 第二步：检查依赖

```bash
echo "=== 依赖检查 ==="
command -v jq >/dev/null 2>&1 && echo "jq: OK" || echo "jq: MISSING"
command -v curl >/dev/null 2>&1 && echo "curl: OK" || echo "curl: MISSING"
command -v bash >/dev/null 2>&1 && echo "bash: OK" || echo "bash: MISSING"
```

如果 `jq` 缺失，告诉用户需要安装：`apt install jq` 或 `brew install jq`。
如果 `curl` 缺失，同理。这两个是必须的。

## 第三步：创建目录结构

```bash
mkdir -p ~/.auto-claude/state
mkdir -p ~/.auto-claude/logs
echo "目录结构已创建"
ls -la ~/.auto-claude/
```

## 第四步：配置 Telegram（可选）

用 AskUserQuestion 问用户：

> 是否配置 Telegram 通知？配置后 CC 完成任务、出错、续命时会自动推送通知到你的 Telegram。
>
> 1. 配置 — 我有 Bot Token 和 Chat ID
> 2. 跳过 — 以后再配
> 3. 教我怎么弄 — 我还没有 Bot

**如果选 1（配置）：**
- 再用 AskUserQuestion 问 Bot Token
- 再问 Chat ID
- 写入 `~/.auto-claude/config.env`

**如果选 3（教我）：**
告诉用户：
1. Telegram 搜索 @BotFather，发送 `/newbot`
2. 按提示设置名称，获得 Bot Token
3. 给 bot 发一条消息，然后访问 `https://api.telegram.org/bot<TOKEN>/getUpdates` 获取 Chat ID
4. 拿到后再次运行此技能

**如果选 2（跳过）：**
从 `config/config.env.example` 复制一份到 `~/.auto-claude/config.env`，保留默认值。

写入 config.env 的格式：

```bash
cat > ~/.auto-claude/config.env << 'ENVEOF'
# Auto-Claude 配置文件
# Telegram 通知
TG_BOT_TOKEN=${用户输入的token或空}
TG_CHAT_ID=${用户输入的chat_id或空}

# 续命配置
MAX_CONTINUATIONS=20
MAX_CONSECUTIVE_BLOCKS=10
NOTIFY_ON_SUBAGENT=false
NOTIFY_ON_CONTINUE=true

# 目录
STATE_DIR=~/.auto-claude/state
LOG_DIR=~/.auto-claude/logs
ENVEOF
```

## 第四(b)步：配置续命参数

用 AskUserQuestion 问用户：

> 续命参数配置：
>
> **MAX_CONSECUTIVE_BLOCKS** — CC 被 block 续命后会再次 stop 并带上 stop_hook_active=true。
> 这个参数控制允许连续 block 多少次才强制放行一轮。
> - 值越大 → CC 一口气干更多轮不停歇
> - 值越小 → CC 每隔几轮会暂停一下
> - 默认: 10
>
> **MAX_CONTINUATIONS** — 整个 session 的总续命次数上限。达到后彻底停止。
> - 默认: 20
>
> 是否使用默认值？
> 1. 使用默认值（MAX_CONSECUTIVE_BLOCKS=10, MAX_CONTINUATIONS=20）
> 2. 自定义

如果选 2，分别问两个值，写入 config.env。

## 第四(c)步：安装双向 Telegram Channel（可选）

用 AskUserQuestion 问用户：

> 是否启用双向 Telegram Channel？
>
> 启用后，你可以从 Telegram 直接发消息给 CC，CC 也能回复你。
> 不启用的话，通知功能仍然正常工作（单向推送）。
>
> 1. 启用 — 安装 Channel MCP Server
> 2. 跳过 — 只用单向通知

**如果选 1（启用）：**

```bash
cd "$AUTO_CLAUDE_DIR/channel"
npm install
echo "Channel 依赖安装完成"
```

后续在第六步注册 Hook 时，也需要同时注册 mcpServers 配置（见 config/settings.json 中的 mcpServers 部分）。

启动方式告知用户：
- 自动启动：CC 启动时会根据 settings.json 中的 mcpServers 配置自动启动 Channel 服务
- 或使用 `--channels` 参数：`claude --channels server:auto-claude-telegram`

**如果选 2（跳过）：**
跳过 Channel 安装。Hook 通知会直接 curl Telegram Bot API（路径 A），不影响续命功能。

## 第五步：设置 Hook 脚本权限

```bash
chmod +x "$AUTO_CLAUDE_DIR"/hooks/*.sh
chmod +x "$AUTO_CLAUDE_DIR"/lib/*.sh
echo "脚本权限已设置"
```

## 第六步：注册 Hook 到 Claude Code Settings

这是最关键的一步。需要把 auto-claude 的 hook 配置安全地合并到用户现有的 CC settings 中，**不能破坏用户已有的 hook**。

**目标文件**：项目级别 `.claude/settings.local.json`（优先）或 `.claude/settings.json`

**操作逻辑**：

### 6.1 读取现有配置，检测冲突

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.local.json"
[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"
[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.local.json"

echo "目标 settings 文件: $SETTINGS_FILE"

# 如果文件存在，检查已有 hook
if [ -f "$SETTINGS_FILE" ]; then
  EXISTING_HOOKS=$(jq -r '.hooks // {} | keys[]' "$SETTINGS_FILE" 2>/dev/null)
  echo "用户已有的 hook 事件: ${EXISTING_HOOKS:-无}"
fi
```

### 6.2 逐个事件检测冲突

我们要注册的 hook 事件：`Stop`, `SubagentStart`, `SubagentStop`, `TeammateIdle`, `StopFailure`

对于**每个事件**，检查用户是否已有同名事件的 hook：

- **没有冲突**（该事件下无已有 hook）→ 直接添加
- **有冲突**（该事件下已有 hook）→ 需要特殊处理：

用 AskUserQuestion 展示冲突详情，让用户选择：

> 检测到你已有以下 Hook 配置：
>
> **Stop 事件** 已有 hook:
> ```
> {展示已有的 hook command/prompt}
> ```
>
> Auto-Claude 也需要在 Stop 事件上注册 hook。请选择：
> 1. **追加** — 保留已有 hook，把 auto-claude 的 hook 追加到同一事件的数组中（两个 hook 会并行执行）
> 2. **替换** — 用 auto-claude 的 hook 替换已有的
> 3. **跳过** — 不注册这个事件的 hook（该模块功能将不可用）

**重要**：CC 的 hook 机制允许同一事件注册多个 hook（数组中的多个元素），它们会并行执行。所以"追加"是安全的默认选项。

### 6.3 执行合并

```bash
# 读取模板并替换路径
HOOKS_JSON=$(cat "$AUTO_CLAUDE_DIR/config/settings.json" | sed "s|/path/to/auto-claude|$AUTO_CLAUDE_DIR|g")

# 如果文件不存在，创建空 JSON
mkdir -p "$(dirname "$SETTINGS_FILE")"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
```

**追加模式**（默认，保留已有 hook）：
对每个事件，将 auto-claude 的 hook 条目 append 到该事件的数组末尾，而不是覆盖整个事件。

```bash
# 逐个事件追加，而不是整体合并
# 对于 Stop 事件：把 auto-claude 的 Stop hook 追加到已有的 Stop 数组
# jq: .hooks.Stop += [new_hook_entry]
```

**替换模式**（用户选择替换时）：
直接覆盖该事件的 hook 数组。

### 6.4 设置 Agent Team 环境变量

```bash
# 确保 env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS 存在
MERGED=$(jq '.env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"' "$SETTINGS_FILE")
echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
```

### 6.5 备份与确认

合并前：
1. 备份原文件：`cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak.$(date +%s)"`
2. 告诉用户将要修改哪个文件
3. 展示将要添加的 hook 列表（事件名 + command/prompt 摘要）
4. 展示冲突处理结果（追加/替换/跳过）
5. 让用户确认后再写入

## 第七步：验证安装

```bash
echo "=== 安装验证 ==="
echo "1. 目录结构:"
ls ~/.auto-claude/
echo ""
echo "2. 配置文件:"
[ -f ~/.auto-claude/config.env ] && echo "config.env: OK" || echo "config.env: MISSING"
echo ""
echo "3. Hook 脚本:"
for f in stop-hook.sh subagent-start.sh subagent-stop.sh notify.sh; do
  [ -x "$AUTO_CLAUDE_DIR/hooks/$f" ] && echo "$f: OK" || echo "$f: MISSING/NOT_EXECUTABLE"
done
echo ""
echo "4. Settings 注册:"
cat "$SETTINGS_FILE" | jq '.hooks | keys'
```

## 第八步：完成提示

安装完成后告诉用户：

- Hook 已注册，下次启动 CC 生效（或重新加载当前 session）
- 可以用 `/hooks` 命令验证 hook 是否被识别
- Telegram 通知配置状态（已配置 / 未配置）
- 如需调整续命次数等参数，编辑 `~/.auto-claude/config.env`
- 推荐以 Agent Team 模式工作以获得最佳效果（需要 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`）

## 注意事项

- 整个过程中遇到任何不确定的地方，用 AskUserQuestion 确认
- 不要覆盖用户已有的 hook 配置，只追加
- 所有路径使用绝对路径
- 如果用户已经安装过，检测到已有配置时提示是否覆盖
