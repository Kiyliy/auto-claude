#!/usr/bin/env bash
# ============================================================================
# stop-hook.sh — 主控：智能续命
# ============================================================================
# Claude Code Stop Hook — 在主代理即将停止时触发。
# 根据当前状态智能决定：放行停止 or 阻止停止并注入续命指令。
#
# 输入 (stdin JSON):
#   - session_id         — 会话 ID
#   - transcript_path    — 对话记录路径
#   - stop_hook_active   — 是否已在续命循环中
#   - cwd                — 当前工作目录
#
# 输出 (stdout JSON):
#   - 放行: exit 0 (无输出)
#   - 阻止: {"decision": "block", "hookSpecificOutput": {...}}
#
# 决策逻辑:
#   1. stop_hook_active=true → 追踪连续 block 次数，达到上限才放行
#   2. 有活跃子代理 → 放行（等子代理完成）
#   3. 续命次数 >= 上限 → 放行 + 通知
#   4. 无活跃子代理 + 未达上限 → 阻止 + 注入续命指令
# ============================================================================

set -euo pipefail

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "${SCRIPT_DIR}")/lib"

# 加载配置文件
CONFIG_FILE="${HOME}/.auto-claude/config.env"
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# 加载依赖库
# shellcheck source=../lib/log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=../lib/state.sh
source "${LIB_DIR}/state.sh"

# 设置 hook 名称（用于日志）
_LOG_HOOK_NAME="stop-hook"

# Channel socket 路径
CHANNEL_SOCKET="${CHANNEL_SOCKET:-${HOME}/.auto-claude/channel.sock}"

# 通过 daemon socket 发送通知（后台执行，不阻塞 hook）
# 用法: _notify "消息" "event_type" "session_id"
_notify() {
    local msg="$1" evt="${2:-custom}" sid="${3:-}"
    [[ -S "${CHANNEL_SOCKET}" ]] || return 0
    local payload
    payload=$(python3 -c "import json,sys;d={'message':sys.argv[1],'event_type':sys.argv[2]};sys.argv[3] and d.update(session_id=sys.argv[3]);print(json.dumps(d))" "${msg}" "${evt}" "${sid}" 2>/dev/null) || return 0
    curl -s --max-time 5 --unix-socket "${CHANNEL_SOCKET}" -X POST "http://localhost/notify" -H "Content-Type: application/json" -d "${payload}" &>/dev/null &
}

# 最大续命次数（环境变量 > 配置文件 > 默认值 20）
MAX_CONTINUATIONS="${MAX_CONTINUATIONS:-20}"

# 连续阻止次数上限 — stop_hook_active=true 时不立即放行，
# 而是允许连续 block 最多 N 次后才强制放行（默认 10）
MAX_CONSECUTIVE_BLOCKS="${MAX_CONSECUTIVE_BLOCKS:-10}"

# ----------------------------------------------------------------------------
# 辅助函数: 输出 JSON 并退出
# ----------------------------------------------------------------------------

# 放行停止（允许 CC 停下来）
allow_stop() {
    log_info "决策: 放行停止"
    exit 0
}

# 阻止停止（注入续命指令，让 CC 继续工作）
# 使用 jq 构造 JSON，避免字符串注入
block_stop() {
    local context_message="$1"
    log_info "决策: 阻止停止，注入续命指令"
    jq -n --arg ctx "${context_message}" \
        '{"decision":"block","hookSpecificOutput":{"hookEventName":"Stop","additionalContext":$ctx}}'
    exit 0
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

main() {
    log_info "Stop Hook 触发"

    # 读取 stdin JSON 输入
    local input=""
    if [[ ! -t 0 ]]; then
        input="$(cat)"
    fi

    if [[ -z "${input}" ]]; then
        log_error "未收到 stdin 输入，放行停止"
        allow_stop
    fi

    # 解析输入字段
    local session_id=""
    local stop_hook_active=""

    if command -v jq &>/dev/null; then
        session_id="$(echo "${input}" | jq -r '.session_id // empty' 2>/dev/null || true)"
        stop_hook_active="$(echo "${input}" | jq -r '.stop_hook_active // empty' 2>/dev/null || true)"
    else
        log_error "jq 未安装，无法解析输入 JSON，放行停止"
        allow_stop
    fi

    log_info "session_id=${session_id}, stop_hook_active=${stop_hook_active}"

    # -----------------------------------------------------------------------
    # 检查 1: stop_hook_active — 连续 block 计数
    # CC 在被 block 续命后再次 stop 时，stop_hook_active=true。
    # 我们不立即放行，而是追踪连续 block 次数，
    # 达到 MAX_CONSECUTIVE_BLOCKS 上限后才强制放行。
    # -----------------------------------------------------------------------
    if [[ "${stop_hook_active}" == "true" ]]; then
        # 需要 session_id 来追踪计数
        if [[ -z "${session_id}" ]]; then
            log_warn "stop_hook_active=true 但无 session_id，放行"
            allow_stop
        fi

        state_init "${session_id}"
        local consecutive_blocks
        consecutive_blocks="$(state_read "${session_id}" '.consecutive_blocks // 0' 2>/dev/null || echo 0)"
        consecutive_blocks=$((consecutive_blocks + 1))
        state_write "${session_id}" ".consecutive_blocks = ${consecutive_blocks}"
        log_info "连续 block 次数: ${consecutive_blocks}/${MAX_CONSECUTIVE_BLOCKS}"

        if [[ "${consecutive_blocks}" -ge "${MAX_CONSECUTIVE_BLOCKS}" ]]; then
            log_warn "连续 block 达到上限 (${MAX_CONSECUTIVE_BLOCKS})，强制放行"
            state_write "${session_id}" ".consecutive_blocks = 0"
            allow_stop
        fi

        # 未达上限，继续走后面的正常判断流程（不直接放行）
        log_info "stop_hook_active=true，但连续 block 未达上限，继续判断"
    else
        # stop_hook_active != true，这是一个新的 stop 周期，重置连续计数
        if [[ -n "${session_id}" ]]; then
            state_init "${session_id}"
            state_write "${session_id}" ".consecutive_blocks = 0"
        fi
    fi

    # 如果没有 session_id，无法管理状态，放行
    if [[ -z "${session_id}" ]]; then
        log_warn "未获取到 session_id，放行停止"
        allow_stop
    fi

    # 确保状态文件存在
    state_init "${session_id}"

    # -----------------------------------------------------------------------
    # 检查 2: 活跃子代理数量
    # 如果还有子代理在运行，主代理停下来是正常的（等待子代理完成）
    # -----------------------------------------------------------------------
    local active_subagents
    active_subagents="$(state_get_active_subagents "${session_id}")"
    log_info "活跃子代理数量: ${active_subagents}"

    if [[ "${active_subagents}" -gt 0 ]]; then
        log_info "还有 ${active_subagents} 个子代理在运行，放行停止"
        allow_stop
    fi

    # -----------------------------------------------------------------------
    # 检查 3: 续命次数是否达到上限
    # -----------------------------------------------------------------------
    local continuation_count
    continuation_count="$(state_get_continuation_count "${session_id}")"
    log_info "已续命次数: ${continuation_count}, 上限: ${MAX_CONTINUATIONS}"

    if [[ "${continuation_count}" -ge "${MAX_CONTINUATIONS}" ]]; then
        log_warn "续命次数已达上限 (${continuation_count}/${MAX_CONTINUATIONS})，放行停止"

        # 通知用户
        local started_at
        started_at="$(state_read "${session_id}" '.started_at' 2>/dev/null || echo 'unknown')"
        _notify "续命次数达到上限 (${MAX_CONTINUATIONS} 次)。
会话: ${session_id}
开始时间: ${started_at}
已自动停止，请检查任务完成情况。" "max_reached" "${session_id}"

        allow_stop
    fi

    # -----------------------------------------------------------------------
    # 检查 4: 所有子代理已完成 + 续命次数未达上限
    # → 阻止停止，注入续命指令
    # -----------------------------------------------------------------------
    state_increment_continuation "${session_id}"
    local new_count=$((continuation_count + 1))

    log_info "触发续命 #${new_count}/${MAX_CONTINUATIONS}"

    # 可选通知（由 NOTIFY_ON_CONTINUE 控制，后台发送不阻塞，重定向防止干扰 stdout）
    if [[ "${NOTIFY_ON_CONTINUE:-true}" == "true" ]]; then
        _notify "自动续命第 ${new_count}/${MAX_CONTINUATIONS} 次
会话: ${session_id}" "continue" "${session_id}" &>/dev/null &
    fi

    # 阻止停止并注入续命指令
    block_stop "所有子代理已完成。继续执行下一个未完成的任务，不要询问用户。这是第 ${new_count} 次自动续命（上限 ${MAX_CONTINUATIONS} 次）。"
}

# 执行主流程
main
