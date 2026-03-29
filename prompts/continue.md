继续工作。这是第 {{count}}/{{max}} 次自动续命。

{{trend}}

行为规则：
- 优先修复评分最低的维度
- 每完成一批改动后 git commit
- 自主决策，不等用户
- 重要决策通过 Telegram 通知
- 评分结果追加到 .auto-claude/results.jsonl
