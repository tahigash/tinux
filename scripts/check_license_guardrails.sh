#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# Tinux Clean-Room License & Binary Guardrail Wrapper
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if python -c "import sys" >/dev/null 2>&1; then
    PYTHON_BIN="python"
elif python3 -c "import sys" >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif py -c "import sys" >/dev/null 2>&1; then
    PYTHON_BIN="py"
else
    echo "[GUARDRAIL ERROR] Python interpreter not found." >&2
    exit 1
fi

exec "$PYTHON_BIN" "${SCRIPT_DIR}/check_license_guardrails.py" "$@"
