#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
PASS=0
WARN=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo -e "  [${GREEN}PASS${NC}]$*"; }
warn() { WARN=$((WARN + 1)); echo -e "  [${YELLOW}WARN${NC}]$*"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  [${RED}FAIL${NC}]$*"; }
echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  Tinux Pre-Flight Readiness Verification${NC}"
echo -e "${BOLD}======================================================================${NC}"
# 1. Check Core Binary Tools
echo -e "\n${CYAN}[1/5] Checking Toolchain & Emulator Binaries${NC}"
for cmd in zig qemu-system-x86_64 cpio tar python3 git timeout; do
    if command -v "$cmd" >/dev/null 2>&1; then
        VER=$("$cmd" --version 2>&1 | head -n 1 || true)
        ok "$cmd ($VER)"
    else
        if [[ "$cmd" == "timeout" ]] && command -v gtimeout >/dev/null 2>&1; then
            warn "'timeout' missing (macOS detected), but 'gtimeout' is available. Alias or symlink gtimeout -> time
        else
            fail "Missing required command: $cmd"
        fi
    fi
done
# 2. Detect Zig Version & Calling Convention Style
echo -e "\n${CYAN}[2/5] Probing Zig Compiler Version & Freestanding Target${NC}"
if command -v zig >/dev/null 2>&1; then
    ZIG_VER=$(zig version)
    ok "Detected Zig version: $ZIG_VER"
    TMP_ZIG=$(mktemp /tmp/tinux_zig_probe_XXXXXX.zig)
    cat << 'EOF' > "$TMP_ZIG"
export fn _start() callconv(.C) void {}
EOF
    if zig ast-check "$TMP_ZIG" >/dev/null 2>&1; then
        ok "Zig calling convention syntax: supports 'callconv(.C)' / 'callconv(.Naked)'"
    else
        warn "Zig $ZIG_VER uses lowercase calling conventions ('callconv(.c)' / 'callconv(.naked)'). See Section 2.1
    fi
    rm -f "$TMP_ZIG"
fi
# 3. Verify QEMU isa-debug-exit & virtio Devices
echo -e "\n${CYAN}[3/5] Verifying QEMU x86_64 Device Support${NC}"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    DEV_HELP=$(qemu-system-x86_64 -device help 2>&1 || true)
    for dev in "isa-debug-exit" "virtio-blk-pci" "virtio-net-pci"; do
        if echo "$DEV_HELP" \vert{} grep -q "$dev"; then
            ok "QEMU device supported: $dev"
        else
            fail "QEMU missing device support: $dev"


188 ---
        fi
    done
fi
# 4. Verify Script Permissions & ABI Inspector Probe
echo -e "\n${CYAN}[4/5] Verifying Helper Scripts & Linux ABI Probe${NC}"
chmod +x init_project.sh scripts/*.sh scripts/*.py tools/*.py 2>/dev/null || true
ok "Set executable permissions (+x) on scripts/ and tools/"
if [[ -x "./tools/tinux_abi_mcp.py" ]]; then
    if ./tools/tinux_abi_mcp.py syscall write >/dev/null 2>&1; then
        ok "tools/tinux_abi_mcp.py Linux x86_64 header probe working"
    else
        warn "tools/tinux_abi_mcp.py probe returned non-zero (check python3 / zig env)"
    fi
else
    warn "tools/tinux_abi_mcp.py not yet placed"
fi
# 5. Verify Specification Files (TASK-001 .. TASK-020)
echo -e "\n${CYAN}[5/5] Checking Specification Files (docs/specs/SPEC_TASK_001..020.md)${NC}"
if [[ -x "./scripts/check_specs.sh" ]]; then
    ./scripts/check_specs.sh
else
    warn "scripts/check_specs.sh not found"
fi
echo -e "\n${BOLD}======================================================================${NC}"
echo -e "  Pre-Flight Summary: ${GREEN}${PASS} Passed${NC}, ${YELLOW}${WARN} Warnings${NC},${RED}${FAIL} Failed${NC}
echo -e "${BOLD}======================================================================${NC}"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
