# GOAL-Driven Auto-Claude Refactor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor auto-claude to be driven by a GOAL.md file — one goal file per project, generic scoring, per-round results log, support both `-p` headless and interactive CLI modes.

**Architecture:** User writes GOAL.md in their project root. runner.py (headless) or hooks (interactive) read it. Scoring prompt evaluates against GOAL.md dimensions. Each round's scores append to `.auto-claude/results.jsonl`. Continuation prompts include trend data.

**Tech Stack:** Python 3 (runner), Bash (hooks/lib), Markdown (prompts/templates), TypeScript (channel daemon — unchanged)

---

### Task 1: Create GOAL.md Template

**Files:**
- Create: `templates/GOAL.example.md`

- [ ] **Step 1: Create the template file**

```markdown
# [项目名称]

## 目标
[一句话描述项目目标。例：1:1 复原真实推特，达到生产级水平。]

## 技术栈
[例：Next.js 15 + TypeScript + Tailwind CSS + Prisma + PostgreSQL]

## UI 标杆
[可选。指定参照的真实产品。例：真实推特 (x.com)，配色 #1D9BF0。]
[如不需要对标特定产品，删除此节。]

## 核心功能
- [ ] [功能 1]
- [ ] [功能 2]
- [ ] [功能 3]
[使用 checkbox 格式，评分时逐条核对。]

## 成功标准
- 评分 >= 90/100
- [项目特定的成功条件]

## 行为规则
- 每完成一批改动后 git commit，message 说明改了什么
- 自主决策，不要停下来问用户
- 重要决策通过 Telegram 通知用户
- 优先修复评分最低的维度
- 评分结果追加到 .auto-claude/results.jsonl
```

- [ ] **Step 2: Commit**

```bash
git add templates/GOAL.example.md
git commit -m "feat: add GOAL.md template for goal-driven iteration"
```

---

### Task 2: Rewrite scoring.md (Generic)

**Files:**
- Modify: `prompts/scoring.md`

- [ ] **Step 1: Rewrite scoring.md to read GOAL.md**

The prompt must:
1. Instruct CC to read GOAL.md from project root
2. Have 10 fixed dimensions (generic, not twitter-specific)
3. First dimension = "目标达成度" — check GOAL.md功能 checklist
4. Output JSON with goal_checklist field
5. Instruct CC to append result to `.auto-claude/results.jsonl`
6. Instruct CC to git commit after evaluation

Key dimensions:
1. 目标达成度 — 逐条核对 GOAL.md 功能清单
2. UI/UX 质量 — 如有 UI 标杆则对标，无则检查一致性
3. 响应式/适配 — 多端适配
4. 运行时稳定性 — 控制台零报错
5. 代码质量 — 零编译错误，类型安全
6. 测试覆盖 — 核心逻辑有测试
7. 错误处理 — loading/error/empty 三态
8. 安全性 — 环境变量、输入校验
9. 文档 — README + .env.example
10. 可运行性 — 一键能跑

- [ ] **Step 2: Run inject-prompts.sh to verify it injects correctly**

```bash
bash scripts/inject-prompts.sh
```

- [ ] **Step 3: Commit**

```bash
git add prompts/scoring.md
git commit -m "feat: generic scoring prompt, reads GOAL.md for project-specific criteria"
```

---

### Task 3: Update continue.md (With Trend)

**Files:**
- Modify: `prompts/continue.md`

- [ ] **Step 1: Rewrite continue.md with trend placeholder**

Add `{{trend}}` placeholder that stop-hook.sh or runner.py fills with scoring trend data.

```markdown
继续工作。这是第 {{count}}/{{max}} 次自动续命。

{{trend}}

行为规则：
- 优先修复评分最低的维度
- 每完成一批改动后 git commit
- 自主决策，不等用户
- 重要决策通过 Telegram 通知
```

- [ ] **Step 2: Commit**

```bash
git add prompts/continue.md
git commit -m "feat: add trend data to continuation prompt"
```

---

### Task 4: Refactor runner.py (Generic Engine)

**Files:**
- Modify: `scripts/runner.py`

- [ ] **Step 1: Add CLI argument parsing**

Replace hardcoded CWD and INITIAL_PROMPT. Add argparse:
- `--project` (required): project directory path
- `--goal` (default: "GOAL.md"): goal file name relative to project
- `--max-turns` (default: 100): max rounds before stopping
- `--socket` (default: ~/.auto-claude/channel.sock): daemon socket path
- `--mcp-config` (optional): MCP config file path

- [ ] **Step 2: Read GOAL.md and build initial prompt**

```python
goal_path = os.path.join(args.project, args.goal)
with open(goal_path) as f:
    goal_content = f.read()

initial_prompt = f"请阅读并遵循以下项目目标文件，开始工作。\n\n{goal_content}"
```

- [ ] **Step 3: Add results.jsonl reading for trend-aware continuation**

After receiving a `result` event, read the last N entries from `.auto-claude/results.jsonl` in the project directory and build a trend summary:

```python
def read_trend(project_dir, last_n=5):
    results_file = os.path.join(project_dir, ".auto-claude", "results.jsonl")
    if not os.path.isfile(results_file):
        return ""
    lines = open(results_file).readlines()[-last_n:]
    entries = [json.loads(l) for l in lines if l.strip()]
    if not entries:
        return ""
    latest = entries[-1]
    scores_str = ", ".join(f"{k}({v})" for k, v in latest.get("scores", {}).items())
    totals = [e.get("total", 0) for e in entries]
    trend_line = " → ".join(str(t) for t in totals)
    worst = latest.get("worst", [])
    return (
        f"上一轮评分：总分 {latest.get('total', '?')}/100\n"
        f"各维度：{scores_str}\n"
        f"趋势：{trend_line}\n"
        f"最低维度：{', '.join(worst)}\n"
        f"优先改进最低维度。"
    )
```

- [ ] **Step 4: Update continuation message**

On `result` event:
```python
trend = read_trend(args.project)
continue_msg = f"继续改进项目。第 {turn_count} 轮。\n\n{trend}\n\n每完成一批改动后 git commit。"
proc.stdin.write(make_msg(continue_msg))
```

- [ ] **Step 5: Ensure .auto-claude directory exists in project**

At startup:
```python
os.makedirs(os.path.join(args.project, ".auto-claude"), exist_ok=True)
```

- [ ] **Step 6: Verify runner.py runs with --help**

```bash
python3 scripts/runner.py --help
```

Expected: shows usage with --project, --goal, --max-turns, --socket, --mcp-config.

- [ ] **Step 7: Commit**

```bash
git add scripts/runner.py
git commit -m "feat: runner.py reads GOAL.md via CLI args, trend-aware continuation"
```

---

### Task 5: Update stop-hook.sh (Trend in Continue Prompt)

**Files:**
- Modify: `hooks/stop-hook.sh`

- [ ] **Step 1: Add trend reading from results.jsonl**

Before the `block_stop` call, read the latest results.jsonl entry from the project's `.auto-claude/results.jsonl`. The project directory comes from stdin JSON's `cwd` field.

```bash
# Read trend from results.jsonl
_read_trend() {
    local cwd="$1"
    local results_file="${cwd}/.auto-claude/results.jsonl"
    [[ -f "${results_file}" ]] || { echo ""; return 0; }
    local last_line
    last_line="$(tail -1 "${results_file}" 2>/dev/null)" || { echo ""; return 0; }
    [[ -z "${last_line}" ]] && { echo ""; return 0; }
    python3 -c "
import json,sys
e=json.loads(sys.argv[1])
t=e.get('total','?')
w=', '.join(e.get('worst',[]))
print(f'上一轮评分：{t}/100，最低维度：{w}')
" "${last_line}" 2>/dev/null || echo ""
}
```

- [ ] **Step 2: Parse cwd from stdin and include trend in continue message**

Add `cwd` parsing from stdin JSON (CC passes it). Replace trend placeholder in continue.md:

```bash
cwd="$(echo "${input}" | jq -r '.cwd // empty' 2>/dev/null)" || true
trend="$(_read_trend "${cwd}")"
msg="${msg//\{\{trend\}\}/${trend}}"
```

- [ ] **Step 3: Commit**

```bash
git add hooks/stop-hook.sh
git commit -m "feat: stop-hook reads results.jsonl for trend in continue prompt"
```

---

### Task 6: Update Config and Inject Script

**Files:**
- Modify: `config/settings.json`
- Modify: `scripts/inject-prompts.sh`

- [ ] **Step 1: Run inject-prompts.sh to update settings.json with new scoring prompt**

```bash
bash scripts/inject-prompts.sh
```

- [ ] **Step 2: Verify settings.json has the updated scoring prompt**

```bash
jq '.hooks.Stop[0].hooks[0].prompt[:80]' config/settings.json
```

Expected: starts with "你是严格的项目评审官" and mentions "GOAL.md".

- [ ] **Step 3: Commit if settings.json changed**

```bash
git add config/settings.json scripts/inject-prompts.sh
git commit -m "chore: sync scoring prompt to settings.json"
```

---

### Task 7: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `SOUL.md`

- [ ] **Step 1: Update README.md**

Key changes:
- Quick start shows creating GOAL.md
- Two usage modes: headless (`python3 runner.py --project ~/myapp`) and interactive (`claude` in project dir)
- Show GOAL.md format
- Show results.jsonl format
- Remove twitter-specific references

- [ ] **Step 2: Update SOUL.md**

Key changes:
- Architecture shows GOAL.md as the entry point
- Scoring reads GOAL.md
- Results.jsonl tracking
- Two modes: headless + interactive

- [ ] **Step 3: Commit**

```bash
git add README.md SOUL.md
git commit -m "docs: update for GOAL.md-driven architecture"
```

---

### Task 8: Deploy and Test on Remote Server

**Files:**
- No file changes — deployment and verification only

- [ ] **Step 1: Sync updated auto-claude to remote server**

```bash
tar czf /tmp/auto-claude-sync.tar.gz --exclude='node_modules' --exclude='.git' .
scp /tmp/auto-claude-sync.tar.gz root@152.53.165.85:/tmp/
ssh root@152.53.165.85 'cd ~/auto-claude && tar xzf /tmp/auto-claude-sync.tar.gz'
```

- [ ] **Step 2: Create GOAL.md for twitter-clone project**

Write a twitter-specific GOAL.md to `~/projects/twitter-clone/GOAL.md` on the remote.

- [ ] **Step 3: Run inject-prompts.sh and update CC settings on remote**

```bash
ssh root@152.53.165.85 'cd ~/auto-claude && bash scripts/inject-prompts.sh'
```

Then install settings.json with correct paths.

- [ ] **Step 4: Start experiment with new runner.py**

```bash
ssh root@152.53.165.85 'tmux new-session -d -s auto-claude "python3 ~/auto-claude/scripts/runner.py --project ~/projects/twitter-clone"'
```

- [ ] **Step 5: Verify CC is reading GOAL.md and producing results.jsonl**

Wait 5-10 minutes, then:
```bash
ssh root@152.53.165.85 'cat ~/projects/twitter-clone/.auto-claude/results.jsonl; tail -10 ~/auto-claude-test.log'
```
