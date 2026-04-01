# sleepship

> **Sleep. Ship.**

Define the goal, go to sleep, wake up to a shipped app.

Autonomous AI development framework built on [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Core Idea

A simple syllogism:

1. **Any goal can be scored.** Whether it's "build a login page" or "migrate to TypeScript" — you can verify the result through tests, endpoint checks, or end-to-end usage, and convert that into a number.
2. **AI can improve iteratively toward a target score.** Given specific feedback ("auth returns 401", "3 tests failing", "core flow broken"), an LLM can diagnose and fix — just like a human developer reading a code review.
3. **Therefore, build the loop.** If the goal is scorable and the agent is improvable, the only thing missing is the loop: work → score → feedback → repeat until pass.

That's all sleepship is: **the loop**.

You define the goal (`GOAL.md`), the framework scores it through a three-level review (L1 basics → L2 modules → L3 quality, each must hit 100), and feeds the result back. The agent keeps working until all three levels pass — or you tell it to stop.

## How it works

```
GOAL.md  →  Claude Code (headless)  →  Independent Reviewer (Sonnet)
                    ↑                           ↓
                    └── feedback injection ──────┘
                    (L1/L2/L3 any < 100 → keep going)
```

1. Write a `GOAL.md` in your project — features, success criteria, quality level
2. Run `runner.py` — Claude Code works autonomously in headless (`-p`) mode
3. After each turn, an independent Sonnet agent runs a three-level review
4. Any level < 100 → feedback is injected back → keeps working
5. All three levels = 100 → done

## Quick start

```bash
# 1. Create a GOAL.md in your project (see GOAL.index.md for template)
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
mkdir -p ~/.sleepship
cp config.env.example ~/.sleepship/config.env
# Edit config.env with your bot token and chat ID

cd channel && npm install && cd ..
npx tsx channel/src/daemon.ts &
```

### Optional: Hook-based review (alternative to runner.py)

Instead of the runner, you can use Claude Code's native agent hook:

```bash
cp settings.example.json ~/.claude/settings.json
```

This configures a Stop hook that runs an independent Sonnet review whenever CC tries to stop. If it doesn't pass, the hook blocks the stop and CC continues working.

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
  --max-turns 50
```

## Project structure

```
sleepship/
├── runner.py                  # Headless mode engine + review loop
├── scoring.md                 # Three-level scoring rubric (L1/L2/L3)
├── SKILLS.md                  # Agent operational manual (3 phases)
├── GOAL.index.md              # GOAL.md template for new projects
├── agentloop.md               # Agent loop discipline (team, skills, failure handling)
├── config.env.example         # Telegram configuration template
├── settings.example.json      # Claude Code agent hook config
├── channel/src/               # Telegram notification daemon
│   ├── daemon.ts              # HTTP API + TG long-polling
│   ├── telegram.ts            # Telegram Bot API helpers
│   └── config.ts              # Configuration loader
└── LICENSE
```

## Scoring

Three-level review, each scored 0-100. All three must hit 100 to pass.

| Level | What it checks | Pass condition |
|-------|---------------|----------------|
| **L1: Basics** | Can it start? Are all features real (no mock/TODO/fallback)? Build passes? | = 100 |
| **L2: Modules** | Each feature tested end-to-end. Edge cases, error paths, module integration. | = 100 |
| **L3: Quality** | Code quality, security, test coverage, documentation. | = 100 |

Upper level gates lower: L1 fail → skip L2/L3.

The reviewer actually runs the project (starts servers, curls endpoints, calls contracts, runs tests) — not just code review. See [scoring.md](scoring.md) for full rubric.

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
- Three-level review all pass (L1/L2/L3 = 100)

## Agent Loop
See agentloop.md

## Rules
- Git commit after each batch of changes
- Make decisions autonomously, do not stop to ask
```

See [GOAL.index.md](GOAL.index.md) for full template.

## Architecture

**Runner mode** (`runner.py`): Python process manages the CC lifecycle. Spawns CC in `--input-format stream-json` mode, reads result events, runs independent review, and injects feedback via stdin. Also polls the Telegram daemon for human messages.

**Hook mode** (`settings.json`): Uses CC's native agent hook on the Stop event. Lighter weight — CC manages itself, the hook just gates when it's allowed to stop.

**Telegram daemon** (`channel/`): Node.js process that provides a Unix socket HTTP API. Manages Telegram long-polling, session-to-topic routing, and message queues. Enables bidirectional human-in-the-loop communication.

## License

MIT
