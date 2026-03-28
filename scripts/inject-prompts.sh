#!/usr/bin/env bash
# ============================================================================
# inject-prompts.sh — 将 prompts/ 下的 .md 文件注入到 config/settings.json
# ============================================================================
# 注入内容：
#   - prompts/teammate-idle.md  → TeammateIdle hook prompt
#   - prompts/stop-judge.md     → Stop hook prompt (Haiku 自主探索判断)
#   - 验证 stop-continue.md 存在（stop-hook.sh 运行时读取）
#
# 用法: bash scripts/inject-prompts.sh
# 幂等: 可安全多次运行
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

PROMPTS_DIR="${PROJECT_ROOT}/prompts"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.json"

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install: apt install jq / brew install jq"
    exit 1
fi

if [[ ! -f "${SETTINGS_FILE}" ]]; then
    echo "ERROR: ${SETTINGS_FILE} not found"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1. teammate-idle.md → TeammateIdle hook prompt
# ----------------------------------------------------------------------------
TEAMMATE_IDLE_FILE="${PROMPTS_DIR}/teammate-idle.md"

if [[ -f "${TEAMMATE_IDLE_FILE}" ]]; then
    echo "[inject] teammate-idle.md → TeammateIdle prompt"
    prompt_content="$(cat "${TEAMMATE_IDLE_FILE}")"
    tmp_file="$(mktemp)"
    jq --arg prompt "${prompt_content}" \
        '.hooks.TeammateIdle[0].hooks[0].prompt = $prompt' \
        "${SETTINGS_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${SETTINGS_FILE}"
else
    echo "WARN: ${TEAMMATE_IDLE_FILE} not found, skipping"
fi

# ----------------------------------------------------------------------------
# 2. stop-judge.md → Stop hook 增加 prompt 类型判断（Haiku 自主探索）
# ----------------------------------------------------------------------------
STOP_JUDGE_FILE="${PROMPTS_DIR}/stop-judge.md"

if [[ -f "${STOP_JUDGE_FILE}" ]]; then
    echo "[inject] stop-judge.md → Stop hook prompt (Haiku judge)"
    judge_content="$(cat "${STOP_JUDGE_FILE}")"

    tmp_file="$(mktemp)"
    # 在 Stop 事件的 hooks 数组最前面插入 prompt 类型 hook
    # 如果已存在 prompt 类型则更新，不重复插入
    jq --arg prompt "${judge_content}" '
        # 检查 Stop hooks 数组第一个元素是否已经是 prompt 类型
        if .hooks.Stop[0].hooks[0].type == "prompt" then
            .hooks.Stop[0].hooks[0].prompt = $prompt
        else
            # 在现有 hooks 前面插入 prompt hook
            .hooks.Stop[0].hooks = [{"type": "prompt", "prompt": $prompt}] + .hooks.Stop[0].hooks
        end
    ' "${SETTINGS_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${SETTINGS_FILE}"
else
    echo "WARN: ${STOP_JUDGE_FILE} not found, skipping"
fi

# ----------------------------------------------------------------------------
# 3. 验证 stop-continue.md 存在
# ----------------------------------------------------------------------------
STOP_CONTINUE_FILE="${PROMPTS_DIR}/stop-continue.md"

if [[ -f "${STOP_CONTINUE_FILE}" ]]; then
    echo "[inject] stop-continue.md exists (stop-hook.sh reads at runtime)"
else
    echo "WARN: ${STOP_CONTINUE_FILE} not found, stop-hook.sh will use default"
fi

echo "[inject] Done."
