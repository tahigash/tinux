# Tinux Implementation Specification Template (Architect-Builder Pattern)

> **Usage Workflow:**
> 1. **[Architect Step 1 - Gemini 4 Argon]:** Fill out the blueprint draft based on kernel architecture and subsystem boundaries.
> 2. **[Architect Step 2 - Claude Opus 5.5]:** Audit Linux ABI compatibility, memory layouts, lock ordering, and register contracts.
> 3. **[Builder Step 3 - Gemini 3.8 Flash High]:** Ingest the audited specification, implement the code, and run the automated QEMU verification loop.

---

## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)

You are the **Implementation Builder**. Adhere strictly to the following rules:

1. **No Architectural Improvisation:**
   Do not rename structs, change field types, alter function signatures, or modify directory paths defined in this specification.
2. **Strict Zig Version Idioms:**
   Never output deprecated Zig idioms (e.g. 0.10/0.11 era built-ins). Follow Section 1's "Zig Idiom Cheat Sheet" exclusively.
3. **Compile-Time ABI Verification:**
   Every struct exchanged with Linux user space must include `comptime` assertions (`@sizeOf` and `@offsetOf`).
4. **3-Strike Escalation Protocol:**
   * If `zig build` or the QEMU harness fails **3 consecutive times**, do not attempt a 4th ungrounded speculative patch.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution for architectural review.

---

## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)

Use only modern Zig syntax (0.13 / 0.14 / 0.15+) to avoid compilation errors:

| Operation | Prohibited (Deprecated) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Bit cast | `@bitCast(DestType, val)` | `@as(DestType, @bitCast(val))` |
| Alignment cast | `@alignCast(4096, ptr)` | `@as(*align(4096) T, @alignCast(ptr))` |
| Enum to integer | `@enumToInt(e)` | `@intFromEnum(e)` |
| Integer to enum | `@intToEnum(MyEnum, i)` | `@as(MyEnum, @enumFromInt(i))` |
| C ABI struct | `struct { ... }` (undefined layout) | `extern struct { ... }` |
| Packed struct | Manual bit shifts | `packed struct(u64) { ... }` |
| Inline assembly | Loose string registers | `asm volatile ("..." : [ret] "={rax}" (-> usize) : [arg1] "{rdi}" (a1))` |

---

## 2. Task Metadata & Scope

* **Task ID:** `TASK-[ID]` (e.g. `TASK-012`)
* **Title:** `[Task Title]` (e.g. `sys_mmap Anonymous Private Mapping Implementation`)
* **Subsystem:** `[mm / vfs / proc / syscall / arch / net]`
* **Target Files to Create/Modify:**
  * `src/mm/vmm.zig` (Modify)
  * `src/syscall/dispatch.zig` (Modify)
* **Read-Only Reference Files:**
  * `src/mm/pmm.zig`
  * `src/uapi/errno.zig`

---

## 3. Linux ABI & UAPI Contract (Audited)

Strict interface contract required for binary compatibility with Linux binaries (musl/glibc).

### 3.1 System Call Numbers & Signatures (x86_64)

| Syscall | Number | Arg 0 (`rdi`) | Arg 1 (`rsi`) | Arg 2 (`rdx`) | Arg 3 (`r10`) | Arg 4 (`r8`) | Arg 5 (`r9`) | Return (`rax`) |
| :--- | :---: | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `sys_[name]` | `[num]` | `[type]` | `[type]` | `[type]` | `[type]` | `[type]` | `[type]` | `isize` |

### 3.2 Error Return Values (Negative `Errno`)

Evaluate conditions top-to-bottom and return negative error codes (`-@as(isize, @intFromEnum(Errno.XXX))`):

1. **`-EINVAL` (22):** Arguments are malformed or invalid (e.g. unaligned address or length is zero).
2. **`-ENOMEM` (12):** Virtual address space exhausted or physical frame allocation failed.
3. **`-EFAULT` (14):** User-space pointer references non-user memory above canonical boundary (`0x0000_7fff_ffff_ffff`).

---

## 4. Exact Data Structures & Signatures

Builder must implement the exact signatures below without changing struct layout or field order:

```zig
const std = @import("std");
const uapi = @import("../uapi/linux.zig");
const Errno = @import("../uapi/errno.zig").Errno;

pub const LinuxStructName = extern struct {
    field_a: u64,
    field_b: u32,
    _pad0: u32 = 0,

    comptime {
        // Guarantee 100% alignment and layout parity with Linux x86_64 ABI
        std.debug.assert(@sizeOf(LinuxStructName) == 16);
        std.debug.assert(@offsetOf(LinuxStructName, "field_b") == 8);
    }
};

pub fn targetFunction(
    task: *Task,
    arg1: usize,
    arg2: usize,
) Errno!usize {
    // Builder implements body according to Section 5
}
```

---

## 5. Step-by-Step Implementation Logic & State Transitions

1. **Step 1: Input Validation & Alignment**
   - Validate user pointer bounds and check required alignments.
2. **Step 2: Lock Acquisition (Lock Ordering Rule)**
   - Lock acquisition order: `[Lock A] -> [Lock B]` to prevent deadlocks.
   - Always place `defer lock.release();` immediately after acquisition.
3. **Step 3: Core State Mutation**
   - Update page tables, task descriptors, or virtual filesystem nodes.
4. **Step 4: Rollback on Partial Failure (`errdefer`)**
   - Use `errdefer` to unwind intermediate allocations if any step fails.
5. **Step 5: Return Value Formatting**
   - Return success result or cast negative error code to `isize` in dispatcher.

---

## 6. Verification Harness & Pass Criteria

### 6.1 Verification Command

```bash
zig build test-unit && ./scripts/verify_qemu.sh --test-case=[test_name] --timeout=5
```

### 6.2 Expected Output (Pass Criteria)

* `zig build` finishes with zero warnings and zero errors.
* QEMU serial output contains expected markers and exits with code `0`:
  ```text
  [TINUX_TEST] START: [test_name]
  [TINUX_TEST] PASS: [test_name]
  ```
* Zero Page Faults (`#PF`), General Protection Faults (`#GP`), or Kernel Panics.

---

## 7. Escalation Report Template (On 3rd Consecutive Failure)

If the build or QEMU test fails 3 consecutive times, stop immediately and output `ESCALATION_REPORT.md`:

```markdown
# Escalation Report: [Task ID]

## 1. Failure Summary
* **Failed Stage:** [Compile Error / QEMU Boot Hang / Kernel Panic / Syscall Return Mismatch]
* **Attempt History:**
  * Attempt 1: [Changes made and observed result]
  * Attempt 2: [Changes made and observed result]
  * Attempt 3: [Changes made and observed result]

## 2. Exact Error / Serial Log Output
```text
[Compiler error or last 50 lines of QEMU serial log / register dump (RIP, CR2, RSP)]
```

## 3. Current Code Diff
```diff
[Relevant source code changes or git diff]
```

## 4. Suspected Root Cause (For Architect Review)
* [Hypothesis on specification ambiguity, hardware edge cases, or register clobbers]
```
