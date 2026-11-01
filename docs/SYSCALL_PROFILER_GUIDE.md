# Tinux Syscall Profiler Guide (`src/syscall/profiler.zig`)

> **Purpose:** Measure execution cycles and invocation frequency for Linux syscalls using the x86_64 Time Stamp Counter (`rdtsc`).

---

## 1. Key Principles

* Serializes the pipeline with `lfence` before reading the 64-bit TSC via `rdtsc` to prevent out-of-order distortion.
* Excludes blocking rewind cycles (`frame.user_rip -= 2`) in calls such as `nanosleep`, `wait4`, or blocking `read`.
* Reading `/proc/syscalls` outputs all invoked syscalls sorted in descending order of cumulative cycle consumption (`% time`).
* Writing `reset` or `0` to `/proc/syscalls` resets all statistics counters atomically prior to benchmarking.

---

## 2. Implementation (`src/syscall/profiler.zig`)

Create `src/syscall/profiler.zig` with the following implementation:

```zig
const std = @import("std");

pub const MAX_SYSCALL_NR: usize = 350;

pub const SyscallStat = struct {
    count: u64 = 0,
    total_cycles: u64 = 0,
    min_cycles: u64 = std.math.maxInt(u64),
    max_cycles: u64 = 0,
};

pub var stats: [MAX_SYSCALL_NR]SyscallStat = [_]SyscallStat{.{}} ** MAX_SYSCALL_NR;
pub var total_kernel_cycles: u64 = 0;

pub inline fn readTscSerialized() u64 {
    asm volatile ("lfence" ::: "memory");
    return asm volatile (
        \\rdtsc
        \\shl $32, %%rdx
        \\or %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        :
        : "rdx"
    );
}

pub fn record(nr: usize, cycles: u64) void {
    if (nr >= MAX_SYSCALL_NR) return;
    var s = &stats[nr];
    s.count += 1;
    s.total_cycles += cycles;
    total_kernel_cycles += cycles;
    if (cycles < s.min_cycles) s.min_cycles = cycles;
    if (cycles > s.max_cycles) s.max_cycles = cycles;
}

pub fn reset() void {
    for (&stats) |*s| {
        s.* = .{};
    }
    total_kernel_cycles = 0;
}
```

---

## 3. Integration

### 3.1 `src/syscall/dispatch.zig` (Measurement Hooks)

Import `profiler.zig` and wrap execution in `syscallDispatch`:

```zig
const profiler = @import("profiler.zig");

pub fn syscallDispatch(frame: *SyscallFrame) *SyscallFrame {
    const t0 = profiler.readTscSerialized();
    const nr = frame.rax;

    // ... (dispatch logic) ...

    const t1 = profiler.readTscSerialized();
    if (t1 > t0) {
        profiler.record(nr, t1 - t0);
    }
    return out_frame;
}
```

### 3.2 `/proc/syscalls` Virtual Node

Expose formatted statistics through `/proc/syscalls` in `src/fs/procfs.zig`:

```bash
# Reset counters
echo reset > /proc/syscalls

# Run test workload
/bin/kv_server &

# View sorted profile
cat /proc/syscalls
```
