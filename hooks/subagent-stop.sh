#!/usr/bin/env bash
# ============================================================================
# subagent-stop.sh — 子代理完成追踪
# ============================================================================
# Claude Code SubagentStop Hook — 在子代理完成时触发。
# 递减活跃子代理计数，更新子代理历史记录。
#
# 输入 (stdin JSON):
#   - session_id   — 主会话 ID
#   - 其他子代理相关信息（type 等）
#
# 输出: 无（仅更新状态和日志）
#
# 环境变量:
#   NOTIFY_ON_SUBAGENT — 是否在子代理完成时发送 Telegram 通知
#                         (true/false, 默认 false，避免刷屏)
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
# shellcheck source=./notify.sh
source "${SCRIPT_DIR}/notify.sh"

# 设置 hook 名称
_LOG_HOOK_NAME="subagent-stop"

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

main() {
    log_info "SubagentStop Hook 触发"

    # 读取 stdin JSON 输入
    local input=""
    if [[ ! -t 0 ]]; then
        input="$(cat)"
    fi

    if [[ -z "${input}" ]]; then
        log_warn "未收到 stdin 输入，跳过"
        exit 0
    fi

    # 解析输入字段
    local session_id=""
    local agent_type=""

    if command -v jq &>/dev/null; then
        session_id="$(echo "${input}" | jq -r '.session_id // empty' 2>/dev/null || true)"
        agent_type="$(echo "${input}" | jq -r '(.agent_type // .type // .subagent_type // "unknown")' 2>/dev/null || echo "unknown")"
    else
        log_error "jq 未安装，无法解析输入 JSON"
        exit 0
    fi

    if [[ -z "${session_id}" ]]; then
        log_warn "未获取到 session_id，跳过"
        exit 0
    fi

    log_info "子代理完成: session=${session_id}, type=${agent_type}"

    # 确保状态文件存在
    state_init "${session_id}"

    # 递减活跃子代理计数
    state_decrement_subagents "${session_id}"

    # 更新子代理历史（将最新一条该类型的 stopped=null 记录标记为完成）
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local state_file
    state_file="${STATE_DIR}/${session_id}.json"

    if [[ -f "${state_file}" ]]; then
        _state_with_lock "${session_id}" bash -c "
            tmp_file=\"\$(mktemp)\"
            if jq --arg type \"${agent_type}\" --arg stopped \"${now}\" '
                ([.subagent_history | to_entries[] |
                  select(.value.type == \$type and .value.stopped == null) |
                  .key] | if length > 0 then last else null end) as \$idx |
                if \$idx then .subagent_history[\$idx].stopped = \$stopped
                else . end
            ' \"${state_file}\" > \"\${tmp_file}\" 2>/dev/null; then
                mv \"\${tmp_file}\" \"${state_file}\"
            else
                rm -f \"\${tmp_file}\"
            fi
        "
    fi

    local active_count
    active_count="$(state_get_active_subagents "${session_id}")"
    log_info "当前活跃子代理数: ${active_count}"

    # 可选: 发送 Telegram 通知（后台发送，重定向防止干扰）
    if [[ "${NOTIFY_ON_SUBAGENT:-false}" == "true" ]]; then
        notify_telegram "子代理 ${agent_type} 已完成
会话: ${session_id}
剩余活跃: ${active_count}" "subagent" "${session_id}" &>/dev/null &
    fi
}

# 执行主流程
main
