#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Tinux Specification Readiness & Quality Validator (TASK-001 .. TASK-020)
# Validates:
#   1. Existence and non-emptiness (>30 lines)
#   2. Absence of STATUS: PLACEHOLDER tags
#   3. Zero stray clipboard markers (^\d+\s+---)
#   4. Zero non-ASCII / Japanese characters (ord > 127)
# ==============================================================================

# Locate Python interpreter for exact byte-level character validation
PYTHON_BIN=""
for cand in python python3 py; do
    if "$cand" -c 'import sys' >/dev/null 2>&1; then
        PYTHON_BIN="$cand"
        break
    fi
done

echo "Checking Tinux specification readiness (TASK-001 .. TASK-020)..."
READY_COUNT=0
TOTAL_SPECS=20

for num in $(seq -f "%03g" 1 "$TOTAL_SPECS"); do
    FILE="docs/specs/SPEC_TASK_${num}.md"

    if [ ! -f "$FILE" ]; then
        echo "  [PENDING] $FILE (file missing)"
        continue
    fi

    LINE_COUNT=$(wc -l < "$FILE" | tr -d ' ')
    if [ "$LINE_COUNT" -le 30 ]; then
        echo "  [PENDING] $FILE (fewer than 30 lines: $LINE_COUNT lines)"
        continue
    fi

    if grep -q "STATUS: PLACEHOLDER" "$FILE"; then
        echo "  [PENDING] $FILE (contains STATUS: PLACEHOLDER)"
        continue
    fi

    if grep -qE "^[0-9]+[[:space:]]+---" "$FILE"; then
        echo "  [PENDING] $FILE (contains clipboard marker '^[0-9]+ ---')"
        continue
    fi

    # Enforce pure ASCII (0 non-ASCII / Japanese characters, ord <= 127)
    HAS_NON_ASCII=0
    if [ -n "$PYTHON_BIN" ]; then
        if ! "$PYTHON_BIN" -c '
import sys
try:
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    sys.exit(1 if any(b > 127 for b in data) else 0)
except Exception:
    sys.exit(2)
' "$FILE" >/dev/null 2>&1; then
            HAS_NON_ASCII=1
        fi
    else
        # Fallback using tr to count bytes outside standard 7-bit ASCII
        NON_ASCII_COUNT=$(LC_ALL=C tr -d '\000-\177' < "$FILE" | wc -c | tr -d ' ')
        if [ "$NON_ASCII_COUNT" -gt 0 ]; then
            HAS_NON_ASCII=1
        fi
    fi

    if [ "$HAS_NON_ASCII" -eq 1 ]; then
        echo "  [PENDING] $FILE (contains non-ASCII or Japanese characters)"
        continue
    fi

    echo "  [READY]   $FILE"
    READY_COUNT=$((READY_COUNT + 1))
done

echo "Summary: ${READY_COUNT}/${TOTAL_SPECS} specifications ready for Builder execution."

if [ "$READY_COUNT" -eq "$TOTAL_SPECS" ]; then
    exit 0
else
    exit 1
fi
