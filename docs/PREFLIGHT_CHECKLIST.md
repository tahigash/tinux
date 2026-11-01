# Tinux Pre-Flight Final Checklist & Zig Version Compatibility Guide
> **Purpose:**
> Eliminates environment-level build failures before launching the autonomous **Gemini 3.8 Flash High** Builder loop
---
## 1. Automated Pre-Flight Check Script (`scripts/preflight_check.sh`)
Before starting the autonomous loop, save `scripts/preflight_check.sh` and run `chmod +x scripts/preflight_check.sh && ./scripts/preflight_check.sh`. Confirm all checks pass before advancing:
```bash
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
            warn "'timeout' missing (macOS detected), but 'gtimeout' is available. Alias or symlink gtimeout -> timeout"
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
            fail "QEMU missing device support: $dev"
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
echo -e "  Pre-Flight Summary: ${GREEN}${PASS} Passed${NC}, ${YELLOW}${WARN} Warnings${NC}, ${RED}${FAIL} Failed${NC}"
echo -e "${BOLD}======================================================================${NC}"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
```
---
## 2. Zig Compiler Version Compatibility Matrix (`0.13` / `0.14` / `0.15+`)
Zig built-ins and standard library APIs change between minor releases. The reference patterns below prevent compilation issues across versions:
### 2.1 Calling Convention (`callconv`) Casing Differences
* **Symptom:** Zig `0.13` through early `0.14` used uppercase convention tags (`callconv(.C)`, `callconv(.Naked)`), whereas newer releases use lowercase (`callconv(.c)`, `callconv(.naked)`).
* **Resolution:**
If compilation fails with `error: enum 'std.builtin.CallingConvention' has no member named 'C'`, apply the following:
1. Use `callconv(.c)` and `callconv(.naked)` (functions marked with `export fn` default to C calling convention, making explicit `.c` optional).
2. In user-space test entry points (`_start`), use `export fn _start() callconv(.naked) noreturn`.
### 2.2 Assembly Files and Linker Scripts in `build.zig`
* **Symptom:** In Zig build APIs, `exe.addAssemblyFile(...)` is called either directly on `exe` or via `exe.root_module` depending on compiler build.
* **Resolution:**
  ```zig
  // Linker script setting
  exe.setLinkerScript(b.path("linker.ld"));
  // Assembly file registration (works across 0.13 / 0.14 / 0.15+)
  if (@hasDecl(@TypeOf(exe.*), "addAssemblyFile")) {
      exe.addAssemblyFile(b.path("src/arch/x86_64/boot.S"));
  } else {
      exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/boot.S"));
  }
  ```
### 2.3 `std.mem.Allocator` VTable Signature Evolution
* **Symptom:** In Zig `0.13` and `0.14`, `std.mem.Allocator.VTable` requires `alloc`, `resize`, and `free`. Newer development builds may also declare `remap`.
* **Resolution:**
If `TASK-003` encounters VTable signature mismatches in `src/mm/heap.zig`, structure the wrapper using conditional compilation:
  ```zig
  const AlignmentArg = @typeInfo(@TypeOf(@as(std.mem.Allocator.VTable, undefined).alloc)).@"fn".params[2].type.?;
  fn alignToBytes(a: AlignmentArg) usize {
      if (AlignmentArg == u8) {
          return @as(usize, 1) << @intCast(a);
      } else {
          return a.toByteUnits();
      }
  }
  ```
If `std.mem.Allocator.VTable` includes a `remap` field, provide `.remap = heapRemap` conditionally.
### 2.4 Standalone Linux ELF Compiler Flags
* **Symptom:** Running `zig build-exe` on tests may default to PIE or dynamic linking depending on toolchain options, resulting in user-space page faults.
* **Resolution:**
When compiling user-space test ELFs in `verify_qemu.sh`, use the following flag combination (fixed-address static executable, zero libc, no stack protector):
  ```bash
  zig build-exe src/user/init_test.zig \
      -target x86_64-linux-none \
      -O ReleaseSmall \
      -fno-pie \
      -fno-strip \
      -femit-bin=src/proc/init_test.elf
  ```
---
## 3. Host OS Nuances (Linux Server vs. macOS Apple Silicon)
Cross-platform considerations across Linux and macOS development environments:
1. **Timeout command:**
* Linux includes GNU `timeout`. On macOS, install `coreutils` (`brew install coreutils`) or rely on the fallback mechanism in `verify_qemu.sh`.
2. **Archive formats:**
* `initramfs.cpio` creation requires `cpio -o -H newc` (SVR4 format, magic "070701"), supported by both GNU and BSD `cpio`.
* For `TASK-016`, `scripts/verify_qemu.sh` automatically supports both GNU `--format=ustar` and BSD `--format ustar`.
3. **QEMU acceleration:**
* Using explicit software emulation (`-accel tcg`) ensures deterministic behavior during GDT/IDT reload, CR3 page table switches, and SMP AP startup.
---
## 4. Final Launch Sequence (Ready for Liftoff)
When ready, launch autonomous execution with these three steps:
```bash
# Step 1: Run pre-flight check
chmod +x scripts/preflight_check.sh
./scripts/preflight_check.sh
# Step 2: Verify clean baseline commit
git status
# Step 3: Select Gemini 3.8 Flash High in Google Antigravity,
#         and submit the Section 2 prompt from ANTIGRAVITY_MASTER_PROMPT.md
```
