# auto-claude

> GOAL.md-driven autonomous iteration engine for Claude Code — write one goal file, CC works until it's done.

## How It Works

1. You write a `GOAL.md` in your project root — what to build, feature checklist, success criteria
2. Auto-Claude makes CC iterate autonomously, scoring each round against GOAL.md
3. Each round: CC works → scoring prompt evaluates → below target: keep going → at target: stop
4. Score trends are tracked in `.auto-claude/results.jsonl`

## Quick Start

### 1. Create GOAL.md in your project

```markdown
# My App

## Goal
Build a pixel-perfect Twitter clone, production-ready.

## Tech Stack
Next.js + TypeScript + Tailwind CSS + Prisma

## Core Features
- [ ] Register / Login
- [ ] Post tweets (text + images)
- [ ] Like / Retweet / Bookmark
- [ ] Follow / Unfollow
- [ ] Profile page
- [ ] Search
- [ ] Responsive design

## Success Criteria
- Score >= 90/100

## Rules
- Git commit after each batch of changes
- Make decisions autonomously
- Prioritize fixing lowest-scoring dimensions
- Append scoring results to .auto-claude/results.jsonl
```

See [templates/GOAL.example.md](templates/GOAL.example.md) for the full template.

### 2. Choose a mode

**Headless mode** (runs in background):
```bash
python3 auto-claude/scripts/runner.py --project ~/projects/my-app
```

**Interactive mode** (terminal):
```bash
cd ~/projects/my-app
claude
> Read GOAL.md and start working
```

Both modes use the same hooks and scoring system.

### 3. Watch progress

```bash
# Score trends
cat ~/projects/my-app/.auto-claude/results.jsonl | python3 -c "
import json, sys
for l in sys.stdin:
    e = json.loads(l)
    print(f\"Round {e.get('round','?')}: {e.get('total','?')}/100 — worst: {', '.join(e.get('worst',[]))}\")"

# Live log
tail -f ~/auto-claude-test.log
```

## Installation

```bash
git clone https://github.com/Kiyliy/auto-claude.git
cd auto-claude

# Configure
mkdir -p ~/.auto-claude/{state,logs}
cp config/config.env.example ~/.auto-claude/config.env
# Edit config.env: set TG_BOT_TOKEN and TG_CHAT_ID

# Inject scoring prompt into CC settings
bash scripts/inject-prompts.sh

# (Optional) Start Telegram daemon
cd channel && npm install && cd ..
npx tsx channel/src/daemon.ts &
```

## Scoring System

10 universal dimensions, 0-10 each, max 100:

| # | Dimension | Description |
|---|-----------|-------------|
| 1 | Goal Completion | Check GOAL.md feature list item by item |
| 2 | UI/UX Quality | Match UI reference if specified |
| 3 | Responsive | Desktop / tablet / mobile |
| 4 | Runtime Stability | Zero console errors |
| 5 | Code Quality | Zero build errors, type-safe |
| 6 | Test Coverage | Core logic tested |
| 7 | Error Handling | Loading / error / empty states |
| 8 | Security | Env vars, input validation |
| 9 | Documentation | README + .env.example |
| 10 | Runnability | One-command start |

Scoring requires running build, tests, and dev server first. Results append to `.auto-claude/results.jsonl`.

## Project Structure

```
auto-claude/
├── GOAL.md                    # Test goal (Twitter clone)
├── templates/GOAL.example.md  # GOAL.md template for users
├── scripts/runner.py          # Headless mode engine
├── hooks/stop-hook.sh         # Continuation controller
├── prompts/
│   ├── scoring.md             # Generic scoring (reads GOAL.md)
│   ├── continue.md            # Continuation prompt (with trends)
│   └── teammate-idle.md
├── channel/src/               # Telegram daemon
├── config/                    # Hook registration + env vars
└── lib/                       # State management + logging
```

## Configuration

`~/.auto-claude/config.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TG_BOT_TOKEN` | — | Telegram Bot Token (required) |
| `TG_CHAT_ID` | — | Chat ID (required) |
| `MAX_CONTINUATIONS` | 20 | Max continuations per session |
| `MAX_CONSECUTIVE_BLOCKS` | 10 | Max consecutive blocks before allowing one stop |
| `NOTIFY_ON_CONTINUE` | true | Notify on each continuation |

## Runner CLI

```
python3 runner.py --project PATH [--goal GOAL.md] [--max-turns 100] [--mcp-config FILE]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--project` | (required) | Project directory with GOAL.md |
| `--goal` | GOAL.md | Goal filename |
| `--max-turns` | 100 | Max rounds |
| `--mcp-config` | — | MCP config for Telegram etc. |

## License

MIT
