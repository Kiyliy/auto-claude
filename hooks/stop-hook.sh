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

    block_stop "Continue working. Auto-continue ${new_count}/${MAX_CONTINUATIONS}."
}

main
