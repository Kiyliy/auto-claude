# SleepShip 技能手册

在任何项目中使用 sleepship 的实战指南——从零开始或中途接入均可。

---

## 技能 1：从零建应用

**适用场景：** 你有一个想法，但还没有任何代码。

```bash
mkdir ~/myapp && cd ~/myapp
git init

# 写你的 GOAL.md
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

# 启动
python3 /path/to/sleepship/runner.py --project .
```

SleepShip 会自动搭建项目骨架、实现功能、测试、接受评审、迭代改进，直到通过为止。

---

## 技能 2：功能冲刺（在已有项目上加功能）

**适用场景：** 你有一个能跑的项目，想加一个大功能。

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

**关键：** `## Existing Context` 告诉 agent 项目现有的技术栈和上下文，避免它从头重写。

---

## 技能 3：Bug 大扫除（修 bug + 加固）

**适用场景：** 应用基本能用，但有质量问题——bug、缺少错误处理、测试覆盖不够。

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

## 技能 4：快速原型（低门槛，求速度）

**适用场景：** 黑客松、演示、概念验证——需要一个能跑的 demo。

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

**关键：** `Level: demo` + `--target-score 70` + `--max-turns 20` = 快糙猛，不纠结。

---

## 技能 5：重构与迁移

**适用场景：** 技术栈迁移、架构重构、主要依赖升级。

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

## 如何写好 GOAL.md

### Level 决定评审标准

| Level | 门槛 | 评审员的期望 |
|-------|------|-------------|
| `demo` | 主流程能跑通 | 忽略边界情况，不要求打磨 |
| `mvp` | 日常可用，无明显 bug | 测试核心流程，检查错误处理 |
| `pmf` | 生产级可上线 | 完整测试覆盖、安全审计、性能达标 |

### Feature 清单 = 合同

`- [ ]` 复选框就是评审员的检查清单。每个未完成项扣 **-3 分**。要写得具体可测试：

```markdown
# 差——太模糊
- [ ] User management

# 好——可验证
- [ ] Register with email + password (validation: email format, password 8+ chars)
- [ ] Login with email + password (returns JWT, 401 on wrong credentials)
- [ ] Logout (clears token, redirects to login)
```

### Existing Context 能省很多时间

对已有项目，务必写明现有上下文：

```markdown
## Existing Context
- Framework: Next.js 15 with App Router
- Database: Prisma + PostgreSQL (schema in prisma/schema.prisma)
- Auth: NextAuth.js with GitHub provider
- Start command: `npm run dev` (port 3000)
- Test command: `npm test`
```

防止 agent 猜错你的技术栈，或者误覆盖已有代码。

### Rules 控制行为

```markdown
## Rules
- Git commit after each batch of changes          # 进度可追踪
- Make decisions autonomously, do not stop to ask  # 不要停下来问人
- Prioritize fixing the lowest-scoring dimensions  # 优先补短板
- Do NOT rewrite existing code unless necessary    # 保护已有代码
- Write tests before fixing bugs                   # TDD 修 bug
```

---

## Runner 调参指南

| 参数 | 默认值 | 什么时候改 |
|------|--------|-----------|
| `--target-score` | 90 | demo 降到 70，生产环境升到 95 |
| `--max-turns` | 100 | 快速原型降到 20，复杂应用升到 200 |
| `--review-model` | claude-sonnet-4-6 | 用 opus 做更严格的评审，用 haiku 省钱加速 |
| `--review-timeout` | 1800 | 大项目评审耗时长，可以加大 |

### 恢复中断的会话

```bash
# SleepShip 把会话状态存在 PROJECT/.sleepship/session.json
python3 runner.py --project ~/myapp --resume
```

### 通过 Telegram 监控

配好 channel daemon 之后：
- 每轮的产出会转发到你的 Telegram
- 评审分数在每次 review 后推送
- 你可以在 Telegram 里发消息，实时注入指令给 agent

---

## 实战经验

1. **先 `demo` 再升 `mvp`** —— 先跑通主流程，再打磨质量
2. **一个 GOAL 一个会话** —— 不要把"加支付"和"修登录 bug"混在一起
3. **写具体的成功标准** —— "登录能用"太模糊；"POST /api/login 返回 200 + JWT"可验证
4. **写明测试命令** —— 评审员需要知道怎么跑你的测试
5. **原型项目限制 max-turns** —— 防止在一次性代码上无限迭代
