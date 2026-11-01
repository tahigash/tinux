#!/usr/bin/env python3
"""
Tinux Clean-Room License & Binary Guardrail Auditor

Ensures the repository contains zero compiled binary artifacts, zero GPL-contaminated
userland binaries (e.g. prebuilt BusyBox or coreutils), and enforces license metadata
integrity (MIT / Apache-2.0 hybrid license and Linux trademark disclaimer).

Usage:
    python scripts/check_license_guardrails.py          # Scan tracked and working tree files
    python scripts/check_license_guardrails.py --staged # Scan only git staged files (pre-commit)
"""

import os
import sys
import subprocess

FORBIDDEN_EXTENSIONS = {
    ".cpio", ".elf", ".bin", ".img", ".iso",
    ".so", ".dylib", ".a", ".o", ".exe",
    ".tar", ".gz", ".tgz", ".qcow2"
}

FORBIDDEN_NAMES = {
    "busybox", "coreutils", "initramfs.cpio"
}

MAGIC_SIGNATURES = [
    (b"\x7fELF", "ELF binary executable/object"),
    (b"070701", "SVR4 CPIO archive (magic 070701)"),
    (b"070702", "SVR4 CRC CPIO archive (magic 070702)"),
    (b"MZ", "DOS/PE executable"),
    (b"\xfe\xed\xfa\xce", "Mach-O 32-bit"),
    (b"\xfe\xed\xfa\xcf", "Mach-O 64-bit"),
    (b"\xcf\xfa\xed\xfe", "Mach-O 64-bit (reverse)"),
    (b"\xce\xfa\xed\xfe", "Mach-O 32-bit (reverse)"),
    (b"PK\x03\x04", "ZIP / Jar archive"),
    (b"\x1f\x8b", "GZIP compressed archive"),
]

def check_file_for_violations(file_path):
    violations = []
    basename = os.path.basename(file_path).lower()
    ext = os.path.splitext(basename)[1].lower()

    # 1. Check forbidden filenames
    if basename in FORBIDDEN_NAMES or any(basename.startswith(n) for n in ["busybox"]):
        violations.append(f"Forbidden third-party GPL/binary name: '{basename}'")

    # 2. Check forbidden extensions
    if ext in FORBIDDEN_EXTENSIONS:
        violations.append(f"Forbidden binary file extension '{ext}'")

    # 3. Inspect header magic bytes
    if os.path.isfile(file_path) and os.path.getsize(file_path) > 0:
        try:
            with open(file_path, "rb") as fp:
                header = fp.read(16)
            for magic, desc in MAGIC_SIGNATURES:
                if header.startswith(magic):
                    violations.append(f"Contains forbidden binary header signature: {desc}")
                    break
            # Also check ustar signature at offset 257 for tar archives
            if os.path.getsize(file_path) >= 512:
                with open(file_path, "rb") as fp:
                    fp.seek(257)
                    tar_magic = fp.read(5)
                    if tar_magic == b"ustar":
                        violations.append("Contains POSIX USTAR tar archive header")
        except Exception as e:
            violations.append(f"Failed to read file for header inspection: {e}")

    return violations

def check_license_integrity(repo_root):
    issues = []
    # Check required license files
    for req in ["LICENSE", "LICENSE-MIT", "LICENSE-APACHE"]:
        p = os.path.join(repo_root, req)
        if not os.path.isfile(p):
            issues.append(f"Missing required license file: '{req}'")

    # Check trademark disclaimer in README.md
    readme_path = os.path.join(repo_root, "README.md")
    if os.path.isfile(readme_path):
        with open(readme_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        disclaimer_snippet = "Disclaimer: Tinux is an independent, clean-room implementation compatible with the Linux ABI"
        if disclaimer_snippet not in content:
            issues.append("README.md missing standard Linux trademark disclaimer")
    else:
        issues.append("Missing README.md")

    return issues

def get_staged_files(repo_root):
    cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"]
    res = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
    if res.returncode != 0:
        return []
    return [os.path.join(repo_root, line.strip()) for line in res.stdout.splitlines() if line.strip()]

def get_workspace_files(repo_root):
    ignored_dirs = {".git", ".zig-cache", "zig-cache", "zig-out", ".cache", "zig-pkg"}
    all_files = []
    for root, dirs, files in os.walk(repo_root):
        dirs[:] = [d for d in dirs if d not in ignored_dirs]
        for f in files:
            all_files.append(os.path.join(root, f))
    return all_files

def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    is_staged_only = "--staged" in sys.argv

    print("=" * 75)
    print("  Tinux Clean-Room License & Binary Guardrail Auditor")
    print("=" * 75)

    files_to_check = get_staged_files(repo_root) if is_staged_only else get_workspace_files(repo_root)
    mode_label = "Git Staged Changes" if is_staged_only else "Full Workspace"
    print(f"  Target Scope: {mode_label} ({len(files_to_check)} files)\n")

    violation_count = 0
    for file_path in files_to_check:
        # Skip git internal files or guardrail script itself
        rel_path = os.path.relpath(file_path, repo_root)
        if rel_path.startswith(".git") or rel_path.endswith(".pyc"):
            continue

        violations = check_file_for_violations(file_path)
        if violations:
            violation_count += 1
            print(f"  [VIOLATION] {rel_path}:")
            for v in violations:
                print(f"    - {v}")

    license_issues = check_license_integrity(repo_root)
    if license_issues:
        print("\n  [LICENSE ISSUES]:")
        for issue in license_issues:
            print(f"    - {issue}")
        violation_count += len(license_issues)

    print("-" * 75)
    if violation_count == 0:
        print("  [PASS] All clean-room licensing and binary guardrails satisfied.")
        print("         Zero prohibited binaries detected; license metadata intact.")
        print("=" * 75)
        sys.exit(0)
    else:
        print(f"  [FAIL] Detected {violation_count} license or binary contamination issue(s).")
        print("         Commit or build blocked to preserve clean-room licensing boundaries.")
        print("=" * 75)
        sys.exit(1)

if __name__ == "__main__":
    main()
