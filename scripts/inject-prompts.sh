#!/usr/bin/env bash
# ============================================================================
# inject-prompts.sh — 将 prompts/*.md 注入到 config/settings.json
# ============================================================================
# 注入: scoring.md → Stop prompt, teammate-idle.md → TeammateIdle prompt
# 用法: bash scripts/inject-prompts.sh
# ============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPTS_DIR="${PROJECT_ROOT}/prompts"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.json"

command -v jq &>/dev/null || { echo "ERROR: jq required"; exit 1; }
[[ -f "${SETTINGS_FILE}" ]] || { echo "ERROR: ${SETTINGS_FILE} not found"; exit 1; }

inject() {
    local file="$1" jq_expr="$2" label="$3"
    if [[ -f "${file}" ]]; then
        echo "[inject] ${label}"
        local content
        content="$(cat "${file}")"
        local tmp
        tmp="$(mktemp)"
        jq --arg p "${content}" "${jq_expr}" "${SETTINGS_FILE}" > "${tmp}"
        mv "${tmp}" "${SETTINGS_FILE}"
    else
        echo "WARN: ${file} not found"
    fi
}

# scoring.md → Stop hook prompt (第一个 hook)
inject "${PROMPTS_DIR}/scoring.md" \
    '.hooks.Stop[0].hooks[0].prompt = $p' \
    "scoring.md → Stop prompt"

# teammate-idle.md → TeammateIdle hook prompt
inject "${PROMPTS_DIR}/teammate-idle.md" \
    '.hooks.TeammateIdle[0].hooks[0].prompt = $p' \
    "teammate-idle.md → TeammateIdle prompt"

# 验证 continue.md 存在（stop-hook.sh 运行时读取）
if [[ -f "${PROMPTS_DIR}/continue.md" ]]; then
    echo "[ok] continue.md exists (stop-hook.sh reads at runtime)"
else
    echo "WARN: continue.md not found"
fi

echo "[done]"
