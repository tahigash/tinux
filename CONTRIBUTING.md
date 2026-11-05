# Contributing to Tinux

Thank you for your interest in contributing to **Tinux**!

Tinux is an independent, from-scratch, Linux ABI-compatible x86_64 operating system kernel written in Zig. Because of our from-scratch design and hybrid permissive licensing, all contributors must strictly adhere to the following principles.

---

## 1. Original Implementation & Licensing Principles

Tinux is distributed under a permissive dual license (**MIT OR Apache-2.0**). To protect the project, users, and contributors from intellectual property and copyright contamination:

1. **Zero GPL Code Contamination:**
   - **DO NOT** copy, paste, adapt, or transcribe source code or comments from the Linux kernel, GNU tools, BusyBox, or any GPL/AGPL-licensed project.
   - Implement all data structures, functions, drivers, and algorithms from scratch in Zig based solely on public specifications (such as POSIX standards, Linux man-pages, OSDev wiki, and hardware datasheets).

2. **No Proprietary Decompilations:**
   - Do not submit code derived from reverse engineering proprietary operating systems or copyrighted disassembly.

3. **No Compiled Binary Blobs:**
   - The repository tracks zero binary executables, object files, or pre-built archives. All test binaries and filesystem images must be built dynamically from source.
   - Any pull request introducing binary files (`.elf`, `.bin`, `.o`, `.so`, `.cpio`, `.tar`, `.exe`) will be automatically rejected by our CI guardrails.

---

## 2. Developer Certificate of Origin (DCO)

To certify that your contribution is your original work and conforms to these licensing principles, we require all commits to include a **Signed-off-by** line.

Use the `-s` or `--signoff` flag when committing:

```bash
git commit -s -m "feat(subsystem): descriptive summary of changes"
```

This adds a sign-off footer to your commit message:

```text
Signed-off-by: Your Name <your.email@example.com>
```

By signing off, you certify under the [Developer Certificate of Origin 1.1](https://developercertificate.org/) that you have the right to submit the work under Tinux's dual license (MIT OR Apache-2.0).

---

## 3. Coding and Quality Standards

1. **Target Toolchain:**
   - Zig version: `0.13.0` (or backward-compatible modern release).
   - Code must build freestanding with `-target x86_64-freestanding-none`.

2. **Pure 7-Bit ASCII Standard:**
   - All source code, specifications, and documentation must contain strictly 7-bit ASCII characters (`ord <= 127`).
   - Do not use non-ASCII punctuation, smart quotes, or non-English docstrings.

3. **Linux ABI Verification:**
   - All structs exchanged with Linux userland must include compile-time layout and size assertions (`@sizeOf` and `@offsetOf`).

---

## 4. Local Verification Workflow

Before submitting a Pull Request, run the local quality and license checks:

```bash
# 1. License and binary guardrail verification
python scripts/check_license_guardrails.py

# 2. Specification and ASCII integrity check
bash scripts/check_specs.sh

# 3. Compile kernel across configurations
zig build
zig build -Dtask=TASK-012
zig build -Dtask=TASK-020

# 4. Run automated QEMU verification
bash scripts/verify_qemu.sh TASK-012 10
bash scripts/verify_qemu.sh TASK-016 10
```

Confirm that all checks report `PASS` with exit code `0`.

---

## 5. Pull Request Guidelines

1. **Target Branch:** All pull requests should target the `main` branch.
2. **Atomic Commits:** Keep commits focused, well-documented, and signed off (`-s`).
3. **PR Description:** Complete the checklist in `.github/pull_request_template.md`.
4. **CI Passing:** All status checks in GitHub Actions must pass before a pull request can be merged.
