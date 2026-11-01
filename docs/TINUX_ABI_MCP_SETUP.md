# Tinux Linux ABI & UAPI Inspector (FastMCP Server + Standalone CLI)
> **Purpose:**
> Provides zero-hallucination Linux `x86_64` ABI ground truth (syscall numbers, `errno` codes, C macro values, exact struct field offsets, and comptime assertions).
---
## 1. Architecture and Setup
1. **Dual-Mode Execution (FastMCP + CLI):**
   * **MCP Mode (`--mcp`):** Runs as a standard Model Context Protocol server over `stdio` using `FastMCP`, exposing tools to AI developer environments.
   * **CLI Mode:** Runs directly from bash with zero third-party Python dependencies required, allowing tools and scripts to query ABI facts directly.
2. **Cross-Platform `zig cc -target x86_64-linux-gnu` Probe Engine:**
   * Instead of relying on host architecture headers (which differ on macOS/ARM64), this tool invokes `zig cc -target x86_64-linux-gnu` with small probe snippets to obtain exact target definitions.
---
## 2. Implementation (`tools/tinux_abi_mcp.py`)
Save the following code as `tools/tinux_abi_mcp.py` and make it executable (`chmod +x tools/tinux_abi_mcp.py`):
```python
#!/usr/bin/env python3
"""
Tinux Linux x86_64 ABI & UAPI Inspector (FastMCP Server & CLI)
Provides exact syscall numbers, macro constants, struct sizes/offsets,
and UAPI header searches using Zig's bundled x86_64-linux toolchain.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional
TARGET_TRIPLE = "x86_64-linux-gnu"
def get_zig_libc_include_dirs() -> List[pathlib.Path]:
    """Locates Zig's bundled Linux UAPI and libc header directories."""
    dirs: List[pathlib.Path] = []
    try:
        res = subprocess.run(
            ["zig", "env"], capture_output=True, text=True, check=True, timeout=5
        )
        # zig env may output JSON or ZON; extract lib_dir with regex
        match = re.search(r'"?lib_dir"?\s*[=:]\s*"([^"]+)"', res.stdout)
        if match:
            lib_dir = pathlib.Path(match.group(1))
            candidates = [
                lib_dir / "libc" / "include" / "x86_64-linux-gnu",
                lib_dir / "libc" / "include" / "any-linux-any",
                lib_dir / "libc" / "include" / "x86_64-linux-musl",
                lib_dir / "libc" / "musl" / "include",
            ]
            for c in candidates:
                if c.is_dir():
                    dirs.append(c)
    except Exception:
        pass
    for sys_inc in ["/usr/include/x86_64-linux-gnu", "/usr/include"]:
        p = pathlib.Path(sys_inc)
        if p.is_dir():
            dirs.append(p)
    return dirs
def run_zig_c_probe(headers: List[str], probes: Dict[str, str]) -> Dict[str, Optional[int]]:
    """
    Compiles a C probe with `zig cc -target x86_64-linux-gnu -S -O1`
    and extracts compile-time integer constants from the generated x86_64 assembly.
    Works on any host OS (Linux, macOS Apple Silicon, Windows) without executing ELF binaries.
    """
    lines = ["#define _GNU_SOURCE", "#include <stddef.h>", "#include <stdint.h>"]
    for h in headers:
        h_clean = h.strip().strip("<>\"'")
        lines.append(f"#include <{h_clean}>")
    probe_keys = list(probes.keys())
    for idx, key in enumerate(probe_keys):
        expr = probes[key]
        lines.append(f"long __tinux_probe_{idx}(void) {{ return (long)({expr}); }}")
    c_source = "\n".join(lines) + "\n"
    with tempfile.NamedTemporaryFile(mode="w", suffix=".c", delete=False) as tmp:
        tmp.write(c_source)
        tmp_path = tmp.name
    try:
        cmd = [
            "zig",
            "cc",
            "-target",
            TARGET_TRIPLE,
            "-S",
            "-O1",
            "-fno-asynchronous-unwind-tables",
            "-o",
            "-",
            tmp_path,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if proc.returncode != 0:
            raise RuntimeError(f"zig cc probe failed:\n{proc.stderr.strip()}")
        asm_text = proc.stdout
        results: Dict[str, Optional[int]] = {}
        for idx, key in enumerate(probe_keys):
            fn_pattern = rf"__tinux_probe_{idx}:\s*(.*?)\n\s*retq"
            m = re.search(fn_pattern, asm_text, re.DOTALL)
            if not m:
                results[key] = None
                continue
            body = m.group(1)
            if re.search(r"xor[lq]\s+%[er]ax,\s*%[er]ax", body):
                results[key] = 0
            else:
                imm_match = re.search(r"mov[lq]\s+\$(-?\d+),\s*%[er]ax", body)
                if imm_match:
                    results[key] = int(imm_match.group(1))
                else:
                    results[key] = None
        return results
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
# ==============================================================================
# Core Tool Implementations
# ==============================================================================
def lookup_syscall_impl(query: str) -> str:
    """
    Looks up Linux x86_64 syscall numbers by name or number from unistd_64.h.
    """
    inc_dirs = get_zig_libc_include_dirs()
    syscall_map: Dict[str, int] = {}
    for d in inc_dirs:
        for rel in ["asm/unistd_64.h", "bits/syscall.h"]:
            hdr = d / rel
            if hdr.is_file():
                content = hdr.read_text(errors="ignore")
                for m in re.finditer(r"#define\s+__NR_([a-zA-Z0-9_]+)\s+(\d+)", content):
                    syscall_map[m.group(1)] = int(m.group(2))
                if syscall_map:
                    break
        if syscall_map:
            break
    q = query.strip().lower()
    if q.startswith("sys_"):
        q = q[4:]
    matches = []
    if q.isdigit():
        target_num = int(q)
        for name, num in sorted(syscall_map.items(), key=lambda x: x[1]):
            if num == target_num:
                matches.append({"name": f"sys_{name}", "number": num, "macro": f"__NR_{name}"})
    else:
        for name, num in sorted(syscall_map.items(), key=lambda x: x[1]):
            if q in name.lower():
                matches.append({"name": f"sys_{name}", "number": num, "macro": f"__NR_{name}"})
    output = {
        "architecture": "x86_64-linux",
        "register_abi": {
            "syscall_num": "rax",
            "arg1": "rdi",
            "arg2": "rsi",
            "arg3": "rdx",
            "arg4": "r10",
            "arg5": "r8",
            "arg6": "r9",
            "return": "rax (-errno on error)",
            "clobbered_by_hardware": ["rcx (user_rip)", "r11 (user_rflags)"],
        },
        "matches": matches[:25],
    }
    return json.dumps(output, indent=2)
def eval_c_constants_impl(headers: List[str], macros: List[str]) -> str:
    """
    Evaluates exact C macro/constant values on x86_64-linux (hex, octal, decimal).
    """
    probes = {m: m for m in macros}
    raw_vals = run_zig_c_probe(headers, probes)
    formatted = {}
    zig_lines = ["// Auto-generated Zig constants (x86_64-linux ABI)"]
    for m, val in raw_vals.items():
        if val is None:
            formatted[m] = None
        else:
            uval = val if val >= 0 else (1 << 64) + val
            formatted[m] = {
                "decimal": val,
                "hex": f"0x{uval:X}",
                "octal": f"0o{uval:o}",
            }
            zig_lines.append(f"pub const {m}: usize = 0x{uval:X}; // dec: {val}, oct: 0o{uval:o}")
    return json.dumps(
        {
            "headers": headers,
            "constants": formatted,
            "zig_snippet": "\n".join(zig_lines),
        },
        indent=2,
    )
def probe_struct_abi_impl(headers: List[str], struct_type: str, fields: List[str]) -> str:
    """
    Computes exact sizeof(struct_type), _Alignof(struct_type), and offsetof/sizeof
    for each specified field on x86_64-linux, and generates Zig comptime assertions.
    """
    probes: Dict[str, str] = {
        "__sizeof__": f"sizeof({struct_type})",
        "__alignof__": f"_Alignof({struct_type})",
    }
    for f in fields:
        probes[f"offset__{f}"] = f"offsetof({struct_type}, {f})"
        probes[f"size__{f}"] = f"sizeof((({struct_type} *)0)->{f})"
    raw = run_zig_c_probe(headers, probes)
    total_size = raw.get("__sizeof__")
    align_size = raw.get("__alignof__")
    field_info = {}
    assert_lines = [
        "comptime {",
        f"    std.debug.assert(@sizeOf(Self) == {total_size});",
    ]
    for f in fields:
        off = raw.get(f"offset__{f}")
        sz = raw.get(f"size__{f}")
        field_info[f] = {"offset": off, "size": sz}
        assert_lines.append(f'    std.debug.assert(@offsetOf(Self, "{f}") == {off});')
    assert_lines.append("}")
    return json.dumps(
        {
            "struct_type": struct_type,
            "sizeof": total_size,
            "alignof": align_size,
            "fields": field_info,
            "zig_comptime_assertions": "\n".join(assert_lines),
        },
        indent=2,
    )
def search_uapi_headers_impl(pattern: str, max_results: int = 30) -> str:
    """
    Searches Zig's bundled Linux UAPI / libc headers for a regex or identifier.
    """
    inc_dirs = get_zig_libc_include_dirs()
    regex = re.compile(pattern)
    hits = []
    for base_dir in inc_dirs:
        for root, _, files in os.walk(base_dir):
            for fname in files:
                if not fname.endswith(".h"):
                    continue
                fpath = pathlib.Path(root) / fname
                try:
                    lines = fpath.read_text(errors="ignore").splitlines()
                    for lineno, line in enumerate(lines, start=1):
                        if regex.search(line):
                            hits.append(
                                {
                                    "file": str(fpath.relative_to(base_dir)),
                                    "line": lineno,
                                    "code": line.strip(),
                                }
                            )
                            if len(hits) >= max_results:
                                return json.dumps({"pattern": pattern, "hits": hits}, indent=2)
                except Exception:
                    continue
    return json.dumps({"pattern": pattern, "hits": hits}, indent=2)
# ==============================================================================
# FastMCP Server Registration (Mode 1: --mcp)
# ==============================================================================
def run_mcp_server() -> None:
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        try:
            from fastmcp import FastMCP  # type: ignore
        except ImportError:
            sys.stderr.write(
                "Error: 'mcp' or 'fastmcp' package not installed. "
                "Install with: pip install fastmcp\n"
            )
            sys.exit(1)
    mcp = FastMCP("tinux-abi-inspector")
    @mcp.tool()
    def lookup_syscall(query: str) -> str:
        """Look up Linux x86_64 syscall numbers and ABI registers by name (e.g. 'openat') or number ('257')."""
        return lookup_syscall_impl(query)
    @mcp.tool()
    def eval_c_constants(headers: List[str], macros: List[str]) -> str:
        """Evaluate exact Linux x86_64 C macro values (e.g. headers=['fcntl.h'], macros=['O_CREAT', 'O_CLOEXEC'])."""
        return eval_c_constants_impl(headers, macros)
    @mcp.tool()
    def probe_struct_abi(headers: List[str], struct_type: str, fields: List[str]) -> str:
        """Probe exact byte size and field offsets of a Linux C struct (e.g. struct stat, struct epoll_event)."""
        return probe_struct_abi_impl(headers, struct_type, fields)

    @mcp.tool()
    def search_uapi_headers(pattern: str, max_results: int = 30) -> str:
        """Search local/Zig-bundled Linux UAPI headers for a struct, typedef, or #define pattern."""
        return search_uapi_headers_impl(pattern, max_results)
    mcp.run()
# ==============================================================================
# Standalone CLI Entrypoint (Mode 2: Direct Bash Invocation)
# ==============================================================================
def main() -> None:
    if "--mcp" in sys.argv:
        run_mcp_server()
        return
    parser = argparse.ArgumentParser(
        description="Tinux Linux x86_64 ABI & UAPI Inspector CLI / FastMCP Server"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    # 1. syscall
    p_sys = sub.add_parser("syscall", help="Look up syscall by name or number")
    p_sys.add_argument("query", help="Syscall name (e.g. futex) or number (e.g. 202)")
    # 2. constants
    p_const = sub.add_parser("constants", help="Evaluate C macro constants")
    p_const.add_argument(
        "-i", "--include", action="append", required=True, help="Header file (e.g. fcntl.h)"
    )
    p_const.add_argument("macros", nargs="+", help="Macro names (e.g. O_CREAT O_TRUNC)")
    # 3. struct
    p_struct = sub.add_parser("struct", help="Probe C struct sizeof and field offsets")
    p_struct.add_argument(
        "-i", "--include", action="append", required=True, help="Header file (e.g. sys/stat.h)"
    )
    p_struct.add_argument("struct_type", help="Struct type (e.g. 'struct stat')")
    p_struct.add_argument("fields", nargs="*", help="Field names (e.g. st_mode st_size)")
    # 4. search
    p_search = sub.add_parser("search", help="Search Linux UAPI headers by regex")
    p_search.add_argument("pattern", help="Regex pattern to search")
    p_search.add_argument("-n", "--max", type=int, default=30, help="Max results")
    args = parser.parse_args()
    if args.cmd == "syscall":
        print(lookup_syscall_impl(args.query))
    elif args.cmd == "constants":
        print(eval_c_constants_impl(args.include, args.macros))
    elif args.cmd == "struct":
        print(probe_struct_abi_impl(args.include, args.struct_type, args.fields))
    elif args.cmd == "search":
        print(search_uapi_headers_impl(args.pattern, args.max))
if __name__ == "__main__":
    main()
```
---
## 3. Google Antigravity MCP Configuration
Add the following configuration to .antigravity/mcp.json so agents can autonomously query Linux ABI definitions:
```json
{
  "mcpServers": {
    "tinux-abi-inspector": {
      "command": "python3",
      "args": [
        "${workspaceFolder}/tools/tinux_abi_mcp.py",
        "--mcp"
      ]
    }
  }
}
```
---
## 4. Standalone CLI Usage Examples (For Builder Agent)
Direct CLI command examples for terminal usage without MCP:
### Example 1: Query Syscall Numbers and Arguments
```bash
./tools/tinux_abi_mcp.py syscall epoll
```
### Example 2: Query Exact Constant Values and Generate Zig Code
```bash
./tools/tinux_abi_mcp.py constants -i fcntl.h -i sys/mman.h O_CREAT O_EXCL O_TRUNC O_APPEND O_CLOEXEC MAP_FIXED MAP_ANONYMOUS
```
### Example 3: Inspect Struct Layouts and Comptime Assertions
```bash
# Inspect struct stat (144 bytes)
./tools/tinux_abi_mcp.py struct -i sys/stat.h "struct stat" st_dev st_ino st_nlink st_mode st_uid st_gid st_rdev st_size st_blksize st_blocks
# Inspect struct epoll_event (12 bytes packed on x86_64)
./tools/tinux_abi_mcp.py struct -i sys/epoll.h "struct epoll_event" events data
```
### Example 4: Search Header Definitions
```bash
./tools/tinux_abi_mcp.py search "TIOC[GS]PGRP"
```
