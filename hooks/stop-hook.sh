#!/usr/bin/env bash
# ============================================================================
# stop-hook.sh — 续命控制器 + Haiku 独立审查
# ============================================================================
# Stop event command hook.
# 1. 启动独立 Haiku 进程审查项目质量（非自评）
# 2. 根据分数决定 block/allow
# 3. 将审查结果注入 CC 的 context
#
# 输入 (stdin JSON): session_id, stop_hook_active, cwd
# 输出: exit 0 = 放行停止, exit 2 + stderr = 阻止停止并注入消息
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "${SCRIPT_DIR}")/lib"

CONFIG_FILE="${HOME}/.auto-claude/config.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/state.sh"

_LOG_HOOK_NAME="stop-hook"

CHANNEL_SOCKET="${CHANNEL_SOCKET:-${HOME}/.auto-claude/channel.sock}"
MAX_CONTINUATIONS="${MAX_CONTINUATIONS:-20}"
MAX_CONSECUTIVE_BLOCKS="${MAX_CONSECUTIVE_BLOCKS:-10}"
SCORE_TARGET="${SCORE_TARGET:-90}"

_notify() {
    local msg="$1" evt="${2:-info}" sid="${3:-}"
    [[ -S "${CHANNEL_SOCKET}" ]] || return 0
    curl -s --max-time 5 --unix-socket "${CHANNEL_SOCKET}" \
        -X POST "http://localhost/notify" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "import json,sys;print(json.dumps({'message':sys.argv[1],'event_type':sys.argv[2],'session_id':sys.argv[3]}))" \
            "${msg}" "${evt}" "${sid}" 2>/dev/null)" \
        &>/dev/null &
}

_tg_reply() {
    local msg="$1" sid="$2"
    [[ -S "${CHANNEL_SOCKET}" ]] || return 0
    curl -s --max-time 5 --unix-socket "${CHANNEL_SOCKET}" \
        -X POST "http://localhost/sessions/${sid}/reply" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "import json,sys;print(json.dumps({'text':sys.argv[1]}))" "${msg}" 2>/dev/null)" \
        &>/dev/null &
}

block_stop() {
    log_info "Block: ${1:0:80}"
    echo "$1" >&2
    exit 2
}

allow_stop() {
    log_info "Allow stop"
    exit 0
}

# ============================================================================
# Haiku 独立审查
# ============================================================================
run_haiku_review() {
    local project_dir="$1"
    local round_num="$2"
    local scoring_prompt_file="${SCRIPT_DIR}/../prompts/scoring.md"

    [[ ! -d "${project_dir}" ]] && { echo '{"total":0,"error":"project dir not found"}'; return; }

    local scoring_prompt=""
    if [[ -f "${scoring_prompt_file}" ]]; then
        scoring_prompt="$(cat "${scoring_prompt_file}")"
    else
        scoring_prompt="Score this project 0-100. Output JSON with total, scores, bugs_found, worst, reason."
    fi

    log_info "Starting Haiku review in ${project_dir}..."

    # 调用独立 Haiku CC 进程做审查
    local haiku_result
    haiku_result="$(cd "${project_dir}" && IS_SANDBOX=1 timeout 300 claude -p \
        --model haiku \
        --dangerously-skip-permissions \
        --output-format json \
        "${scoring_prompt}

IMPORTANT: You are an INDEPENDENT reviewer. Be strict and honest.
This is round ${round_num}. Output ONLY the JSON object, nothing else.
Test the app with curl against localhost:3000 if a server is running." 2>/dev/null)" || true

    # 从 haiku 输出中提取 JSON
    local score_json
    score_json="$(echo "${haiku_result}" | python3 -c "
import json, sys, re

raw = sys.stdin.read()

# Try to parse the result field from CC JSON output
try:
    cc_out = json.loads(raw)
    text = cc_out.get('result', raw)
except:
    text = raw

# Find JSON object in the text
match = re.search(r'\{[^{}]*\"total\"[^{}]*\}', text, re.DOTALL)
if not match:
    # Try multiline JSON
    match = re.search(r'\{.*?\"total\".*?\}', text, re.DOTALL)

if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj))
    except:
        print(json.dumps({'total': 0, 'error': 'json parse failed', 'raw': text[:500]}))
else:
    print(json.dumps({'total': 0, 'error': 'no json found', 'raw': text[:500]}))
" 2>/dev/null)" || score_json='{"total":0,"error":"haiku failed"}'

    echo "${score_json}"
}

# ============================================================================
# Main
# ============================================================================
main() {
    local input=""
    [[ ! -t 0 ]] && input="$(cat)"
    [[ -z "${input}" ]] && allow_stop

    local session_id stop_hook_active cwd
    session_id="$(echo "${input}" | jq -r '.session_id // empty' 2>/dev/null)" || true
    stop_hook_active="$(echo "${input}" | jq -r '.stop_hook_active // empty' 2>/dev/null)" || true
    cwd="$(echo "${input}" | jq -r '.cwd // empty' 2>/dev/null)" || true

    [[ -z "${session_id}" ]] && allow_stop

    state_init "${session_id}"

    # --- 连续 block 计数 ---
    if [[ "${stop_hook_active}" == "true" ]]; then
        local blocks
        blocks="$(state_read "${session_id}" '.consecutive_blocks // 0')"
        blocks=$((blocks + 1))
        state_write "${session_id}" ".consecutive_blocks = ${blocks}"
        log_info "Consecutive blocks: ${blocks}/${MAX_CONSECUTIVE_BLOCKS}"

        if [[ "${blocks}" -ge "${MAX_CONSECUTIVE_BLOCKS}" ]]; then
            log_warn "Consecutive block limit reached, allowing one stop"
            state_write "${session_id}" ".consecutive_blocks = 0"
            allow_stop
        fi
    else
        state_write "${session_id}" ".consecutive_blocks = 0"
    fi

    # --- 总续命计数 ---
    local count
    count="$(state_get_continuation_count "${session_id}")"

    if [[ "${count}" -ge "${MAX_CONTINUATIONS}" ]]; then
        _notify "Max continuations reached (${MAX_CONTINUATIONS})" "max_reached" "${session_id}"
        allow_stop
    fi

    state_increment_continuation "${session_id}"
    local new_count=$((count + 1))
    log_info "Continue #${new_count}/${MAX_CONTINUATIONS}"

    # --- Haiku 独立审查 ---
    local project_dir="${cwd:-$(pwd)}"
    local score_json=""
    local total=0
    local haiku_reason=""
    local haiku_bugs=""
    local haiku_worst=""

    score_json="$(run_haiku_review "${project_dir}" "${new_count}")"
    total="$(echo "${score_json}" | jq -r '.total // 0' 2>/dev/null)" || total=0
    haiku_reason="$(echo "${score_json}" | jq -r '.reason // "no reason"' 2>/dev/null)" || haiku_reason=""
    haiku_worst="$(echo "${score_json}" | jq -r '(.worst // []) | join(", ")' 2>/dev/null)" || haiku_worst=""
    haiku_bugs="$(echo "${score_json}" | jq -r '(.bugs_found // []) | join("; ")' 2>/dev/null)" || haiku_bugs=""

    log_info "Haiku score: ${total}/100 (worst: ${haiku_worst})"

    # --- 写 results.jsonl ---
    local results_file="${project_dir}/.auto-claude/results.jsonl"
    mkdir -p "$(dirname "${results_file}")" 2>/dev/null || true
    # 添加 round 和 timestamp
    local enriched_json
    enriched_json="$(echo "${score_json}" | python3 -c "
import json, sys, datetime
obj = json.loads(sys.stdin.read())
obj['round'] = ${new_count}
obj['timestamp'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
obj['reviewer'] = 'haiku'
print(json.dumps(obj))
" 2>/dev/null)" || enriched_json="${score_json}"
    echo "${enriched_json}" >> "${results_file}" 2>/dev/null || true

    # --- TG 报告 ---
    local tg_report="📊 Round ${new_count} (Haiku review): ${total}/100"
    [[ -n "${haiku_worst}" ]] && tg_report="${tg_report}\nWeakest: ${haiku_worst}"
    [[ -n "${haiku_bugs}" ]] && tg_report="${tg_report}\n🐛 Bugs: ${haiku_bugs}"
    [[ -n "${haiku_reason}" ]] && tg_report="${tg_report}\n${haiku_reason}"
    _tg_reply "${tg_report}" "${session_id}" &>/dev/null &
    _notify "Round ${new_count}: ${total}/100" "score" "${session_id}" &>/dev/null &

    # --- 决策：block 或 allow ---
    local msg="Continue working. Auto-continue ${new_count}/${MAX_CONTINUATIONS}.

=== INDEPENDENT HAIKU REVIEW (score: ${total}/100, target: ${SCORE_TARGET}) ===
${haiku_reason}
Weakest dimensions: ${haiku_worst}
Bugs found: ${haiku_bugs:-none}
=======================================================================

Fix the issues above. Prioritize bugs first, then lowest-scoring dimensions.
After fixing, git commit your changes."

    block_stop "${msg}"
}

main
