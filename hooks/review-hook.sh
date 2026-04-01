#!/usr/bin/env bash
# Stop hook: launch independent claude -p (Sonnet) for project review
# exit 0 = allow stop, exit 2 + stderr = block stop and continue working

set -euo pipefail

PROJECT_DIR="$(pwd)"
REVIEW_LOG="${PROJECT_DIR}/.auto-claude/reviews.jsonl"
SCORING_FILE="${PROJECT_DIR}/scoring.md"
GOAL_FILE="${PROJECT_DIR}/GOAL.md"
REQ_FILE="${PROJECT_DIR}/requirements.md"

# Read scoring.md content
SCORING_PROMPT="$(cat "${SCORING_FILE}" 2>/dev/null || echo "Score the project 0-100.")"

# Build review prompt
REVIEW_PROMPT="You are working in ${PROJECT_DIR}.

${SCORING_PROMPT}

Project goals:
$(cat "${GOAL_FILE}" 2>/dev/null)

Requirements:
$(cat "${REQ_FILE}" 2>/dev/null)

Follow scoring.md strictly: start the server, curl-test endpoints, check code, score.
Output strict JSON:
{\"ok\": true/false, \"total\": N, \"scores\": {...}, \"bugs\": [...], \"reason\": \"...\"}

ok=true only when total >= 90."

# Run independent Sonnet review (stream-json mode, extract from result event)
REVIEW_TEXT="$(timeout 600 claude -p \
  --model claude-sonnet-4-6 \
  --output-format stream-json \
  --verbose \
  --dangerously-skip-permissions \
  "${REVIEW_PROMPT}" 2>/dev/null | python3 -c "
import sys,json
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        if d.get('type')=='result':
            print(d.get('result',''))
            break
    except: pass
")" || true

# Parse JSON (handle markdown code fence wrapping)
PARSED="$(echo "${REVIEW_TEXT}" | python3 -c "
import sys,json,re
raw = sys.stdin.read().strip()
# 去掉 markdown code fence
raw = re.sub(r'^\`\`\`json\s*', '', raw)
raw = re.sub(r'\`\`\`\s*$', '', raw)
# 找第一个 { 到最后一个 }
start = raw.find('{')
end = raw.rfind('}')
if start >= 0 and end > start:
    raw = raw[start:end+1]
try:
    d = json.loads(raw)
    print(json.dumps(d))
except:
    print(json.dumps({'ok': False, 'total': 0, 'reason': 'parse failed', 'raw': raw[:500]}))
" 2>/dev/null)" || PARSED='{"ok":false,"total":0,"reason":"review process failed"}'

# Extract fields
OK="$(echo "${PARSED}" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('ok',False))" 2>/dev/null)" || OK="False"
TOTAL="$(echo "${PARSED}" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('total',0))" 2>/dev/null)" || TOTAL="0"
REASON="$(echo "${PARSED}" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('reason','no reason'))" 2>/dev/null)" || REASON="no reason"

# Write to reviews.jsonl
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "${PARSED}" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
d['timestamp']='${TIMESTAMP}'
d['reviewer']='sonnet'
print(json.dumps(d))
" >> "${REVIEW_LOG}" 2>/dev/null

# Decision
if [ "${OK}" = "True" ]; then
  # Pass — allow stop
  exit 0
else
  # Fail — block stop, inject reason into CC
  echo "Independent reviewer score: ${TOTAL}/100. ${REASON}" >&2
  exit 2
fi
