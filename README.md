# auto-claude

> GOAL.md 驱动的 Claude Code 自主迭代引擎 — 写一个目标文件，CC 自己干到达标

## 怎么用

### 1. 在项目根目录创建 GOAL.md

```markdown
# Twitter Clone

## 目标
1:1 复原真实推特，达到生产级水平。

## 技术栈
Next.js 15 + TypeScript + Tailwind CSS + Prisma

## UI 标杆
真实推特 (x.com)，配色 #1D9BF0

## 核心功能
- [ ] 注册 / 登录
- [ ] 发推文（文字 + 图片）
- [ ] 转推 / 引用
- [ ] 点赞 / 收藏
- [ ] 关注 / 粉丝
- [ ] 个人主页
- [ ] 通知
- [ ] 搜索
- [ ] 响应式

## 成功标准
- 评分 >= 90/100

## 行为规则
- 每完成一批改动后 git commit
- 自主决策，不要停下来问用户
- 优先修复评分最低的维度
- 评分结果追加到 .auto-claude/results.jsonl
```

参考模板：[templates/GOAL.example.md](templates/GOAL.example.md)

### 2. 选择运行模式

**无头模式**（后台持续跑）：
```bash
python3 auto-claude/scripts/runner.py --project ~/projects/twitter-clone
```

**交互模式**（终端直接用）：
```bash
cd ~/projects/twitter-clone
claude
> 请阅读 GOAL.md 并开始工作
```

两种模式使用相同的 hooks 和评分系统。

### 3. 观察进度

```bash
# 查看评分趋势
cat ~/projects/twitter-clone/.auto-claude/results.jsonl | python3 -c "
import json,sys
for l in sys.stdin:
    e=json.loads(l)
    print(f\"Round {e.get('round','?')}: {e.get('total','?')}/100 — worst: {', '.join(e.get('worst',[]))}\")"

# 查看日志
tail -f ~/auto-claude-test.log
```

## 安装

```bash
git clone https://github.com/Kiyliy/auto-claude.git
cd auto-claude

# 配置环境变量
mkdir -p ~/.auto-claude/{state,logs}
cp config/config.env.example ~/.auto-claude/config.env
# 编辑 config.env，填写 TG_BOT_TOKEN 和 TG_CHAT_ID

# 注入评分 prompt 到 settings.json
bash scripts/inject-prompts.sh

# （可选）启动 Telegram daemon
cd channel && npm install && cd ..
npx tsx channel/src/daemon.ts &
```

## 评分系统

10 个通用维度，满分 100：

| # | 维度 | 说明 |
|---|------|------|
| 1 | 目标达成度 | 逐条核对 GOAL.md 功能清单 |
| 2 | UI/UX 质量 | 有 UI 标杆则对标，无则检查一致性 |
| 3 | 响应式 | 桌面/平板/手机三断点 |
| 4 | 运行时稳定性 | 控制台零报错 |
| 5 | 代码质量 | 零编译错误，类型安全 |
| 6 | 测试覆盖 | 核心逻辑有测试 |
| 7 | 错误处理 | loading/error/empty 三态 |
| 8 | 安全性 | 环境变量、输入校验 |
| 9 | 文档 | README + .env.example |
| 10 | 可运行性 | 一键能跑 |

评分前必须跑 build、测试、启动验证。每轮结果追加到 `.auto-claude/results.jsonl`。

## 项目结构

```
auto-claude/
├── scripts/runner.py          # 无头模式引擎
├── hooks/stop-hook.sh         # 续命控制器
├── prompts/
│   ├── scoring.md             # 通用评分（读 GOAL.md）
│   ├── continue.md            # 续命指令（含趋势）
│   └── teammate-idle.md
├── templates/GOAL.example.md  # GOAL.md 模板
├── channel/src/               # TG daemon
├── config/                    # Hook 注册 + 环境变量
└── lib/                       # 状态管理 + 日志
```

## 前置条件

| 依赖 | 说明 |
|------|------|
| Claude Code | `claude --version` |
| jq | `apt install jq` |
| Python 3 | runner.py |
| Node.js | TG daemon（可选） |

## License

MIT
