#!/usr/bin/env bash
# ============================================================================
# state.sh — 状态管理工具
# ============================================================================
# 管理 auto-claude 的会话状态文件。
# 状态目录: ~/.auto-claude/state/
# 状态文件: {session_id}.json
# 使用 jq 进行 JSON 操作，flock 保证线程安全。
#
# 依赖: jq, flock (util-linux)
# ============================================================================

# 状态目录（可通过环境变量覆盖）
readonly STATE_DIR="${STATE_DIR:-${HOME}/.auto-claude/state}"

# flock 超时时间（秒）
readonly FLOCK_TIMEOUT=5

# ----------------------------------------------------------------------------
# _state_validate_session_id — 验证 session_id 安全性
# 参数:
#   $1 — session_id
# 返回: 0=合法, 1=非法
# ----------------------------------------------------------------------------
_state_validate_session_id() {
    local sid="$1"
    if [[ ! "${sid}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "session_id 包含非法字符: ${sid}"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# _state_check_deps — 检查依赖是否可用
# 返回: 0=正常, 1=缺少依赖
# ----------------------------------------------------------------------------
_state_check_deps() {
    if ! command -v jq &>/dev/null; then
        log_error "jq 未安装，状态管理不可用。请安装: apt-get install jq"
        return 1
    fi
    if ! command -v flock &>/dev/null; then
        log_warn "flock 不可用，将跳过文件锁（可能出现竞态问题）"
        # 不返回错误，因为可以降级运行
    fi
    return 0
}

# ----------------------------------------------------------------------------
# _state_file — 获取指定 session 的状态文件路径
# 参数:
#   $1 — session_id
# 输出: 状态文件的绝对路径
# ----------------------------------------------------------------------------
_state_file() {
    local session_id="$1"
    echo "${STATE_DIR}/${session_id}.json"
}

# ----------------------------------------------------------------------------
# _state_lock_file — 获取指定 session 的锁文件路径
# 参数:
#   $1 — session_id
# 输出: 锁文件的绝对路径
# ----------------------------------------------------------------------------
_state_lock_file() {
    local session_id="$1"
    echo "${STATE_DIR}/${session_id}.lock"
}

# ----------------------------------------------------------------------------
# _state_with_lock — 在文件锁保护下执行操作（排他锁）
# 参数:
#   $1 — session_id
#   $2... — 要执行的命令
# 说明: 如果 flock 不可用，直接执行（降级模式）
# ----------------------------------------------------------------------------
_state_with_lock() {
    local session_id="$1"
    shift
    local lock_file
    lock_file="$(_state_lock_file "${session_id}")"

    # 确保状态目录存在
    mkdir -p "${STATE_DIR}" 2>/dev/null || true

    if command -v flock &>/dev/null; then
        # 使用 flock 实现排他锁
        (
            flock -w "${FLOCK_TIMEOUT}" 200 || {
                log_warn "获取文件锁超时（${FLOCK_TIMEOUT}s），强制执行"
            }
            "$@"
        ) 200>"${lock_file}"
    else
        # 降级模式：直接执行
        "$@"
    fi
}

# ----------------------------------------------------------------------------
# _state_with_shared_lock — 在共享锁保护下执行操作（读操作用）
# 参数:
#   $1 — session_id
#   $2... — 要执行的命令
# ----------------------------------------------------------------------------
_state_with_shared_lock() {
    local session_id="$1"
    shift
    local lock_file
    lock_file="$(_state_lock_file "${session_id}")"

    mkdir -p "${STATE_DIR}" 2>/dev/null || true

    if command -v flock &>/dev/null; then
        (
            flock -s -w "${FLOCK_TIMEOUT}" 200 || {
                log_warn "获取共享锁超时（${FLOCK_TIMEOUT}s），强制执行"
            }
            "$@"
        ) 200>"${lock_file}"
    else
        "$@"
    fi
}

# ----------------------------------------------------------------------------
# state_init — 初始化会话状态文件
# 参数:
#   $1 — session_id
# 说明: 如果状态文件已存在，不会覆盖。使用锁内检查防止竞态。
# ----------------------------------------------------------------------------
state_init() {
    local session_id="$1"

    if [[ -z "${session_id}" ]]; then
        log_error "state_init: session_id 不能为空"
        return 1
    fi

    _state_validate_session_id "${session_id}" || return 1
    _state_check_deps || return 1

    mkdir -p "${STATE_DIR}" 2>/dev/null || true

    local state_file
    state_file="$(_state_file "${session_id}")"

    # 快速检查（无锁）：如果文件已存在，直接返回
    if [[ -f "${state_file}" ]]; then
        return 0
    fi

    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # 在锁内进行 check-then-create，防止竞态
    _state_with_lock "${session_id}" bash -c "
        if [[ ! -f '${state_file}' ]]; then
            jq -n \
                --arg sid '${session_id}' \
                --arg started '${now}' \
                --argjson max_cont ${MAX_CONTINUATIONS:-20} \
                '{
                    session_id: \$sid,
                    started_at: \$started,
                    active_subagents: 0,
                    subagent_history: [],
                    continuation_count: 0,
                    consecutive_blocks: 0,
                    max_continuations: \$max_cont
                }' > '${state_file}'
        fi
    "
    log_info "状态文件已初始化: ${state_file}"
}

# ----------------------------------------------------------------------------
# state_read — 读取状态文件中指定字段的值
# 参数:
#   $1 — session_id
#   $2 — jq 查询表达式（例如 ".active_subagents"）
# 输出: 查询结果
# ----------------------------------------------------------------------------
state_read() {
    local session_id="$1"
    local query="$2"

    if [[ -z "${session_id}" ]] || [[ -z "${query}" ]]; then
        log_error "state_read: session_id 和 query 都不能为空"
        return 1
    fi

    _state_check_deps || return 1

    local state_file
    state_file="$(_state_file "${session_id}")"

    if [[ ! -f "${state_file}" ]]; then
        log_warn "状态文件不存在: ${state_file}，自动初始化"
        state_init "${session_id}"
    fi

    # 使用共享锁读取
    _state_with_shared_lock "${session_id}" jq -r "${query}" "${state_file}" 2>/dev/null
}

# ----------------------------------------------------------------------------
# state_write — 更新状态文件中指定字段
# 参数:
#   $1 — session_id
#   $2 — jq 更新表达式（例如 '.active_subagents = 5'）
# 注意: 此函数仅供内部使用，update_expr 不应包含外部用户输入
# ----------------------------------------------------------------------------
state_write() {
    local session_id="$1"
    local update_expr="$2"

    if [[ -z "${session_id}" ]] || [[ -z "${update_expr}" ]]; then
        log_error "state_write: session_id 和 update_expr 都不能为空"
        return 1
    fi

    _state_check_deps || return 1

    local state_file
    state_file="$(_state_file "${session_id}")"

    if [[ ! -f "${state_file}" ]]; then
        log_warn "状态文件不存在: ${state_file}，自动初始化"
        state_init "${session_id}"
    fi

    _state_with_lock "${session_id}" bash -c "
        tmp_file=\"\$(mktemp)\"
        if jq '${update_expr}' '${state_file}' > \"\${tmp_file}\" 2>/dev/null; then
            mv \"\${tmp_file}\" '${state_file}'
        else
            rm -f \"\${tmp_file}\"
            echo 'state_write: jq 更新失败' >&2
            exit 1
        fi
    "
}

# ----------------------------------------------------------------------------
# state_increment_subagents — 活跃子代理计数 +1
# 参数:
#   $1 — session_id
# ----------------------------------------------------------------------------
state_increment_subagents() {
    local session_id="$1"

    if [[ -z "${session_id}" ]]; then
        log_error "state_increment_subagents: session_id 不能为空"
        return 1
    fi

    _state_check_deps || return 1

    local state_file
    state_file="$(_state_file "${session_id}")"

    if [[ ! -f "${state_file}" ]]; then
        state_init "${session_id}"
    fi

    _state_with_lock "${session_id}" bash -c "
        tmp_file=\"\$(mktemp)\"
        if jq '.active_subagents += 1' '${state_file}' > \"\${tmp_file}\" 2>/dev/null; then
            mv \"\${tmp_file}\" '${state_file}'
        else
            rm -f \"\${tmp_file}\"
            exit 1
        fi
    "

    log_info "活跃子代理 +1 (session=${session_id})"
}

# ----------------------------------------------------------------------------
# state_decrement_subagents — 活跃子代理计数 -1（最小为 0）
# 参数:
#   $1 — session_id
# ----------------------------------------------------------------------------
state_decrement_subagents() {
    local session_id="$1"

    if [[ -z "${session_id}" ]]; then
        log_error "state_decrement_subagents: session_id 不能为空"
        return 1
    fi

    _state_check_deps || return 1

    local state_file
    state_file="$(_state_file "${session_id}")"

    if [[ ! -f "${state_file}" ]]; then
        state_init "${session_id}"
    fi

    _state_with_lock "${session_id}" bash -c "
        tmp_file=\"\$(mktemp)\"
        if jq '.active_subagents = ([.active_subagents - 1, 0] | max)' '${state_file}' > \"\${tmp_file}\" 2>/dev/null; then
            mv \"\${tmp_file}\" '${state_file}'
        else
            rm -f \"\${tmp_file}\"
            exit 1
        fi
    "

    log_info "活跃子代理 -1 (session=${session_id})"
}

# ----------------------------------------------------------------------------
# state_get_active_subagents — 获取当前活跃子代理数量
# 参数:
#   $1 — session_id
# 输出: 活跃子代理数量（整数）
# ----------------------------------------------------------------------------
state_get_active_subagents() {
    local session_id="$1"
    local count
    count="$(state_read "${session_id}" '.active_subagents // 0')"

    # 如果读取失败或返回非数字，默认为 0
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${count}"
    fi
}

# ----------------------------------------------------------------------------
# state_increment_continuation — 续命计数 +1
# 参数:
#   $1 — session_id
# ----------------------------------------------------------------------------
state_increment_continuation() {
    local session_id="$1"

    if [[ -z "${session_id}" ]]; then
        log_error "state_increment_continuation: session_id 不能为空"
        return 1
    fi

    _state_check_deps || return 1

    local state_file
    state_file="$(_state_file "${session_id}")"

    if [[ ! -f "${state_file}" ]]; then
        state_init "${session_id}"
    fi

    _state_with_lock "${session_id}" bash -c "
        tmp_file=\"\$(mktemp)\"
        if jq '.continuation_count += 1' '${state_file}' > \"\${tmp_file}\" 2>/dev/null; then
            mv \"\${tmp_file}\" '${state_file}'
        else
            rm -f \"\${tmp_file}\"
            exit 1
        fi
    "

    log_info "续命计数 +1 (session=${session_id})"
}

# ----------------------------------------------------------------------------
# state_get_continuation_count — 获取当前续命次数
# 参数:
#   $1 — session_id
# 输出: 续命次数（整数）
# ----------------------------------------------------------------------------
state_get_continuation_count() {
    local session_id="$1"
    local count
    count="$(state_read "${session_id}" '.continuation_count // 0')"

    # 如果读取失败或返回非数字，默认为 0
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${count}"
    fi
}
