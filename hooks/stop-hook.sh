#!/usr/bin/env bash
# ============================================================================
# stop-hook.sh — 主控：智能续命
# ============================================================================
# Claude Code Stop Hook — 在主代理即将停止时触发。
# 根据当前状态智能决定：放行停止 or 阻止停止并注入续命指令。
#
# 同时检查所有信号源（不是互斥的）:
#   - active_subagents  — 来自 state.sh 手动计数（SubagentStart/Stop hook）
#   - active_teammates  — 来自 CC 原生 ~/.claude/teams/ config.json
#   - pending_tasks     — 来自 CC 原生 ~/.claude/tasks/ 目录
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
# 决策逻辑（同时检查所有信号，不是互斥模式）:
#   1. stop_hook_active=true → 追踪连续 block 次数，达到上限才放行
#   2. active_subagents > 0 OR active_teammates > 0 → 放行（agent 还在干活）
#   3. pending_tasks > 0 且无活跃 agent → 阻止（还有未完成 task，需要分配）
#   4. 续命次数 >= 上限 → 放行 + 通知
#   5. 全部 == 0 且未达上限 → 阻止 + 注入续命指令
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

# CC 原生 Agent Team 状态目录
CC_TEAMS_DIR="${HOME}/.claude/teams"
CC_TASKS_DIR="${HOME}/.claude/tasks"

# ----------------------------------------------------------------------------
# Agent Team 辅助函数
# ----------------------------------------------------------------------------

# _detect_team — 检测当前 session 是否是某个 team 的 lead
# 参数:
#   $1 — session_id
# 输出: team name（找到时），空字符串（未找到时）
_detect_team() {
    local session_id="$1"

    # 目录不存在则快速返回
    if [[ ! -d "${CC_TEAMS_DIR}" ]]; then
        echo ""
        return 0
    fi

    local config_file team_dir team_name lead_sid
    for config_file in "${CC_TEAMS_DIR}"/*/config.json; do
        [[ -f "${config_file}" ]] || continue
        lead_sid="$(jq -r '.leadSessionId // empty' "${config_file}" 2>/dev/null || true)"
        if [[ "${lead_sid}" == "${session_id}" ]]; then
            team_dir="$(dirname "${config_file}")"
            team_name="$(basename "${team_dir}")"
            echo "${team_name}"
            return 0
        fi
    done

    echo ""
    return 0
}

# _get_active_teammates — 获取 team 活跃 teammate 数量（不含 lead）
# 参数:
#   $1 — team_name
# 输出: 活跃 teammate 数量（整数）
_get_active_teammates() {
    local team_name="$1"
    local config="${CC_TEAMS_DIR}/${team_name}/config.json"

    if [[ ! -f "${config}" ]]; then
        echo "0"
        return 0
    fi

    local count
    # members 数组包含 lead 自己，所以 -1；最小为 0
    count="$(jq '[(.members | length) - 1, 0] | max' "${config}" 2>/dev/null || echo 0)"

    # 确保返回有效整数
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "${count}"
    fi
}

# _get_pending_tasks — 获取 team 未完成 task 数量
# 参数:
#   $1 — team_name
# 输出: 未完成 task 数量（整数）
_get_pending_tasks() {
    local team_name="$1"
    local task_dir="${CC_TASKS_DIR}/${team_name}"

    if [[ ! -d "${task_dir}" ]]; then
        echo "0"
        return 0
    fi

    local pending=0 task_file status
    for task_file in "${task_dir}"/*.json; do
        [[ -f "${task_file}" ]] || continue
        # 跳过 highwatermark 等非 task 文件
        [[ "$(basename "${task_file}")" == ".highwatermark" ]] && continue
        status="$(jq -r '.status // "unknown"' "${task_file}" 2>/dev/null || echo "unknown")"
        if [[ "${status}" != "completed" ]]; then
            pending=$((pending + 1))
        fi
    done

    echo "${pending}"
}

# ----------------------------------------------------------------------------
# 辅助函数: 输出 JSON 并退出
# ----------------------------------------------------------------------------

# 放行停止（允许 CC 停下来）
allow_stop() {
    log_info "决策: 放行停止"
    exit 0
}

# 阻止停止（注入续命指令，让 CC 继续工作）
# 使用 exit 2 + stderr 消息，CC 读取 stderr 后继续工作
block_stop() {
    local context_message="$1"
    log_info "决策: 阻止停止，注入续命指令"
    echo "${context_message}" >&2
    exit 2
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
    # 检查 2: 收集所有信号源（同时检查，不是互斥模式）
    #   - active_subagents  ← state.sh 手动计数
    #   - active_teammates  ← CC 原生 ~/.claude/teams/ config.json
    #   - pending_tasks     ← CC 原生 ~/.claude/tasks/ 目录
    # -----------------------------------------------------------------------
    local detected_team=""
    local active_teammates=0
    local pending_tasks=0
    local active_subagents=0

    # 2a: 读取手动追踪的 subagent 计数（始终检查）
    active_subagents="$(state_get_active_subagents "${session_id}")"

    # 2b: 检测 Agent Team（始终检查）
    detected_team="$(_detect_team "${session_id}")"
    if [[ -n "${detected_team}" ]]; then
        active_teammates="$(_get_active_teammates "${detected_team}")"
        pending_tasks="$(_get_pending_tasks "${detected_team}")"
    fi

    # 汇总日志：三个信号源全部可见
    log_info "信号汇总: subagents=${active_subagents}, teammates=${active_teammates}, pending_tasks=${pending_tasks}, team=${detected_team:-none}"

    # 2c: 有活跃 agent（subagent 或 teammate）→ 放行（agent 还在干活）
    if [[ "${active_subagents}" -gt 0 ]] || [[ "${active_teammates}" -gt 0 ]]; then
        log_info "还有活跃 agent (subagents=${active_subagents}, teammates=${active_teammates})，放行停止"
        allow_stop
    fi

    # 2d: 无活跃 agent，但有未完成 task → 需要续命（让 lead 继续分配）
    #     走后面的续命流程

    # 2e: 全部 == 0 → 真正完成（无 agent、无 pending task）
    if [[ "${active_subagents}" -eq 0 ]] && [[ "${active_teammates}" -eq 0 ]] && [[ "${pending_tasks}" -eq 0 ]] && [[ -n "${detected_team}" ]]; then
        log_info "全部完成 (team=${detected_team}, 所有信号为 0)，放行停止"

        # 通知用户
        local started_at
        started_at="$(state_read "${session_id}" '.started_at' 2>/dev/null || echo 'unknown')"
        local cont_count
        cont_count="$(state_get_continuation_count "${session_id}")"
        _notify "Agent Team 全部完成！
团队: ${detected_team}
会话: ${session_id}
开始时间: ${started_at}
续命次数: ${cont_count}" "team_complete" "${session_id}"

        allow_stop
    fi

    # 到这里说明：无活跃 agent，但有 pending_tasks > 0（或非 team 模式的普通续命）
    if [[ "${pending_tasks}" -gt 0 ]]; then
        log_info "还有 ${pending_tasks} 个未完成任务，准备续命"
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
        local notify_msg="续命次数达到上限 (${MAX_CONTINUATIONS} 次)。
会话: ${session_id}
开始时间: ${started_at}
已自动停止，请检查任务完成情况。"
        if [[ -n "${detected_team}" ]]; then
            notify_msg="[Agent Team: ${detected_team}] ${notify_msg}
未完成任务: ${pending_tasks}"
        fi
        _notify "${notify_msg}" "max_reached" "${session_id}"

        allow_stop
    fi

    # -----------------------------------------------------------------------
    # 检查 4: 需要续命 — 阻止停止，注入续命指令
    # -----------------------------------------------------------------------
    state_increment_continuation "${session_id}"
    local new_count=$((continuation_count + 1))

    log_info "触发续命 #${new_count}/${MAX_CONTINUATIONS}"

    # 可选通知（由 NOTIFY_ON_CONTINUE 控制，后台发送不阻塞，重定向防止干扰 stdout）
    if [[ "${NOTIFY_ON_CONTINUE:-true}" == "true" ]]; then
        local continue_msg="自动续命第 ${new_count}/${MAX_CONTINUATIONS} 次
会话: ${session_id}"
        if [[ -n "${detected_team}" ]]; then
            continue_msg="[Agent Team: ${detected_team}] ${continue_msg}
未完成任务: ${pending_tasks}"
        fi
        _notify "${continue_msg}" "continue" "${session_id}" &>/dev/null &
    fi

    # 阻止停止并注入续命指令（根据模式选择不同的 prompt 模板）
    local context_msg
    local PROMPT_DIR="${SCRIPT_DIR}/../prompts"

    local PROMPT_FILE="${PROMPT_DIR}/stop-continue.md"
    if [[ -f "${PROMPT_FILE}" ]]; then
        context_msg="$(cat "${PROMPT_FILE}")"
    else
        context_msg="继续执行下一个未完成的任务。第 {{count}}/{{max}} 次续命。"
    fi

    # 替换通用占位符
    context_msg="${context_msg//\{\{count\}\}/${new_count}}"
    context_msg="${context_msg//\{\{max\}\}/${MAX_CONTINUATIONS}}"

    block_stop "${context_msg}"
}

# 执行主流程
main
