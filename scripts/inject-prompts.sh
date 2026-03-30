#!/usr/bin/env bash
# inject-prompts.sh — Validate prompts and show scoring info
# Haiku reads scoring.md directly from disk, no injection needed.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[check] prompts/scoring.md"
if [[ -f "${PROJECT_ROOT}/prompts/scoring.md" ]]; then
    lines=$(wc -l < "${PROJECT_ROOT}/prompts/scoring.md")
    echo "  OK (${lines} lines) — Haiku reads this at review time"
else
    echo "  MISSING — create prompts/scoring.md"
    exit 1
fi

echo "[check] config/settings.json"
if [[ -f "${PROJECT_ROOT}/config/settings.json" ]]; then
    hooks=$(jq '[.hooks | keys[]]' "${PROJECT_ROOT}/config/settings.json" 2>/dev/null)
    echo "  OK — hooks: ${hooks}"
else
    echo "  MISSING"
    exit 1
fi

echo "[done] Haiku reads scoring.md directly — no injection needed."
echo "  Install settings: cp config/settings.json ~/.claude/settings.json"
echo "  Then fix the path: /path/to/auto-claude → actual path"
