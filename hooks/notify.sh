#!/usr/bin/env bash
# ============================================================================
# notify.sh — Telegram 通知工具（支持 Channel / Direct 双模式）
# ============================================================================
# 既可以作为库被 source 引入，也可以直接命令行调用。
#
# 通知后端（按优先级）:
#   1. Channel 模式: POST via Unix socket ~/.auto-claude/channel.sock /notify
#   2. Direct 模式:  curl Telegram Bot API（回退方案）
#
# 作为库使用:
#   source notify.sh
#   notify_telegram "消息内容"
#
# 命令行使用:
#   notify.sh error "错误信息"
#   notify.sh complete "任务完成"
#   notify.sh continue "续命第 N 次"
#   notify.sh max_reached "续命次数已达上限"
#   notify.sh custom "自定义消息"
#
# 配置（环境变量或 ~/.auto-claude/config.env）:
#   TG_BOT_TOKEN     — Telegram Bot Token
#   TG_CHAT_ID       — 接收通知的 Chat ID
#   CHANNEL_SOCKET   — Channel daemon Unix socket 路径
#                      （默认 ~/.auto-claude/channel.sock）
# ============================================================================

# 获取脚本所在目录（支持被 source 和直接调用两种方式）
_NOTIFY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NOTIFY_LIB_DIR="$(dirname "${_NOTIFY_SCRIPT_DIR}")/lib"

# 加载日志工具（如果还没加载的话）
if ! declare -f log_info &>/dev/null; then
    if [[ -f "${_NOTIFY_LIB_DIR}/log.sh" ]]; then
        # shellcheck source=../lib/log.sh
        source "${_NOTIFY_LIB_DIR}/log.sh"
    else
        # 降级模式：日志函数退化为 stderr 输出
        log_info()  { echo "[INFO] $1" >&2; }
        log_warn()  { echo "[WARN] $1" >&2; }
        log_error() { echo "[ERROR] $1" >&2; }
    fi
fi

# 加载配置文件（如果存在）
_NOTIFY_CONFIG="${HOME}/.auto-claude/config.env"
if [[ -f "${_NOTIFY_CONFIG}" ]]; then
    # shellcheck source=/dev/null
    source "${_NOTIFY_CONFIG}"
fi

# ----------------------------------------------------------------------------
# _notify_via_channel — Channel 模式：POST 到 daemon Unix socket
# 参数:
#   $1 — 原始消息内容
#   $2 — 事件类型 (error / complete / continue / max_reached / subagent / custom)
#   $3 — (可选) session_id，用于路由到正确的 topic
# 返回: 0=成功, 1=失败（服务不可达或返回非 2xx）
# ----------------------------------------------------------------------------
_notify_via_channel() {
    local message="$1"
    local event_type="${2:-custom}"
    local session_id="${3:-${_NOTIFY_SESSION_ID:-}}"
    local socket="${CHANNEL_SOCKET:-${HOME}/.auto-claude/channel.sock}"

    # 检查 socket 文件是否存在
    if [[ ! -S "${socket}" ]]; then
        log_warn "Channel 模式: socket 不存在 (${socket})，跳过"
        return 1
    fi

    # 构造 JSON payload — 使用 python3 确保正确转义
    local payload
    payload=$(python3 -c "
import json, sys
d = {'message': sys.argv[1], 'event_type': sys.argv[2]}
if len(sys.argv) > 3 and sys.argv[3]:
    d['session_id'] = sys.argv[3]
print(json.dumps(d))
" "${message}" "${event_type}" "${session_id}" 2>/dev/null)

    if [[ -z "${payload}" ]]; then
        log_warn "Channel 模式: JSON 构造失败，跳过"
        return 1
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --max-time 5 \
        --connect-timeout 2 \
        --unix-socket "${socket}" \
        -X POST "http://localhost/notify" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        2>/dev/null)

    local http_code
    http_code=$(echo "${response}" | tail -1)

    if [[ "${http_code}" =~ ^2[0-9]{2}$ ]]; then
        log_info "Channel 通知发送成功 (socket ${socket})"
        return 0
    else
        log_warn "Channel 通知失败 (HTTP ${http_code})，将回退到 Direct 模式"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# _notify_via_direct — Direct 模式：直接调用 Telegram Bot API
# 参数:
#   $1 — 已格式化的消息内容（支持 Markdown）
# 返回: 0=成功, 1=失败
# ----------------------------------------------------------------------------
_notify_via_direct() {
    local message="$1"

    # 检查必要配置（使用 :- 防止 nounset 报错）
    if [[ -z "${TG_BOT_TOKEN:-}" ]] || [[ -z "${TG_CHAT_ID:-}" ]]; then
        log_info "Telegram 未配置（TG_BOT_TOKEN 或 TG_CHAT_ID 缺失），通知仅记录日志"
        log_info "通知内容: ${message}"
        return 0  # 不视为错误，优雅降级
    fi

    # 发送 Telegram 消息
    local api_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    local response
    response=$(curl -s -w "\n%{http_code}" \
        --max-time 10 \
        -X POST "${api_url}" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        2>/dev/null)

    # 解析 HTTP 状态码（response 最后一行）
    local http_code
    http_code=$(echo "${response}" | tail -1)
    local body
    body=$(echo "${response}" | sed '$d')

    if [[ "${http_code}" == "200" ]]; then
        log_info "Telegram 通知发送成功 (Direct 模式)"
        return 0
    else
        log_error "Telegram 通知发送失败 (HTTP ${http_code}): ${body}"
        # 如果 Markdown 解析失败，尝试纯文本重发
        if [[ "${http_code}" == "400" ]]; then
            log_info "尝试以纯文本模式重发..."
            curl -s --max-time 10 \
                -X POST "${api_url}" \
                -d "chat_id=${TG_CHAT_ID}" \
                -d "text=${message}" \
                &>/dev/null
        fi
        return 1
    fi
}

# ----------------------------------------------------------------------------
# notify_telegram — 发送 Telegram 消息（自动选择 Channel / Direct 后端）
# 参数:
#   $1 — 消息内容（支持 Markdown 格式）
#   $2 — (可选) 事件类型，用于 Channel 模式传递原始 event_type
# 返回: 0=成功, 1=失败（无配置或发送失败）
# 说明:
#   - 优先尝试 Channel 模式（localhost HTTP 服务）
#   - Channel 不可用时回退到 Direct 模式（Telegram Bot API）
#   - 如果未配置 token/chat_id 且 Channel 也不可用，仅记录日志，不报错
# ----------------------------------------------------------------------------
notify_telegram() {
    local message="$1"
    local event_type="${2:-custom}"
    local session_id="${3:-${_NOTIFY_SESSION_ID:-}}"

    if [[ -z "${message}" ]]; then
        log_warn "notify_telegram: 消息内容为空，跳过"
        return 1
    fi

    # 检查 curl 是否可用
    if ! command -v curl &>/dev/null; then
        log_error "curl 未安装，无法发送通知"
        log_info "通知内容: ${message}"
        return 1
    fi

    # 优先尝试 Channel 模式 — 发送原始消息 + event_type + session_id，由服务端格式化
    if _notify_via_channel "${message}" "${event_type}" "${session_id}"; then
        return 0
    fi

    # Channel 不可用，回退到 Direct 模式 — 本地格式化后发送
    local formatted_message
    formatted_message="$(_notify_format_message "${event_type}" "${message}")"
    _notify_via_direct "${formatted_message}"
}

# ----------------------------------------------------------------------------
# _notify_format_message — 根据事件类型格式化通知消息
# 参数:
#   $1 — 事件类型 (error / complete / continue / max_reached / custom)
#   $2 — 消息内容
# 输出: 格式化后的 Markdown 消息
# ----------------------------------------------------------------------------
_notify_format_message() {
    local event_type="$1"
    local message="$2"
    local hostname
    # 替换 hostname 中的下划线为短横线，避免破坏 Telegram Markdown 解析
    hostname="$(hostname 2>/dev/null || echo 'unknown')"
    hostname="${hostname//_/-}"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"

    case "${event_type}" in
        error)
            echo "*Auto-Claude 错误*
_${hostname} | ${timestamp}_

${message}"
            ;;
        complete)
            echo "*Auto-Claude 任务完成*
_${hostname} | ${timestamp}_

${message}"
            ;;
        continue)
            echo "*Auto-Claude 自动续命*
_${hostname} | ${timestamp}_

${message}"
            ;;
        max_reached)
            echo "*Auto-Claude 续命上限*
_${hostname} | ${timestamp}_

${message}

需要人工介入。"
            ;;
        subagent)
            echo "*Auto-Claude 子代理事件*
_${hostname} | ${timestamp}_

${message}"
            ;;
        *)
            # custom 或未知类型：原样输出
            echo "*Auto-Claude*
_${hostname} | ${timestamp}_

${message}"
            ;;
    esac
}

# ============================================================================
# 命令行入口 — 仅在直接调用时执行（被 source 时不执行）
# ============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 直接调用模式: notify.sh <event_type> <message>
    event_type="${1:-custom}"
    shift 2>/dev/null || true
    message="$*"

    if [[ -z "${message}" ]]; then
        # 如果没有消息参数，尝试从 stdin 读取
        if [[ ! -t 0 ]]; then
            message="$(cat)"
        fi
    fi

    if [[ -z "${message}" ]]; then
        log_error "用法: notify.sh <event_type> <message>"
        log_error "  event_type: error | complete | continue | max_reached | subagent | custom"
        exit 1
    fi

    # 传递原始消息 + event_type 给 notify_telegram
    # Channel 模式会发送原始消息（服务端格式化）
    # Direct 模式会在 notify_telegram 内部调用 _notify_format_message 格式化
    notify_telegram "${message}" "${event_type}"
    exit $?
fi
