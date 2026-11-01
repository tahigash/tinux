#!/usr/bin/env python3
"""
Tinux Automated Crash Triage & Log Analyzer
"""
import sys
import argparse
import os

def main():
    parser = argparse.ArgumentParser(description="Tinux Crash Triage Analyzer")
    parser.add_argument("--log", help="Path to QEMU serial log file", default="/tmp/tinux_qemu.log")
    parser.add_argument("--elf", help="Path to kernel ELF binary", default="zig-out/bin/tinux")
    parser.add_argument("--out", help="Path to write escalation report", default="ESCALATION_REPORT.md")
    args = parser.parse_args()

    print(f"[TRIAGE] Analyzing log file: {args.log}")
    if os.path.exists(args.log):
        with open(args.log, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        print(f"[TRIAGE] Total log lines: {len(lines)}")
        tail = "".join(lines[-30:]) if len(lines) > 30 else "".join(lines)
        print("[TRIAGE] Tail log output:\n" + tail)
    else:
        print(f"[TRIAGE] Log file {args.log} not found.")

if __name__ == "__main__":
    main()
