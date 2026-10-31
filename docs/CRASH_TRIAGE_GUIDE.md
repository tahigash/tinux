# Tinux Automated Crash Triage Report",
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
        lines.append(f"* **CPU Exception Vector:** `{vec}` (`{mnemonic}` — {desc})")
    if err is not None:
        lines.append(f"* **Hardware Error Code:** `0x{int(err):016X}`")
    lines.append("")
    lines.append("## 1. Register & Memory Map Classification")
    lines.append("")
    lines.append("| Register | Hex Value | Tinux Virtual Memory Region |")
    lines.append("| :--- | :--- | :--- |")
    if rip is not None:
        lines.append(f"| **`RIP`** | `0x{int(rip):016X}` | {classify_address(int(rip))} |")
    if cr2 is not None:
        lines.append(f"| **`CR2`** | `0x{int(cr2):016X}` | {classify_address(int(cr2))} |")
    if rsp is not None:
        align_note = "16B-aligned" if (int(rsp) % 16 == 0) else "UNALIGNED (Check SSE!)"
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
        lines.append("* Check if an SSE instruction (`movaps`) executed with an unaligned `RSP` (not a multiple of 1
        lines.append("* Check if `SYSRET` or `IRETQ` attempted to load a non-canonical `RIP`/`RSP` or invalid GDT se


125 ---
    if rip is not None:
        rip_int = int(rip)
        target_elf = kernel_elf
        lookup_addr = rip_int
        # If RIP is in user space, check user ELF binaries if available
        if 0x0040_0000 <= rip_int < 0x0080_0000:
            for cand in [".cache/initramfs_root/bin/busybox", "src/proc/init_test.elf"]:
                if os.path.isfile(cand):
                    target_elf = cand
                    break
        func_name, src_file, src_line = resolve_address(target_elf, lookup_addr)
        lines.append("")
        lines.append("## 3. Symbol & Source Code Resolution")
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


126 ---
## 3. Usage & Integration with `verify_qemu.sh`
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
Add this hook to scripts/verify_qemu.sh inside the failure check to diagnose crashes automatically:
```bash
if [ "$QEMU_EXIT" -ne 33 ]; then
    echo "[HARNESS] FAIL: Unexpected QEMU exit code $QEMU_EXIT (expected 33)."
    if [ -x "./scripts/triage_crash.py" ]; then
        ./scripts/triage_crash.py --log "$LOG_FILE" --elf "$KERNEL_BIN"
    fi
    exit 1
fi
```
