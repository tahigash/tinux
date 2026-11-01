# Tinux Kernel Crash Triage Guide (`scripts/triage_crash.py`)

> **Purpose:**
> Analyzes QEMU crash dumps and register state from serial execution logs, diagnosing CPU exceptions (#GP, #PF, #UD), stack alignment, and faulting instructions.

---

## 1. Triage Architecture

When a test run or kernel execution crashes, the triage analyzer extracts:
* CPU exception vector and hardware error code
* Faulting virtual address in CR2 and RIP, classified against the Tinux virtual memory layout
* Stack alignment in RSP to check 16-byte alignment requirements for SSE instructions
* Function symbol and source file location using symbol tables
* Disassembled machine instructions surrounding the crash site
* Last 25 lines of serial log output

---

## 2. Crash Triage Script (`scripts/triage_crash.py`)

```python
#!/usr/bin/env python3
"""
Tinux Automated Crash Triage and Exception Analyzer
"""
import argparse
import glob
import os
import pathlib
import re
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

X86_EXCEPTIONS = {
    0: ("#DE", "Divide-by-zero Error"),
    1: ("#DB", "Debug Exception"),
    2: ("#NMI", "Non-Maskable Interrupt"),
    3: ("#BP", "Breakpoint"),
    4: ("#OF", "Overflow"),
    5: ("#BR", "BOUND Range Exceeded"),
    6: ("#UD", "Invalid Opcode"),
    7: ("#NM", "Device Not Available (No Math Coprocessor)"),
    8: ("#DF", "Double Fault"),
    10: ("#TS", "Invalid TSS"),
    11: ("#NP", "Segment Not Present"),
    12: ("#SS", "Stack-Segment Fault"),
    13: ("#GP", "General Protection Fault"),
    14: ("#PF", "Page Fault"),
    16: ("#MF", "x87 FPU Floating-Point Error"),
    17: ("#AC", "Alignment Check"),
    18: ("#MC", "Machine Check"),
    19: ("#XM", "SIMD Floating-Point Exception"),
}

def classify_address(addr: int) -> str:
    if addr == 0:
        return "Null Pointer Dereference (0x0)"
    if addr < 0x0040_0000:
        return "Low Virtual Memory (0x0 .. 0x3FFFFF)"
    if 0x0040_0000 <= addr < 0x0080_0000:
        return "User ELF Text / Data (0x400000 .. 0x7FFFFF)"
    if 0x7000_0000_0000 <= addr < 0x7FFF_0000_0000:
        return "User Dynamic mmap / Heap Region"
    if 0x7FFF_0000_0000 <= addr <= 0x7FFF_FFFF_FFFF:
        return "User Stack Space"
    if 0x0000_8000_0000_0000 <= addr < 0xFFFF_8000_0000_0000:
        return "Non-Canonical Address Hole (General Protection Fault)"
    if 0xFFFF_8000_0000_0000 <= addr < 0xFFFF_8880_0000_0000:
        return "Kernel Lower Half Space"
    if 0xFFFF_8880_0000_0000 <= addr < 0xFFFF_C000_0000_0000:
        return "Physical Direct Map (HHDM)"
    if 0xFFFF_FFFF_8000_0000 <= addr:
        return "Kernel Text / BSS / High Virtual Space"
    return "Unknown Memory Region"

def decode_page_fault_error(err: int, cr2: Optional[int], rip: Optional[int]) -> List[str]:
    reasons = []
    p = bool(err & (1 << 0))
    wr = bool(err & (1 << 1))
    us = bool(err & (1 << 2))
    rsvd = bool(err & (1 << 3))
    id_flag = bool(err & (1 << 4))
    if not p:
        reasons.append("P=0: Non-present page (page translation entry not present in page table).")
    else:
        reasons.append("P=1: Page-protection violation (access rights violated).")
    if wr:
        reasons.append("W/R=1: Write operation caused the fault.")
    else:
        reasons.append("W/R=0: Read operation caused the fault.")
    if us:
        reasons.append("U/S=1: Fault occurred while running in User Mode (CPL=3).")
    else:
        reasons.append("U/S=0: Fault occurred while running in Supervisor Mode (CPL=0).")
    if rsvd:
        reasons.append("RSVD=1: Reserved bits set in page table entry.")
    if id_flag:
        reasons.append("I/D=1: Instruction fetch caused the fault (NX violation).")
    return reasons

def resolve_address(elf_path: str, addr: int) -> Tuple[str, Optional[str], Optional[int]]:
    if not os.path.isfile(elf_path):
        return (f"0x{addr:X}", None, None)
    try:
        res = subprocess.run(["addr2line", "-e", elf_path, "-f", "-C", f"0x{addr:X}"],
                             capture_output=True, text=True, timeout=3)
        lines = res.stdout.strip().splitlines()
        if len(lines) >= 2:
            func = lines[0]
            loc = lines[1]
            if ":" in loc:
                file_part, line_part = loc.rsplit(":", 1)
                try:
                    return (func, file_part, int(line_part))
                except ValueError:
                    return (func, file_part, None)
            return (func, loc, None)
    except Exception:
        pass
    return (f"0x{addr:X}", None, None)

def extract_source_snippet(src_file: str, line_no: int, context: int = 4) -> Optional[str]:
    if not os.path.isfile(src_file):
        return None
    try:
        with open(src_file, "r", encoding="utf-8", errors="replace") as f:
            all_lines = f.readlines()
        start = max(0, line_no - context - 1)
        end = min(len(all_lines), line_no + context)
        out = []
        for i in range(start, end):
            marker = ">>" if (i + 1 == line_no) else "  "
            out.append(f"{marker} {i+1:4d} | {all_lines[i].rstrip()}")
        return "\n".join(out)
    except Exception:
        return None

def disassemble_around(elf_path: str, addr: int) -> Optional[str]:
    if not os.path.isfile(elf_path):
        return None
    try:
        start_addr = max(0, addr - 32)
        stop_addr = addr + 32
        res = subprocess.run(
            ["objdump", "-d", f"--start-address=0x{start_addr:X}", f"--stop-address=0x{stop_addr:X}", elf_path],
            capture_output=True, text=True, timeout=3
        )
        return res.stdout.strip()
    except Exception:
        return None

def parse_qemu_log(log_path: str) -> Dict[str, Optional[str]]:
    parsed: Dict[str, Optional[str]] = {
        "panic_msg": None, "vector": None, "error_code": None,
        "rip": None, "rsp": None, "cr2": None,
    }
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    m_panic = re.search(r"KERNEL PANIC:\s*(.+)", text)
    if m_panic:
        parsed["panic_msg"] = m_panic.group(1).strip()
    m_vec = re.search(r"Vector:\s*(\d+)", text, re.IGNORECASE)
    if m_vec:
        parsed["vector"] = m_vec.group(1)
    m_err = re.search(r"Error Code:\s*(0x[0-9a-fA-F]+|\d+)", text, re.IGNORECASE)
    if m_err:
        val = m_err.group(1)
        parsed["error_code"] = str(int(val, 16) if val.startswith("0x") else int(val))
    m_rip = re.search(r"RIP:\s*(0x[0-9a-fA-F]+)", text, re.IGNORECASE)
    if m_rip:
        parsed["rip"] = str(int(m_rip.group(1), 16))
    m_rsp = re.search(r"RSP:\s*(0x[0-9a-fA-F]+)", text, re.IGNORECASE)
    if m_rsp:
        parsed["rsp"] = str(int(m_rsp.group(1), 16))
    m_cr2 = re.search(r"CR2:\s*(0x[0-9a-fA-F]+)", text, re.IGNORECASE)
    if m_cr2:
        parsed["cr2"] = str(int(m_cr2.group(1), 16))
    return parsed

def generate_triage_report(log_path: str, kernel_elf: str) -> str:
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        log_text = f.read()
    parsed = parse_qemu_log(log_path)
    lines = [
        "# Tinux Automated Crash Triage Report",
        "",
        f"* **Log File:** `{log_path}`",
        f"* **Kernel ELF:** `{kernel_elf}`",
    ]
    if parsed["panic_msg"]:
        lines.append(f"* **Kernel Panic Message:** `{parsed['panic_msg']}`")
    vec = parsed["vector"]
    err = parsed["error_code"]
    rip = parsed["rip"]
    rsp = parsed["rsp"]
    cr2 = parsed["cr2"]
    if vec is not None:
        mnemonic, desc = X86_EXCEPTIONS.get(int(vec), ("#??", "Unknown CPU Exception"))
        lines.append(f"* **CPU Exception Vector:** `{vec}` (`{mnemonic}`: {desc})")
    if err is not None:
        lines.append(f"* **Hardware Error Code:** `0x{int(err):016X}`")
    lines.append("")
    lines.append("## 1. Register and Memory Map Classification")
    lines.append("")
    lines.append("| Register | Hex Value | Tinux Virtual Memory Region |")
    lines.append("| :--- | :--- | :--- |")
    if rip is not None:
        lines.append(f"| **`RIP`** | `0x{int(rip):016X}` | {classify_address(int(rip))} |")
    if cr2 is not None:
        lines.append(f"| **`CR2`** | `0x{int(cr2):016X}` | {classify_address(int(cr2))} |")
    if rsp is not None:
        align_note = "16B-aligned" if (int(rsp) % 16 == 0) else "UNALIGNED (Check SSE)"
        lines.append(f"| **`RSP`** | `0x{int(rsp):016X}` | {classify_address(int(rsp))} ({align_note}) |")
    if vec == 14 and err is not None:
        lines.append("")
        lines.append("## 2. Page Fault (`#PF`) Bit-Level Diagnosis")
        lines.append("")
        for reason in decode_page_fault_error(int(err), cr2, rip):
            lines.append(f"* {reason}")
    elif vec == 13:
        lines.append("")
        lines.append("## 2. General Protection Fault (`#GP`) Diagnosis Hints")
        lines.append("")
        lines.append("* Check if an SSE instruction (`movaps`) executed with an unaligned `RSP` (not a multiple of 16).")
        lines.append("* Check if `SYSRET` or `IRETQ` attempted to load a non-canonical `RIP`/`RSP` or invalid GDT selector.")
    if rip is not None:
        rip_int = int(rip)
        target_elf = kernel_elf
        lookup_addr = rip_int
        # If RIP is in user space, check clean-room user ELF binaries if available
        if 0x0040_0000 <= rip_int < 0x0080_0000:
            for cand in [".cache/initramfs_root/bin/tinux_sh", ".cache/initramfs_root/bin/hello_c", "src/proc/init_test.elf"]:
                if os.path.isfile(cand):
                    target_elf = cand
                    break
        func_name, src_file, src_line = resolve_address(target_elf, lookup_addr)
        lines.append("")
        lines.append("## 3. Symbol and Source Code Resolution")
        lines.append("")
        lines.append(f"* **Resolved Symbol:** `{func_name}`")
        if src_file and src_line:
            lines.append(f"* **Source Location:** `{src_file}:{src_line}`")
            snippet = extract_source_snippet(src_file, src_line)
            if snippet:
                lines.append("")
                lines.append("```zig")
                lines.append(snippet)
                lines.append("```")
        disasm = disassemble_around(target_elf, lookup_addr)
        if disasm:
            lines.append("")
            lines.append("## 4. Instruction Disassembly Around `RIP`")
            lines.append("")
            lines.append("```asm")
            lines.append(disasm)
            lines.append("```")
    tail_lines = log_text.strip().splitlines()[-25:]
    lines.append("")
    lines.append("## 5. Serial Log Tail (Last 25 Lines)")
    lines.append("")
    lines.append("```text")
    lines.extend(tail_lines)
    lines.append("```")
    return "\n".join(lines) + "\n"

def find_latest_qemu_log() -> Optional[str]:
    candidates = glob.glob("/tmp/tinux_qemu_*.log")
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)

def main() -> None:
    parser = argparse.ArgumentParser(description="Tinux QEMU Crash & Exception Triage Tool")
    parser.add_argument("--log", help="Path to QEMU serial log (default: latest /tmp/tinux_qemu_*.log)")
    parser.add_argument("--elf", default="zig-out/bin/tinux", help="Path to kernel ELF binary")
    parser.add_argument("--out", help="Optional path to write Markdown report (e.g. ESCALATION_REPORT.md)")
    args = parser.parse_args()
    log_path = args.log or find_latest_qemu_log()
    if not log_path or not os.path.isfile(log_path):
        sys.stderr.write("Error: No QEMU serial log found. Specify --log /tmp/tinux_qemu_TASK-0XX.log\n")
        sys.exit(1)
    report = generate_triage_report(log_path, args.elf)
    print(report)
    if args.out:
        pathlib.Path(args.out).write_text(report)
        print(f"[TRIAGE] Saved triage report to {args.out}")

if __name__ == "__main__":
    main()
```

---

## 3. Usage and Integration with `verify_qemu.sh`

### 1. Inspect Latest QEMU Crash Log
```bash
chmod +x scripts/triage_crash.py
./scripts/triage_crash.py
```

### 2. Export Diagnostic Report Directly to `ESCALATION_REPORT.md`
```bash
./scripts/triage_crash.py --log /tmp/tinux_qemu_TASK-004.log --out ESCALATION_REPORT.md
```

### 3. Automated Hook Integration with `scripts/verify_qemu.sh`
Add this hook to `scripts/verify_qemu.sh` inside the failure check to diagnose crashes automatically:
```bash
if [ "$QEMU_EXIT" -ne 33 ]; then
    echo "[HARNESS] FAIL: Unexpected QEMU exit code $QEMU_EXIT (expected 33)."
    if [ -x "./scripts/triage_crash.py" ]; then
        ./scripts/triage_crash.py --log "$LOG_FILE" --elf "$KERNEL_BIN"
    fi
    exit 1
fi
```
