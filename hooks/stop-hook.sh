#!/usr/bin/env bash
# ============================================================================
# stop-hook.sh — 续命控制器
# ============================================================================
# Stop event command hook。在 scoring prompt 之后运行。
# 控制 CC 是否继续工作：追踪续命计数，未达上限则 block。
#
# 输入 (stdin JSON): session_id, stop_hook_active
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

# 通过 daemon 发送 Telegram 通知（后台，不阻塞）
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

block_stop() {
    log_info "Block: ${1:0:80}"
    echo "$1" >&2
    exit 2
}

allow_stop() {
    log_info "Allow stop"
    exit 0
}

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
    # stop_hook_active=true 时 CC 正处于被 block 后的续命中
    if [[ "${stop_hook_active}" == "true" ]]; then
        local blocks
        blocks="$(state_read "${session_id}" '.consecutive_blocks // 0')"
        blocks=$((blocks + 1))
        state_write "${session_id}" ".consecutive_blocks = ${blocks}"
        log_info "连续 block: ${blocks}/${MAX_CONSECUTIVE_BLOCKS}"

        if [[ "${blocks}" -ge "${MAX_CONSECUTIVE_BLOCKS}" ]]; then
            log_warn "连续 block 达到上限，放行一轮"
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
        _notify "续命达到上限 (${MAX_CONTINUATIONS}次)" "max_reached" "${session_id}"
        allow_stop
    fi

    state_increment_continuation "${session_id}"
    local new_count=$((count + 1))
    log_info "续命 #${new_count}/${MAX_CONTINUATIONS}"

    [[ "${NOTIFY_ON_CONTINUE:-true}" == "true" ]] && \
        _notify "续命 ${new_count}/${MAX_CONTINUATIONS}" "continue" "${session_id}" &>/dev/null &

    # --- 查询 session 的 TG topic thread_id ---
    local tg_thread_id=""
    local tg_chat_id=""
    if [[ -S "${CHANNEL_SOCKET}" ]] && [[ -n "${session_id}" ]]; then
        local session_info
        session_info="$(curl -s --max-time 3 --unix-socket "${CHANNEL_SOCKET}" "http://localhost/sessions" 2>/dev/null)" || true
        if [[ -n "${session_info}" ]]; then
            tg_thread_id="$(echo "${session_info}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('sessions',[]):
    if s['session_id']=='${session_id}':
        print(s.get('topic_thread_id',''))
        break
" 2>/dev/null)" || true
            tg_chat_id="$(python3 -c "
import os
for line in open(os.path.expanduser('~/.auto-claude/config.env')):
    line=line.strip()
    if line.startswith('TG_CHAT_ID='):
        print(line.split('=',1)[1].strip().strip('\"').strip(\"'\"))
        break
" 2>/dev/null)" || true
        fi
    fi

    # --- 续命指令：评分 + TG 报告 + 继续 ---
    local tg_instruction=""
    if [[ -n "${tg_thread_id}" ]] && [[ -n "${tg_chat_id}" ]]; then
        tg_instruction="2. REPORT: Send a detailed progress report to Telegram. Use the reply tool with chat_id=\"${tg_chat_id}\" and message_thread_id=${tg_thread_id}. Include:
   - What you completed this round (bullet points)
   - Current score and weakest dimensions
   - What you plan to improve next
   - Key stats (src files, tests passing, etc.)"
    else
        tg_instruction="2. REPORT: Send a detailed progress report to Telegram via the reply tool. Include what you completed, score, weakest dimensions, next steps, stats."
    fi

    local msg="Continue working. Auto-continue ${new_count}/${MAX_CONTINUATIONS}.

BEFORE continuing, you MUST do these 3 things:

1. SCORE: Read GOAL.md, evaluate the project (build/test/start), output JSON scores, and append one line to .auto-claude/results.jsonl:
   {\"round\":${new_count},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"scores\":{...},\"total\":N,\"ok\":bool,\"worst\":[...],\"reason\":\"...\"}

${tg_instruction}

3. COMMIT: git add -A && git commit -m \"[auto-claude] round ${new_count}: score X/100\"

Then continue improving the project. Prioritize the lowest-scoring dimensions."

    block_stop "${msg}"
}

main
