#!/usr/bin/env bash
set -euo pipefail
echo "Checking Tinux specification readiness (TASK-001 .. TASK-020)..."
READY_COUNT=0
TOTAL_SPECS=20
for num in $(seq -f "%03g" 1 "$TOTAL_SPECS"); do
    FILE="docs/specs/SPEC_TASK_${num}.md"
    if [ -f "$FILE" ] && ! grep -q "STATUS: PLACEHOLDER" "$FILE" && [ "$(wc -l < "$FILE")" -gt 30 ]; then
        echo "  [READY]   $FILE"
        READY_COUNT=$((READY_COUNT + 1))
    else
        echo "  [PENDING] $FILE (needs full specification pasted)"
    fi
done
echo "Summary: ${READY_COUNT}/${TOTAL_SPECS} specifications ready for Builder execution."
