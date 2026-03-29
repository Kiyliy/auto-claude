# Overnight Research Log — 2026-03-29

## What I did while the user slept

### 1. Multi-Level Scoring System (DONE)
- Designed 3-tier scoring: demo / mvp / pmf
- Each level has its own 10 dimensions calibrated to that tier
- GOAL.md gains a `## Level` field
- Deployed to remote server, CC noticed the change

### 2. Session Persistence (DONE)
- runner.py saves session ID to PROJECT/.auto-claude/session.json
- `--resume` flag reuses last session (same TG topic, same CC context)
- `--session-id` flag for explicit session reuse
- Verified: restart with --resume reused session 6e19998e + topic #331

### 3. Experiment Progress
- Twitter clone reached 100/100 (demo-level scoring) at Round 32
- 113 commits, 577+ tests, 132 src files
- CC found and is fixing real bugs:
  - Login page crashes in production (useSearchParams without Suspense)
  - Cookie secure flag breaks on HTTP
  - E2E tests fail due to production/dev mode mismatch

### 4. Experiment Stopped
- CC hit 100/100 and spun for 18 rounds doing nothing but scoring commits
- Stopped to save API credits
- 127 total commits, 48 scoring rounds
- Score journey: 92→93→94→95→96→97→98→99→100
- 577 unit tests + 68 E2E tests, all passing

### 5. Pending Issues
- [ ] mvp-level scoring too lenient — CC self-scores 100 without finding real bugs
- [ ] Need external validation mechanism (separate reviewer, not self-score)
- [ ] CC should auto-stop when score plateaus for N rounds (waste prevention)
- [ ] TG detailed reports still inconsistent (CC sometimes skips curl command)

### 6. Key Learnings
- Stop hooks DO fire in stream-json mode (confirmed by source + test)
- runner.py auto-continue + stop-hook.sh = double-loop (complementary, not conflicting)
- CC self-scores too generously — the "if you found 0 bugs you didn't test hard enough" instruction doesn't work. CC just says "0 bugs" anyway
- Multi-level scoring is the right direction but needs teeth:
  - demo → mvp transition should force CC to actually curl test every endpoint
  - pmf level needs external review (cross-model like ARIS)
- Session persistence via session.json + --resume works well
- NEXTAUTH_URL must match access URL or login breaks
- `next start` forces NODE_ENV=production regardless of env vars
- HSTS header (`max-age=63072000`) poisons browser cache for 2 years on HTTP servers
