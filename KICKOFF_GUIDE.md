# Tinux Kickoff Procedure (`KICKOFF_GUIDE.md`)

> **Target Workflow:** Autonomous AI Engineering Environment / CLI  
> **Scope:** Full 20-Milestone Autonomous Execution (`TASK-001` .. `TASK-020`)

---

## Step 1: Workspace Integrity Audit

Open a terminal in the project root (`tinux/`) and run this command to verify that all 20 specifications, core scripts, and documents exist and have complete content:

```bash
chmod +x init_project.sh scripts/*.sh scripts/*.py tools/*.py 2>/dev/null || true
python3 - << 'EOF'
import os, sys

REQUIRED_FILES = [
    "PROGRESS.md",
    "ANTIGRAVITY_MASTER_PROMPT.md",
    "CHEATSHEET.md",
    "README.md",
    "docs/SPEC_TEMPLATE.md",
    "scripts/verify_qemu.sh",
    "scripts/triage_crash.py",
    "scripts/run_regression.sh",
    "scripts/debug_gdb.sh",
    "scripts/check_specs.sh",
    "tools/tinux_abi_mcp.py",
]

missing = [f for f in REQUIRED_FILES if not os.path.isfile(f) or os.path.getsize(f) < 100]

spec_errors = []
for i in range(1, 21):
    sp = f"docs/specs/SPEC_TASK_{i:03d}.md"
    if not os.path.isfile(sp):
        spec_errors.append(f"{sp} (MISSING)")
    else:
        txt = open(sp, errors="ignore").read()
        lines = len(txt.splitlines())
        if "STATUS: PLACEHOLDER" in txt or lines < 50:
            spec_errors.append(f"{sp} (INCOMPLETE: {lines} lines)")

print("=" * 70)
print("  Tinux 20-Milestone Workspace Audit")
print("=" * 70)
print(f"  Core Scripts & Docs Ready : {len(REQUIRED_FILES) - len(missing)}/{len(REQUIRED_FILES)}")
print(f"  Specifications Populated  : {20 - len(spec_errors)}/20")
print("=" * 70)

if missing or spec_errors:
    print("[ERROR] Found missing files or incomplete specifications:")
    for m in missing: print(f"  - Missing core file: {m}")
    for e in spec_errors: print(f"  - Spec issue: {e}")
    sys.exit(1)

print("[OK] Workspace integrity verified. Ready for autonomous execution!")
EOF
```

Next, run the pre-flight check for the host toolchain and QEMU devices:

```bash
./scripts/preflight_check.sh
```

---

## Step 2: Git Baseline Snapshot

Before starting the Builder agent, commit all specifications, scripts, and initial scaffolding to Git:

```bash
git add -A
git commit -m "chore(infra): establish clean 20-milestone baseline with audited specifications and harness"
```

---

## Step 3: Real-Time Progress Monitoring (Optional)

Split your terminal pane and run the monitoring command to track progress:

```bash
watch -n 2 'head -n 25 PROGRESS.md'
```

---

## Step 4: Builder Agent Kickoff Prompt

1. Open the agent panel and configure the autonomous builder agent.
2. Paste and send the following kickoff prompt:

```text
You are the Implementation Builder agent for the Tinux kernel project.

The workspace contains the complete specifications for all 20 milestones (`TASK-001` through `TASK-020`) in `docs/specs/`, along with the unified QEMU harness (`scripts/verify_qemu.sh`).

Follow the autonomous execution rules below. Begin implementing and verifying from `TASK-001`.

### 20-Task Autonomous Loop Rules

1. **Sequential execution:**
   - Inspect `PROGRESS.md` to identify the first incomplete task (`[ ]`), starting with `TASK-001`.
   - Read `docs/specs/SPEC_TASK_0XX.md` in full before writing code, adhering to sections 0 through 6 for data structures, comptime assertions, and error handling.
   - Use `scripts/verify_qemu.sh` as-is; it is already configured for all 20 milestones.

2. **Verification gate:**
   - After updating code, run `./scripts/verify_qemu.sh TASK-0XX 10`.
   - Confirm exit code `0` and verify the log contains both `[TINUX_TEST] PASS: TASK-0XX` and `[HARNESS] SUCCESS: TASK-0XX verified cleanly!`.

3. **Checkpointing:**
   - On success, update the task status in `PROGRESS.md` to `[x]` and commit:
     `git add -A && git commit -m "feat(kernel): complete TASK-0XX"`
   - Proceed immediately to the next task's specification (`TASK-0(XX+1)`) without pausing for user confirmation, continuing through `TASK-020`.

4. **3-strike escalation circuit breaker:**
   - If `./scripts/verify_qemu.sh` fails three consecutive times on the same task, halt immediately. Do not make a fourth ungrounded attempt.
   - Run `./scripts/triage_crash.py --out ESCALATION_REPORT.md` and complete Section 7 of the specification before stopping.

Read `PROGRESS.md` and `docs/specs/SPEC_TASK_001.md`, and start implementing `TASK-001`.
```
