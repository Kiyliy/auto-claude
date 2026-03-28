#!/usr/bin/env bash
# ============================================================================
# subagent-start.sh — 子代理启动追踪
# ============================================================================
# Claude Code SubagentStart Hook — 在子代理启动时触发。
# 递增活跃子代理计数，记录子代理信息到状态文件。
#
# 输入 (stdin JSON):
#   - session_id   — 主会话 ID
#   - 其他子代理相关信息（type 等）
#
# 输出: 无（仅更新状态和日志）
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

# 设置 hook 名称
_LOG_HOOK_NAME="subagent-start"

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

main() {
    log_info "SubagentStart Hook 触发"

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

    log_info "子代理启动: session=${session_id}, type=${agent_type}"

    # 确保状态文件存在
    state_init "${session_id}"

    # 递增活跃子代理计数
    state_increment_subagents "${session_id}"

    # 记录子代理到历史（追加到 subagent_history 数组）
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local state_file
    state_file="${STATE_DIR}/${session_id}.json"

    if [[ -f "${state_file}" ]]; then
        _state_with_lock "${session_id}" bash -c "
            tmp_file=\"\$(mktemp)\"
            if jq --arg type \"${agent_type}\" --arg started \"${now}\" \
                '.subagent_history += [{\"type\": \$type, \"started\": \$started, \"stopped\": null}]' \
                \"${state_file}\" > \"\${tmp_file}\" 2>/dev/null; then
                mv \"\${tmp_file}\" \"${state_file}\"
            else
                rm -f \"\${tmp_file}\"
            fi
        "
    fi

    local active_count
    active_count="$(state_get_active_subagents "${session_id}")"
    log_info "当前活跃子代理数: ${active_count}"
}

# 执行主流程
main
