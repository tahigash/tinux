#!/usr/bin/env python3
"""
Tinux 7-Bit Clean ASCII Integrity Checker

Verifies that all source code, specifications, scripts, and documentation
contain strictly 7-bit ASCII characters (ord <= 127).
"""

import os
import sys

EXTENSIONS = {".zig", ".md", ".sh", ".py", ".S", ".ld", ".json"}
IGNORED_DIRS = {".git", ".agents", ".antigravity", ".cache", ".zig-cache", "zig-out"}

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    errors = []

    for root, dirs, files in os.walk(repo_root):
        # Exclude ignored directories in-place
        dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]

        for f in files:
            ext = os.path.splitext(f)[1]
            if ext in EXTENSIONS:
                path = os.path.join(root, f)
                rel_path = os.path.relpath(path, repo_root)
                try:
                    with open(path, "rb") as fp:
                        data = fp.read()
                    for idx, byte in enumerate(data):
                        if byte > 127:
                            errors.append(f"{rel_path}: byte offset {idx} has non-ASCII byte 0x{byte:02x}")
                            break
                except Exception as ex:
                    errors.append(f"{rel_path}: error reading file: {ex}")

    if errors:
        print(f"[FAIL] Found {len(errors)} files with non-ASCII characters:")
        for err in errors[:25]:
            print(f"  - {err}")
        if len(errors) > 25:
            print(f"  ... and {len(errors) - 25} more")
        sys.exit(1)

    print("[PASS] All repository source, scripts, and documentation are 100% 7-bit ASCII compliant.")
    sys.exit(0)

if __name__ == "__main__":
    main()
