# Tinux Autonomous Kernel Engineering — Master Orchestrator Prompt

> **Target Environment:** Google Antigravity IDE / CLI  
> * **Primary Builder Model:** Gemini 3.8 Flash High (Fast Autonomous Execution Loop)  
> * **Escalation Architect / Auditor Models:** Gemini 4 Argon / Claude Opus 5.5  
> * **Project Goal:** Build **Tinux**, a clean-room Linux ABI-compatible x86_64 kernel written in Zig, executing `TASK-001` through `TASK-020` sequentially.

---

## 1. Directory Structure & Prerequisite Setup

Before starting execution, verify that the workspace matches the following layout:

```text
tinux/
├── ANTIGRAVITY_MASTER_PROMPT.md   # Master orchestration prompt
├── PROGRESS.md                    # Progress tracker updated autonomously by the agent
├── docs/
│   ├── SPEC_TEMPLATE.md           # Common specification template
│   └── specs/
│       ├── SPEC_TASK_001.md       # Boot, Serial COM1 & QEMU Harness
│       ├── SPEC_TASK_002.md       # GDT/TSS, IDT Exceptions & PMM
│       ├── SPEC_TASK_003.md       # 4-Level VMM & Kernel Heap Allocator
│       ├── SPEC_TASK_004.md       # SYSCALL/SYSRET, Ring 3 & sys_write/exit
│       ├── SPEC_TASK_005.md       # Static ELF64 Loader, Auxv, TLS & brk
│       ├── SPEC_TASK_006.md       # VFS, CPIO Initramfs & Unmodified BusyBox
│       ├── SPEC_TASK_007.md       # Multi-Process (fork/execve/wait4) & /bin/sh
│       ├── SPEC_TASK_008.md       # Pipes (pipe2), dup2 Redirection & /proc
│       ├── SPEC_TASK_009.md       # Writable tmpfs, getdents64 & ls/mkdir/rm
│       ├── SPEC_TASK_010.md       # Hardware Timer (PIT/PIC), nanosleep, ps & kill
│       ├── SPEC_TASK_011.md       # Dynamic ELF Loader (PT_INTERP / ld-musl)
│       ├── SPEC_TASK_012.md       # Interactive TTY Console (IRQ4 / termios)
│       ├── SPEC_TASK_013.md       # Linux Socket API (TCP Loopback & AF_UNIX)
│       ├── SPEC_TASK_014.md       # Multi-Threading (CLONE_VM), futex & epoll
│       ├── SPEC_TASK_015.md       # PCI Enumeration & VirtIO-Block (/dev/vda)
│       ├── SPEC_TASK_016.md       # Persistent TarFS Mount (sys_mount / sync)
│       ├── SPEC_TASK_017.md       # VirtIO-Net PCI Network Driver (ICMP Ping)
│       ├── SPEC_TASK_018.md       # User-Space Signal Delivery & sigaction
│       ├── SPEC_TASK_019.md       # UDP/IPv4 Socket Stack & DNS Resolver
│       └── SPEC_TASK_020.md       # Local APIC / IOAPIC Init & SMP Boot
```

---

## 2. Prompt for Primary Builder (Gemini 3.8 Flash High)

Select **Gemini 3.8 Flash High** in Google Antigravity and submit the following prompt to start the autonomous loop:

```text
You are the Implementation Builder agent for the Tinux kernel project.

Follow the protocol in `ANTIGRAVITY_MASTER_PROMPT.md`. Implement and verify each milestone from `docs/specs/SPEC_TASK_001.md` through `docs/specs/SPEC_TASK_020.md` sequentially, update `PROGRESS.md`, and complete all tasks.

### Autonomous Loop Rules

1. **Pre-flight environment check (run once):**
   - Run `zig version`, `qemu-system-x86_64 --version`, `cpio --version`, and `tar --version` to confirm your tooling.
   - If `PROGRESS.md` is missing, initialize the checklist for `TASK-001` through `TASK-020`.
   - Run `git status` and initialize the repository (`git init`) if needed.

2. **Strict sequential execution:**
   - Check `PROGRESS.md` and identify the first incomplete task (`TASK-0XX`).
   - Read the corresponding specification (`docs/specs/SPEC_TASK_0XX.md`) completely before writing code. Never combine or skip tasks.

3. **Automated verification gate:**
   - After implementing code, run the verification command specified in Section 6:
     `./scripts/verify_qemu.sh TASK-0XX [timeout]`
   - Verify the command exits with code `0` and outputs both:
     `[TINUX_TEST] PASS: TASK-0XX` and `[HARNESS] SUCCESS: TASK-0XX verified cleanly!`.

4. **Checkpointing and progression:**
   - On success, update `PROGRESS.md` with `[x] TASK-0XX: PASSED` and commit:
     `git add -A && git commit -m "feat(kernel): implement TASK-0XX"`
   - Proceed immediately to the next specification (`TASK-0(XX+1)`) and continue the loop.

5. **3-strike escalation circuit breaker:**
   - If `./scripts/verify_qemu.sh` fails three consecutive times on the same task, stop immediately. Do not make a fourth ungrounded attempt.
   - Generate `ESCALATION_REPORT.md` following Section 7 of the specification, report the failure, and halt execution for architectural review.
```

---

## 3. Prompt for Escalation Architect (Gemini 4 Argon / Claude Opus 5.5)

If the Builder agent triggers the 3-strike escalation and halts with `ESCALATION_REPORT.md`, switch the active model to **Gemini 4 Argon** or **Claude Opus 5.5**, and submit the following prompt:

```text
The Builder agent reached the 3-strike failure limit and generated an ESCALATION_REPORT.md.

1. Review `ESCALATION_REPORT.md`, the task specification (`docs/specs/SPEC_TASK_0XX.md`), and the current code diff.
2. Determine the root cause and apply the appropriate resolution:
   - If the specification was ambiguous or missed edge cases, revise `docs/specs/SPEC_TASK_0XX.md` directly so the Builder can implement it cleanly.
   - If the issue is a specific low-level fault (such as register clobbering or page table calculation errors), apply the targeted fix and verify `./scripts/verify_qemu.sh TASK-0XX` passes.

Once resolved, switch back to Gemini 3.8 Flash High and instruct it to resume autonomous execution from the next pending task in `PROGRESS.md`.
```
