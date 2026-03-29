#!/usr/bin/env bash
# inject-prompts.sh — Inject prompts/scoring.md into config/settings.json
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.json"
SCORING_FILE="${PROJECT_ROOT}/prompts/scoring.md"

command -v jq &>/dev/null || { echo "ERROR: jq required"; exit 1; }
[[ -f "${SETTINGS_FILE}" ]] || { echo "ERROR: ${SETTINGS_FILE} not found"; exit 1; }

if [[ -f "${SCORING_FILE}" ]]; then
    echo "[inject] scoring.md → Stop prompt"
    content="$(cat "${SCORING_FILE}")"
    tmp="$(mktemp)"
    jq --arg p "${content}" '.hooks.Stop[0].hooks[0].prompt = $p' "${SETTINGS_FILE}" > "${tmp}"
    mv "${tmp}" "${SETTINGS_FILE}"
else
    echo "ERROR: ${SCORING_FILE} not found"
    exit 1
fi

echo "[done]"
