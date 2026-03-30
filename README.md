# auto-claude

GOAL.md-driven autonomous iteration for Claude Code.

## How it works

1. Write `GOAL.md` in your project — what to build, feature list, success criteria
2. Run `runner.py` — CC works autonomously in headless mode
3. After each turn, an independent Haiku agent reviews and scores the project
4. Score < 90 → CC keeps working. Score >= 90 → done.

## Setup

```bash
# 1. Install hook config
cp config/settings.json ~/.claude/settings.json

# 2. (Optional) Telegram notifications
mkdir -p ~/.auto-claude
cp config/config.env.example ~/.auto-claude/config.env
# Edit config.env with your bot token and chat ID

cd channel && npm install && cd ..
npx tsx channel/src/daemon.ts &
```

## Usage

```bash
# New project
python3 scripts/runner.py --project ~/myapp

# Resume previous session
python3 scripts/runner.py --project ~/myapp --resume
```

## Project structure

```
auto-claude/
├── scripts/runner.py       # Headless mode engine
├── prompts/scoring.md      # Scoring criteria for reviewer
├── config/settings.json    # Hook config (agent hook + Haiku)
├── channel/src/            # Telegram daemon
└── GOAL.md                 # Example goal (edit for your project)
```

## Scoring

10 dimensions, 0-10 each. Independent Haiku agent runs tests, curls endpoints, checks GOAL.md features.
Score < 90 → agent returns `{ok: false, reason: "..."}` → CC continues.
Score >= 90 → agent returns `{ok: true}` → CC stops.

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
