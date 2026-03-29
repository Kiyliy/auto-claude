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

### 4. Pending Issues
- [ ] TG reports still go to General sometimes (CC doesn't always use daemon /reply)
- [ ] mvp-level scoring not yet triggered (CC still in first turn)
- [ ] stop-hook.sh path placeholder in settings.json (/path/to/auto-claude)
- [ ] HSTS header removal needed for HTTP deployments
- [ ] E2E tests broken in production mode

### 5. Key Learnings
- Stop hooks DO fire in stream-json mode (confirmed by source analysis + test)
- But runner.py auto-continue creates a double-loop with stop-hook.sh
- CC self-scores too generously — needs external validation (curl tests)
- NEXTAUTH_URL must match the access URL or login breaks
- `next start` forces NODE_ENV=production regardless of env vars
