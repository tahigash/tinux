# Tinux Clean-Room Licensing & Binary Guardrails Policy

> **Objective:** Maintain a strict clean-room repository boundary, prevent GPL copyleft contamination from third-party binaries (e.g., precompiled BusyBox or musl runtime binaries), and preserve the hybrid **MIT / Apache-2.0** dual license model.

---

## 1. Clean-Room Architecture & Permissive Licensing

Tinux is an independent, clean-room implementation of the Linux x86_64 ABI written in Zig and assembly. It borrows no source code from the Linux kernel tree.

Because system call numbers, struct layouts, and MSR configurations are non-copyrightable functional interface specifications (ABI), the Linux kernel's GPL v2 license does not apply to Tinux kernel source code. Tinux is therefore freely distributed under a permissive dual license (**MIT OR Apache-2.0**).

---

## 2. Copyleft Risk Vectors & Prevention Rules

To preserve this clean-room status and prevent inadvertent copyleft obligations from triggering, the repository enforces three core prohibitions:

### Rule 1: No Pre-Compiled Binary Artifacts in Git

* **Prohibited Files:** `*.elf`, `*.bin`, `*.o`, `*.a`, `*.so`, `*.dylib`, `*.cpio`, `*.tar`, `*.img`, `*.qcow2`.
* **Rationale:** Committing pre-compiled binary artifacts obscures source provenance and risks bundling third-party binaries that carry reciprocal distribution obligations.
* **Enforcement:**
  - Automated tests cross-compile required user-space testing binaries (`src/user/*.zig`, `user_apps/*.c`) dynamically on the host into ignored temporary directories (`.cache/initramfs_root/bin/`).
  - Disk images and `initramfs.cpio` archives are assembled in memory or under `/tmp/` during test execution and deleted upon completion.

### Rule 2: Zero GPL Third-Party Binaries (BusyBox / Coreutils)

* **Prohibited Files:** Any binary named `busybox`, `coreutils`, or derivatives.
* **Rationale:** Distributing pre-compiled BusyBox or coreutils binaries triggers GPL v2 Section 3, requiring immediate availability of corresponding source code or a formal written offer.
* **Enforcement:**
  - Standard user-space commands used during development (e.g. `cat`, `ls`, `grep`) are provided by lightweight, standalone test tools written in Zig or the host distribution during testing.
  - The repository never checks in a pre-built BusyBox ELF.

### Rule 3: Linux Trademark Disclaimer

* All distributions and primary documentation (`README.md`) must display the non-affiliation disclaimer:
  > *"Tinux is an independent, clean-room implementation compatible with the Linux ABI. It is not an official project of Linus Torvalds or the Linux Foundation, and contains no source code from the Linux kernel."*

---

## 3. Automated Guardrail Infrastructure

The repository provides multi-tier automated guardrails that actively block violations:

### 1. Repository `.gitignore` Filter

The root `.gitignore` blocks binary executables, archives (`*.cpio`, `*.tar`), disk images, and userland build caches.

### 2. Guardrail Auditor Script (`scripts/check_license_guardrails.py`)

A static analysis tool that verifies:
* **Magic bytes inspection:** Scans every file for binary executable headers (ELF `\x7fELF`, CPIO `070701`, USTAR `ustar`, PE `MZ`, Mach-O).
* **Filename and extension verification:** Flags forbidden extensions (`.elf`, `.cpio`, `.img`, etc.) and blacklisted names (`busybox`).
* **License metadata parity:** Confirms the presence of `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`, and the `README.md` trademark disclaimer.

Run the auditor manually at any time:

```bash
python scripts/check_license_guardrails.py
```

### 3. Git Pre-Commit Hook (`.git/hooks/pre-commit`)

Automatically intercepts `git commit` commands and scans staged files (`--staged`). If a prohibited binary or foreign executable is detected, the commit is rejected immediately with an informative error message.

### 4. Harness Gate 0 Integration

Both the single-milestone harness (`scripts/verify_qemu.sh`) and the cumulative regression runner (`scripts/run_regression.sh`) execute the license guardrail auditor before starting kernel builds or QEMU instances. Any violation halts the build immediately.
