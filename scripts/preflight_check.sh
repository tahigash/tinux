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
ok()   { PASS=$((PASS + 1)); echo -e "  [${GREEN}PASS${NC}] $*"; }
warn() { WARN=$((WARN + 1)); echo -e "  [${YELLOW}WARN${NC}] $*"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  [${RED}FAIL${NC}] $*"; }
echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD}  Tinux Pre-Flight Readiness Verification${NC}"
echo -e "${BOLD}======================================================================${NC}"
# Auto-detect portable Zig if not already in PATH
if ! command -v zig >/dev/null 2>&1; then
    for candidate_dir in \
        "/c/Users/takashi/bin/zig-windows-x86_64-0.13.0" \
        "/c/Users/takashi/bin" \
        "$HOME/bin/zig-windows-x86_64-0.13.0" \
        "$HOME/bin" \
        ".cache/toolchain/zig-windows-x86_64-0.13.0" \
        ".cache/toolchain/zig-0.13.0" \
        "$HOME/.local/bin"; do
        if [[ -f "$candidate_dir/zig.exe" ]] || [[ -f "$candidate_dir/zig" ]]; then
            export PATH="$candidate_dir:$PATH"
            break
        fi
    done
fi

# Auto-detect QEMU emulator if not already in PATH
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for candidate_dir in \
        "/c/Users/takashi/bin/qemu" \
        "/c/Program Files/qemu" \
        "$HOME/bin/qemu" \
        "/c/qemu"; do
        if [[ -f "$candidate_dir/qemu-system-x86_64.exe" ]] || [[ -f "$candidate_dir/qemu-system-x86_64" ]]; then
            export PATH="$candidate_dir:$PATH"
            break
        fi
    done
fi

# Detect Python 3 interpreter (avoiding 0-byte WindowsApps alias in Git Bash)
PYTHON_BIN=""
for cand in python python3 py; do
    if command -v "$cand" >/dev/null 2>&1; then
        if "$cand" -c "import sys; sys.exit(0 if sys.version_info.major >= 3 else 1)" >/dev/null 2>&1; then
            PYTHON_BIN="$cand"
            break
        fi
    fi
done

# 1. Check Core Binary Tools
echo -e "\n${CYAN}[1/5] Checking Toolchain & Emulator Binaries${NC}"

# Core Build Tools: zig, git, tar, python, timeout
for cmd in zig git tar timeout; do
    if command -v "$cmd" >/dev/null 2>&1; then
        VER=$("$cmd" --version 2>&1 | head -n 1 || true)
        ok "$cmd ($VER)"
    else
        if [[ "$cmd" == "timeout" ]] && command -v gtimeout >/dev/null 2>&1; then
            warn "'timeout' missing (macOS detected), but 'gtimeout' is available. Alias or symlink gtimeout -> timeout"
        else
            fail "Missing required build tool: $cmd"
        fi
    fi
done

if [[ -n "$PYTHON_BIN" ]]; then
    PY_VER=$("$PYTHON_BIN" --version 2>&1 | head -n 1 || true)
    ok "python ($PYTHON_BIN: $PY_VER)"
else
    fail "Missing required Python 3 interpreter (probed: python, python3, py)"
fi

# Test and Emulator Tools: qemu-system-x86_64, cpio
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    VER=$(qemu-system-x86_64 --version 2>&1 | head -n 1 || true)
    ok "qemu-system-x86_64 ($VER)"
else
    warn "Test/emulator tool 'qemu-system-x86_64' not found (optional for build, required for qemu tests)"
fi

if [[ -f "tools/cpio_writer.py" ]] && [[ -n "$PYTHON_BIN" ]]; then
    ok "cpio archive writer (tools/cpio_writer.py: Python newc archive writer)"
elif command -v cpio >/dev/null 2>&1; then
    VER=$(cpio --version 2>&1 | head -n 1 || true)
    ok "cpio ($VER)"
else
    warn "External 'cpio' not found (fallback: tools/cpio_writer.py required)"
fi

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
        warn "Zig $ZIG_VER uses lowercase calling conventions ('callconv(.c)' / 'callconv(.naked)'). See Section 2.1"
    fi
    rm -f "$TMP_ZIG"
fi

# 3. Verify QEMU isa-debug-exit & virtio Devices
echo -e "\n${CYAN}[3/5] Verifying QEMU x86_64 Device Support${NC}"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    DEV_HELP=$(qemu-system-x86_64 -device help 2>&1 || true)
    for dev in "isa-debug-exit" "virtio-blk-pci" "virtio-net-pci"; do
        if echo "$DEV_HELP" | grep -q "$dev"; then
            ok "QEMU device supported: $dev"
        else
            warn "QEMU missing device support: $dev"
        fi
    done
else
    warn "qemu-system-x86_64 not found; skipping device probe"
fi

# 4. Verify Script Permissions & ABI Inspector Probe
echo -e "\n${CYAN}[4/5] Verifying Helper Scripts & Linux ABI Probe${NC}"
chmod +x init_project.sh scripts/*.sh scripts/*.py tools/*.py 2>/dev/null || true
ok "Set executable permissions (+x) on scripts/ and tools/"
if [[ -f "./tools/tinux_abi_mcp.py" ]] && [[ -n "$PYTHON_BIN" ]]; then
    if "$PYTHON_BIN" ./tools/tinux_abi_mcp.py syscall write >/dev/null 2>&1; then
        ok "tools/tinux_abi_mcp.py Linux x86_64 header probe working ($PYTHON_BIN)"
    else
        warn "tools/tinux_abi_mcp.py probe returned non-zero (check python / zig env)"
    fi
else
    warn "tools/tinux_abi_mcp.py not yet placed or python missing"
fi
# 5. Verify Specification Files (TASK-001 .. TASK-020)
echo -e "\n${CYAN}[5/5] Checking Specification Files (docs/specs/SPEC_TASK_001..020.md)${NC}"
if [[ -x "./scripts/check_specs.sh" ]]; then
    if ./scripts/check_specs.sh; then
        ok "All 20 specifications verified ready"
    else
        warn "Specification checks pending: see detailed status above"
    fi
else
    warn "scripts/check_specs.sh not found"
fi
echo -e "\n${BOLD}======================================================================${NC}"
echo -e "  Pre-Flight Summary: ${GREEN}${PASS} Passed${NC}, ${YELLOW}${WARN} Warnings${NC}, ${RED}${FAIL} Failed${NC}"
echo -e "${BOLD}======================================================================${NC}"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
