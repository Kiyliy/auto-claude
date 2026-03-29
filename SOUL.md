# Auto-Claude

> GOAL.md-driven autonomous iteration engine for Claude Code

## Core Concept

User writes a `GOAL.md` in their project root — defines what to build, feature checklist, success criteria.
Auto-Claude makes CC iterate autonomously, scoring each round, until the target is met.

```
User writes GOAL.md → CC reads it and starts working → scoring → below target: continue → at target: stop
```

## Two Modes

### Headless Mode (-p)
```bash
python3 runner.py --project ~/projects/twitter-clone
```
runner.py reads GOAL.md, spawns CC in stream-json mode, auto-continues, bridges Telegram messages.

### Interactive Mode (CLI)
```bash
cd ~/projects/twitter-clone
claude
> Read GOAL.md and start working
```
CC hooks handle scoring and continuation automatically.

Both modes share the same hooks and prompts.

## Architecture

```
user-project/
├── GOAL.md                  ← User writes: goals + feature checklist + rules
└── .auto-claude/
    └── results.jsonl        ← Per-round scores appended automatically

auto-claude/
├── scripts/runner.py        ← Headless mode engine
├── hooks/stop-hook.sh       ← Continuation controller (both modes)
├── prompts/
│   ├── scoring.md           ← Generic scoring (reads GOAL.md)
│   ├── continue.md          ← Continuation prompt (with score trends)
│   └── teammate-idle.md
├── templates/GOAL.example.md ← GOAL.md template
├── channel/                  ← Telegram daemon
├── config/                   ← Hook registration + env vars
└── lib/                      ← State management + logging
```

## Scoring System

10 universal dimensions, 0-10 each, max 100:

| # | Dimension | Description |
|---|-----------|-------------|
| 1 | Goal Completion | Check GOAL.md feature list item by item |
| 2 | UI/UX Quality | Match UI reference if specified, else check consistency |
| 3 | Responsive | Desktop / tablet / mobile breakpoints |
| 4 | Runtime Stability | Zero console errors |
| 5 | Code Quality | Zero build errors, type-safe |
| 6 | Test Coverage | Core logic tested |
| 7 | Error Handling | Loading / error / empty states |
| 8 | Security | Env vars, input validation, auth |
| 9 | Documentation | README + .env.example |
| 10 | Runnability | One-command start |

Must run build/test/start before scoring. Results append to `results.jsonl`.

## Iteration Loop

```
CC works → tries to stop → scoring prompt evaluates
    │
    ├─ below target → CC continues improving
    │
    └─ at target → stop-hook.sh
                      │
                      ├─ under max continuations → block + inject continue (with trend)
                      │
                      └─ at max continuations → allow stop
```

Continuation prompt includes score trends:
```
Last score: 67/100
Trend: 53 → 61 → 67
Lowest: ui_ux, test_coverage
Prioritize fixing lowest dimensions.
```

## Git Management

- CC commits after each batch of changes
- Auto-commit after scoring: `[auto-claude] round N: score X/100`
- No reset — score trends drive improvement direction

## Telegram

Daemon process on Unix socket. Notifications for continuation/completion/errors. Bidirectional: user messages from Telegram injected into CC stdin. Multi-session via group Topics.
