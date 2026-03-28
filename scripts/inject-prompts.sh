#!/usr/bin/env bash
# ============================================================================
# inject-prompts.sh — 将 prompts/ 下的 .md 文件注入到配置和脚本中
# ============================================================================
# 从 prompts/ 目录读取 markdown 文件，更新：
#   - config/settings.json 中的 TeammateIdle prompt 字段
#   - 验证 stop-continue.md 存在（stop-hook.sh 在运行时读取它）
#
# 用法: bash scripts/inject-prompts.sh
# 幂等: 可安全多次运行
# ============================================================================

set -euo pipefail

# 获取项目根目录（脚本位于 scripts/ 下）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

PROMPTS_DIR="${PROJECT_ROOT}/prompts"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.json"

# ----------------------------------------------------------------------------
# 依赖检查
# ----------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed. Install with: apt install jq / brew install jq"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1. teammate-idle.md → config/settings.json TeammateIdle prompt
# ----------------------------------------------------------------------------
TEAMMATE_IDLE_FILE="${PROMPTS_DIR}/teammate-idle.md"

if [[ -f "${TEAMMATE_IDLE_FILE}" ]]; then
    echo "[inject-prompts] Reading ${TEAMMATE_IDLE_FILE}"

    # Read the prompt content
    prompt_content="$(cat "${TEAMMATE_IDLE_FILE}")"

    # Use jq to safely update the JSON (jq handles escaping automatically)
    if [[ -f "${SETTINGS_FILE}" ]]; then
        tmp_file="$(mktemp)"
        jq --arg prompt "${prompt_content}" \
            '.hooks.TeammateIdle[0].hooks[0].prompt = $prompt' \
            "${SETTINGS_FILE}" > "${tmp_file}"
        mv "${tmp_file}" "${SETTINGS_FILE}"
        echo "[inject-prompts] Updated TeammateIdle prompt in ${SETTINGS_FILE}"
    else
        echo "WARNING: ${SETTINGS_FILE} not found, skipping TeammateIdle injection"
    fi
else
    echo "WARNING: ${TEAMMATE_IDLE_FILE} not found, skipping TeammateIdle injection"
fi

# ----------------------------------------------------------------------------
# 2. stop-continue.md — verify it exists (stop-hook.sh reads it at runtime)
# ----------------------------------------------------------------------------
STOP_CONTINUE_FILE="${PROMPTS_DIR}/stop-continue.md"

if [[ -f "${STOP_CONTINUE_FILE}" ]]; then
    echo "[inject-prompts] Verified ${STOP_CONTINUE_FILE} exists"
    echo "[inject-prompts]   stop-hook.sh will read it at runtime and substitute {{count}} / {{max}}"
else
    echo "WARNING: ${STOP_CONTINUE_FILE} not found"
    echo "  stop-hook.sh will fall back to hardcoded default message"
fi

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
echo "[inject-prompts] Done."
