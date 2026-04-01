# auto-claude

Autonomous AI development framework built on [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Define a goal, let the agent build it, and an independent reviewer scores the result — iterating until it passes.

## How it works

```
GOAL.md  →  Claude Code (headless)  →  Independent Reviewer (Sonnet)
                    ↑                           ↓
                    └── feedback injection ──────┘
                         (score < 90 → keep going)
```

1. Write a `GOAL.md` in your project — features, success criteria, quality level
2. Run `runner.py` — Claude Code works autonomously in headless (`-p`) mode
3. After each turn, an independent Sonnet agent reviews and scores the project (10 dimensions, 0-100)
4. Score < 90 → feedback is injected back into CC → keeps working
5. Score >= 90 → done

## Quick start

```bash
# 1. Create a GOAL.md in your project
cp examples/GOAL.template.md ~/myapp/GOAL.md
# Edit it with your project spec

# 2. Run
python3 runner.py --project ~/myapp
```

## Setup

### Required
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Python 3.8+

### Optional: Telegram notifications

Real-time progress updates and bidirectional communication via Telegram.

```bash
mkdir -p ~/.auto-claude
cp config.env.example ~/.auto-claude/config.env
# Edit config.env with your bot token and chat ID

cd channel && npm install && cd ..
npx tsx channel/src/daemon.ts &
```

### Optional: Hook-based review (alternative to runner.py)

Instead of the runner, you can use Claude Code's native agent hook:

```bash
cp settings.example.json ~/.claude/settings.json
```

This configures a Stop hook that runs an independent Sonnet review whenever CC tries to stop. If the score is < 90, the hook blocks the stop and CC continues working.

## Usage

```bash
# New session
python3 runner.py --project ~/myapp

# Resume previous session
python3 runner.py --project ~/myapp --resume

# Custom options
python3 runner.py \
  --project ~/myapp \
  --review-model claude-sonnet-4-6 \
  --target-score 85 \
  --max-turns 50
```

## Project structure

```
auto-claude/
├── runner.py                  # Headless mode engine + review loop
├── scoring.md                 # 10-dimension scoring rubric
├── config.env.example         # Telegram configuration template
├── settings.example.json      # Claude Code agent hook config
├── channel/src/               # Telegram notification daemon
│   ├── daemon.ts              # HTTP API + TG long-polling
│   ├── telegram.ts            # Telegram Bot API helpers
│   └── config.ts              # Configuration loader
└── LICENSE
```

## Scoring

10 dimensions, 0-10 each (max 100):

| # | Dimension | What it measures |
|---|-----------|-----------------|
| 1 | Goal Completion | Every GOAL.md feature actually works |
| 2 | UI/UX Quality | Consistent, polished, no glitches |
| 3 | Responsive Design | Works on mobile/tablet/desktop |
| 4 | Functional Correctness | Core flows work end-to-end |
| 5 | Code Quality | Type-safe, no dead code, consistent patterns |
| 6 | Test Coverage | Core logic tested, tests pass |
| 7 | Error Handling | User-friendly errors, loading states |
| 8 | Security | Auth, input sanitization, no secrets leaked |
| 9 | Documentation | README, .env.example, setup instructions |
| 10 | Runnability | One-command start, works on fresh clone |

The reviewer actually runs the project (starts servers, curls endpoints, runs tests) — not just code review.

## GOAL.md format

```markdown
# Project Name

## Goal
Build X.

## Level
mvp

## Core Features
- [ ] Feature 1
- [ ] Feature 2

## Success Criteria
- Score >= 90/100
```

## Architecture

**Runner mode** (`runner.py`): Python process manages the CC lifecycle. Spawns CC in `--input-format stream-json` mode, reads result events, runs independent review, and injects feedback via stdin. Also polls the Telegram daemon for human messages.

**Hook mode** (`review-hook.sh` / `settings.json`): Uses CC's native agent hook on the Stop event. Lighter weight — CC manages itself, the hook just gates when it's allowed to stop.

**Telegram daemon** (`channel/`): Node.js process that provides a Unix socket HTTP API. Manages Telegram long-polling, session-to-topic routing, and message queues. Enables bidirectional human-in-the-loop communication.

## License

MIT
