# SleepShip Skills Guide

Practical playbook for using sleepship on any project — from scratch or mid-flight.

---

## Skill 1: Zero-to-App (build from nothing)

**When:** You have an idea but no code yet.

```bash
mkdir ~/myapp && cd ~/myapp
git init

# Write your GOAL.md
cat > GOAL.md << 'EOF'
# My App

## Goal
Build a task management app with real-time collaboration.

## Level
mvp

## Tech Stack
Next.js + TypeScript + Tailwind CSS + Prisma + SQLite

## Core Features
- [ ] User registration and login
- [ ] Create / edit / delete tasks
- [ ] Drag-and-drop kanban board
- [ ] Real-time updates via WebSocket
- [ ] Mobile-responsive layout

## Success Criteria
- Score >= 90/100
- All features working end-to-end
- `npm install && npm run dev` works on fresh clone

## Rules
- Git commit after each batch of changes
- Make decisions autonomously, do not stop to ask
- Prioritize fixing the lowest-scoring dimensions
EOF

# Launch
python3 /path/to/sleepship/runner.py --project .
```

Auto-claude will scaffold the project, implement features, test, get reviewed, and iterate until it passes.

---

## Skill 2: Feature Sprint (add to existing project)

**When:** You have a working codebase and want to add a major feature.

```bash
cd ~/existing-app

cat > GOAL.md << 'EOF'
# Payment Integration

## Goal
Add Stripe payment processing to the existing e-commerce app.

## Level
mvp

## Core Features
- [ ] Stripe checkout flow
- [ ] Payment confirmation page
- [ ] Order history with payment status
- [ ] Webhook handler for async events
- [ ] Refund support from admin panel

## Existing Context
- App runs on Next.js, already has user auth and product catalog
- Database: Prisma + PostgreSQL
- Start with: `npm run dev` on port 3000

## Success Criteria
- Score >= 90/100
- Existing features still work (no regressions)
- Stripe test mode checkout completes end-to-end

## Rules
- Do NOT rewrite existing code unless necessary
- Git commit after each batch of changes
- Run existing tests before and after changes
EOF

python3 /path/to/sleepship/runner.py --project .
```

**Key:** The `## Existing Context` section tells the agent what's already there so it doesn't reinvent the wheel.

---

## Skill 3: Bug Bash (fix and harden)

**When:** Your app works but has quality issues — bugs, missing error handling, test gaps.

```bash
cd ~/my-buggy-app

cat > GOAL.md << 'EOF'
# Quality Hardening

## Goal
Fix all known bugs, add missing error handling, and reach 80%+ test coverage.

## Level
pmf

## Known Bugs
- [ ] Login fails silently when server is down
- [ ] File upload crashes on files > 10MB
- [ ] Race condition in concurrent task updates
- [ ] Mobile nav menu doesn't close on route change

## Hardening Tasks
- [ ] Add error boundaries to all pages
- [ ] Add loading states to all async operations
- [ ] Input validation on all forms (client + server)
- [ ] Rate limiting on auth endpoints
- [ ] Add integration tests for core user flows

## Success Criteria
- Score >= 90/100
- Zero console errors during normal usage
- All known bugs fixed with regression tests

## Rules
- Write a test for each bug BEFORE fixing it
- Git commit after each fix (one bug per commit)
- Do not add new features
EOF

python3 /path/to/sleepship/runner.py --project . --target-score 90
```

---

## Skill 4: Prototype Race (fast demo, low bar)

**When:** You need a working demo fast — hackathon, pitch, proof of concept.

```bash
cat > GOAL.md << 'EOF'
# AI Chat Widget

## Goal
Build an embeddable AI chat widget that connects to OpenAI API.

## Level
demo

## Core Features
- [ ] Floating chat bubble in bottom-right corner
- [ ] Chat window with message history
- [ ] Stream AI responses in real-time
- [ ] Configurable system prompt
- [ ] Single-file embed script

## Success Criteria
- Score >= 70/100
- Happy path works: open chat → send message → get AI response
- Can embed in any page with one script tag

## Rules
- Speed over polish
- Skip auth, skip tests, skip mobile
- Single HTML file with inline JS/CSS is fine
EOF

python3 /path/to/sleepship/runner.py --project . --target-score 70 --max-turns 20
```

**Key:** `Level: demo` + `--target-score 70` + `--max-turns 20` = fast and loose.

---

## Skill 5: Refactor & Migrate

**When:** You need to migrate tech stack, refactor architecture, or upgrade major dependencies.

```bash
cat > GOAL.md << 'EOF'
# Migration: JavaScript → TypeScript

## Goal
Convert the entire codebase from JavaScript to TypeScript with strict mode.

## Level
mvp

## Migration Tasks
- [ ] Add tsconfig.json with strict: true
- [ ] Rename all .js/.jsx files to .ts/.tsx
- [ ] Add type annotations to all functions and components
- [ ] Replace `any` types with proper types
- [ ] Fix all TypeScript compiler errors
- [ ] Ensure all existing tests still pass

## Success Criteria
- Score >= 90/100
- Zero TypeScript errors with strict mode
- All existing tests pass
- No `any` types except in third-party type gaps

## Rules
- Migrate file-by-file, commit after each batch
- Do NOT change any business logic
- Do NOT add new features
- If a test breaks, fix the migration, not the test
EOF

python3 /path/to/sleepship/runner.py --project .
```

---

## Writing Effective GOAL.md

### Level matters

| Level | Bar | Reviewer expectation |
|-------|-----|---------------------|
| `demo` | Happy path works | Ignores edge cases, loose on polish |
| `mvp` | Daily use, no bugs | Tests core flows, checks error states |
| `pmf` | Production-ready | Full test coverage, security audit, performance |

### Feature checklist = contract

The `- [ ]` checkboxes are the reviewer's checklist. Each unchecked item costs **-3 points**. Be specific:

```markdown
# Bad — too vague
- [ ] User management

# Good — testable
- [ ] Register with email + password (validation: email format, password 8+ chars)
- [ ] Login with email + password (returns JWT, 401 on wrong credentials)
- [ ] Logout (clears token, redirects to login)
```

### Existing Context saves time

For existing projects, always include:

```markdown
## Existing Context
- Framework: Next.js 15 with App Router
- Database: Prisma + PostgreSQL (schema in prisma/schema.prisma)
- Auth: NextAuth.js with GitHub provider
- Start command: `npm run dev` (port 3000)
- Test command: `npm test`
```

This prevents the agent from guessing your stack or accidentally overwriting your setup.

### Rules shape behavior

```markdown
## Rules
- Git commit after each batch of changes          # progress tracking
- Make decisions autonomously, do not stop to ask  # no pausing for input
- Prioritize fixing the lowest-scoring dimensions  # smart iteration order
- Do NOT rewrite existing code unless necessary    # protect existing work
- Write tests before fixing bugs                   # TDD for bug fixes
```

---

## Tuning the Runner

| Flag | Default | When to change |
|------|---------|---------------|
| `--target-score` | 90 | Lower for demos (70), raise for production (95) |
| `--max-turns` | 100 | Lower for quick prototypes (20), raise for complex apps (200) |
| `--review-model` | claude-sonnet-4-6 | Use opus for harder reviews, haiku for faster/cheaper |
| `--review-timeout` | 1800 | Increase for large projects where review takes longer |

### Resume interrupted sessions

```bash
# SleepShip saves session state in PROJECT/.sleepship/session.json
python3 runner.py --project ~/myapp --resume
```

### Monitor via Telegram

Set up the channel daemon for real-time updates:
- Each turn's output is forwarded to your Telegram chat
- Review scores are posted after each review
- You can send messages back to inject instructions mid-run

---

## Patterns That Work

1. **Start with `demo`, upgrade to `mvp`** — get the shape right first, then harden
2. **One GOAL per session** — don't mix "add payments" with "fix auth bugs"
3. **Specific success criteria** — "login works" is vague; "POST /api/login returns 200 with JWT" is testable
4. **Include existing test commands** — the reviewer needs to know how to run your tests
5. **Set max-turns for prototypes** — prevents runaway iteration on throwaway code
