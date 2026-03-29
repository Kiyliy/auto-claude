#!/usr/bin/env bash
# ============================================================================
# state.sh — Session 状态管理
# ============================================================================
# 管理每个 session 的续命计数和连续 block 计数。
# 状态文件: ~/.auto-claude/state/{session_id}.json
# 依赖: jq, flock (可选)
# ============================================================================

readonly STATE_DIR="${STATE_DIR:-${HOME}/.auto-claude/state}"
readonly FLOCK_TIMEOUT=5

_state_validate_session_id() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "session_id 非法: $1"
        return 1
    fi
}

_state_file() { echo "${STATE_DIR}/$1.json"; }
_state_lock_file() { echo "${STATE_DIR}/$1.lock"; }

_state_with_lock() {
    local sid="$1"; shift
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    if command -v flock &>/dev/null; then
        (flock -w "${FLOCK_TIMEOUT}" 200 || true; "$@") 200>"$(_state_lock_file "${sid}")"
    else
        "$@"
    fi
}

# 初始化 session 状态文件
state_init() {
    local sid="$1"
    [[ -z "${sid}" ]] && return 1
    _state_validate_session_id "${sid}" || return 1
    command -v jq &>/dev/null || { log_error "jq 未安装"; return 1; }

    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    local f="$(_state_file "${sid}")"
    [[ -f "${f}" ]] && return 0

    local now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    _state_with_lock "${sid}" bash -c "
        [[ ! -f '${f}' ]] && jq -n --arg sid '${sid}' --arg t '${now}' '{
            session_id: \$sid, started_at: \$t,
            continuation_count: 0, consecutive_blocks: 0
        }' > '${f}'
    "
}

# 读取状态字段
state_read() {
    local sid="$1" query="$2"
    local f="$(_state_file "${sid}")"
    [[ ! -f "${f}" ]] && state_init "${sid}"
    jq -r "${query}" "${f}" 2>/dev/null
}

# 更新状态字段
state_write() {
    local sid="$1" expr="$2"
    local f="$(_state_file "${sid}")"
    [[ ! -f "${f}" ]] && state_init "${sid}"
    _state_with_lock "${sid}" bash -c "
        tmp=\$(mktemp)
        jq '${expr}' '${f}' > \"\${tmp}\" 2>/dev/null && mv \"\${tmp}\" '${f}' || rm -f \"\${tmp}\"
    "
}

# 续命计数 +1
state_increment_continuation() {
    local f="$(_state_file "$1")"
    [[ ! -f "${f}" ]] && state_init "$1"
    _state_with_lock "$1" bash -c "
        tmp=\$(mktemp)
        jq '.continuation_count += 1' '${f}' > \"\${tmp}\" 2>/dev/null && mv \"\${tmp}\" '${f}' || rm -f \"\${tmp}\"
    "
}

# 获取续命计数
state_get_continuation_count() {
    local c="$(state_read "$1" '.continuation_count // 0')"
    [[ "${c}" =~ ^[0-9]+$ ]] && echo "${c}" || echo "0"
}
