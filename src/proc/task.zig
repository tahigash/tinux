const std = @import("std");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");
const vfs = @import("../fs/vfs.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;

pub const MAX_TASKS: usize = 16;
pub const KERNEL_STACK_SIZE: usize = 32768;
pub const KSTACK_SIZE: usize = KERNEL_STACK_SIZE;
pub const DEFAULT_MMAP_BASE: usize = 0x2000_0000;

pub const TaskState = enum(u8) {
    UNUSED = 0,
    RUNNING = 1,
    READY = 2,
    WAITING_CHILD = 3,
    ZOMBIE = 4,
    WAITING_PIPE_READ = 5,
    WAITING_PIPE_WRITE = 6,
    WAITING_SLEEP = 7,
    WAITING_TTY = 8,
    WAITING_SOCK_READ = 9,
    WAITING_FUTEX = 10,
    WAITING_EPOLL = 11,
    WAITING_SIGNAL = 12,
    WAITING_SOCK_ACCEPT = 13,

    pub const RUNNABLE = TaskState.READY;
    pub const WAITING = TaskState.WAITING_CHILD;
    pub const BLOCKED = TaskState.WAITING_CHILD;

    pub fn isRunnable(self: TaskState) bool {
        return self == .READY or self == .RUNNING;
    }

    pub fn isBlocked(self: TaskState) bool {
        return switch (self) {
            .WAITING_CHILD,
            .WAITING_PIPE_READ,
            .WAITING_PIPE_WRITE,
            .WAITING_SLEEP,
            .WAITING_TTY,
            .WAITING_SOCK_READ,
            .WAITING_SOCK_ACCEPT,
            .WAITING_FUTEX,
            .WAITING_EPOLL,
            .WAITING_SIGNAL => true,
            else => false,
        };
    }
};

pub const Task = struct {
    pid: usize = 0,
    tgid: usize = 0,
    parent_pid: usize = 0,
    pgid: usize = 1,
    is_thread: bool = false,
    state: TaskState = .UNUSED,
    pml4_phys: usize = 0,
    kernel_stack_top: usize = 0,
    saved_frame: *SyscallFrame = undefined,
    fs_base: u64 = 0,
    initial_brk: usize = 0,
    current_brk: usize = 0,
    next_mmap_vaddr: usize = DEFAULT_MMAP_BASE,
    exit_status: i32 = 0,
    term_sig: u32 = 0,
    strace_enabled: bool = false,
    wait_target_pid: isize = -1,
    wait_pipe_idx: usize = 0,
    wait_sock_idx: usize = 0,
    wait_futex_paddr: usize = 0,
    wait_epoll_idx: usize = 0,
    sleep_wake_tick: u64 = 0,
    alarm_wake_tick: u64 = 0,
    clear_child_tid: usize = 0,
    cwd_buf: [vfs.MAX_PATH_LEN]u8 = [_]u8{'/'} ++ [_]u8{0} ** (vfs.MAX_PATH_LEN - 1),
    cwd_len: usize = 1,
    comm_buf: [32]u8 = [_]u8{0} ** 32,
    comm_len: usize = 0,
    fd_table: [vfs.MAX_OPEN_FILES]vfs.FdEntry = [_]vfs.FdEntry{.{}} ** vfs.MAX_OPEN_FILES,

    pub fn kstackTop(self: *const Task) usize {
        return self.kernel_stack_top;
    }

    pub fn cwd(self: *const Task) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    pub fn setComm(self: *Task, name: []const u8) void {
        const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| name[idx + 1 ..] else name;
        const n = @min(base.len, self.comm_buf.len - 1);
        @memset(&self.comm_buf, 0);
        @memcpy(self.comm_buf[0..n], base[0..n]);
        self.comm_len = n;
    }

    pub fn comm(self: *const Task) []const u8 {
        if (self.comm_len == 0) return "tinux_task";
        return self.comm_buf[0..self.comm_len];
    }

    pub fn closeAllFds(self: *Task) void {
        const pipe_mod = @import("../fs/pipe.zig");
        const sock_mod = @import("../net/socket.zig");
        for (&self.fd_table) |*e| {
            switch (e.kind) {
                .PIPE_READ => pipe_mod.closeReader(e.node_idx),
                .PIPE_WRITE => pipe_mod.closeWriter(e.node_idx),
                .SOCKET => sock_mod.close(e.node_idx),
                else => {},
            }
            e.* = .{};
        }
    }

    pub fn closeCloexecFds(self: *Task) void {
        const pipe_mod = @import("../fs/pipe.zig");
        const sock_mod = @import("../net/socket.zig");
        for (&self.fd_table) |*e| {
            if (e.cloexec and e.kind != .UNUSED) {
                switch (e.kind) {
                    .PIPE_READ => pipe_mod.closeReader(e.node_idx),
                    .PIPE_WRITE => pipe_mod.closeWriter(e.node_idx),
                    .SOCKET => sock_mod.close(e.node_idx),
                    else => {},
                }
                e.* = .{};
            }
        }
    }
};

pub var tasks: [MAX_TASKS]Task = [_]Task{.{}} ** MAX_TASKS;
var task_kernel_stacks: [MAX_TASKS][KERNEL_STACK_SIZE]u8 align(16) = undefined;
pub var current_task_idx: usize = 0;
var next_pid: usize = 1;

pub fn currentTask() *Task {
    return &tasks[current_task_idx];
}

pub fn currentTaskIndex() usize {
    return current_task_idx;
}

pub fn getTaskByPid(pid: usize) ?*Task {
    for (&tasks) |*t| {
        if (t.state != .UNUSED and t.pid == pid) {
            return t;
        }
    }
    return null;
}

pub fn getTaskIndexByPid(pid: usize) ?usize {
    for (&tasks, 0..) |*t, idx| {
        if (t.state != .UNUSED and t.pid == pid) {
            return idx;
        }
    }
    return null;
}

pub fn initPid1(pml4_phys: usize, initial_brk: usize, comm_name: []const u8) *Task {
    tasks[0] = .{
        .pid = 1,
        .tgid = 1,
        .parent_pid = 0,
        .pgid = 1,
        .state = .RUNNING,
        .pml4_phys = pml4_phys,
        .initial_brk = initial_brk,
        .current_brk = initial_brk,
    };
    tasks[0].kernel_stack_top = @intFromPtr(&task_kernel_stacks[0]) + KERNEL_STACK_SIZE;
    tasks[0].setComm(comm_name);
    vfs.initTaskFdTable(&tasks[0].fd_table);
    current_task_idx = 0;
    next_pid = 2;
    activateTask(0);
    return &tasks[0];
}

pub fn activateTask(next_idx: usize) void {
    current_task_idx = next_idx;
    tasks[next_idx].state = .RUNNING;
    syscall_arch.setKernelRsp(tasks[next_idx].kernel_stack_top);
    vmm.loadCr3(tasks[next_idx].pml4_phys);
    syscall_arch.wrmsr(syscall_arch.MSR_FS_BASE, tasks[next_idx].fs_base);
}

pub fn forkCurrentTask(frame: *SyscallFrame) ?usize {
    var slot: ?usize = null;
    for (&tasks, 0..) |*t, idx| {
        if (t.state == .UNUSED) {
            slot = idx;
            break;
        }
    }
    const child_idx = slot orelse return null;
    const parent = currentTask();

    const child_pml4 = vmm.cloneUserPml4(parent.pml4_phys) orelse return null;
    const child_stack_top = @intFromPtr(&task_kernel_stacks[child_idx]) + KERNEL_STACK_SIZE;

    const assigned_pid = next_pid;
    next_pid += 1;

    tasks[child_idx] = .{
        .pid = assigned_pid,
        .tgid = assigned_pid,
        .parent_pid = parent.pid,
        .pgid = parent.pgid,
        .is_thread = false,
        .state = .READY,
        .pml4_phys = child_pml4,
        .kernel_stack_top = child_stack_top,
        .fs_base = parent.fs_base,
        .initial_brk = parent.initial_brk,
        .current_brk = parent.current_brk,
        .next_mmap_vaddr = parent.next_mmap_vaddr,
        .cwd_buf = parent.cwd_buf,
        .cwd_len = parent.cwd_len,
        .comm_buf = parent.comm_buf,
        .comm_len = parent.comm_len,
        .fd_table = parent.fd_table,
    };

    // Duplicate FDs and increase ref counts (pipe/socket)
    const pipe_mod = @import("../fs/pipe.zig");
    const sock_mod = @import("../net/socket.zig");
    for (&tasks[child_idx].fd_table) |*e| {
        if (e.kind == .PIPE_READ) {
            pipe_mod.retainReader(e.node_idx);
        } else if (e.kind == .PIPE_WRITE) {
            pipe_mod.retainWriter(e.node_idx);
        } else if (e.kind == .SOCKET) {
            sock_mod.retain(e.node_idx);
        }
    }

    // Set up child's saved frame on child's kernel stack
    const child_frame_ptr = @as(*SyscallFrame, @ptrFromInt(child_stack_top - @sizeOf(SyscallFrame)));
    child_frame_ptr.* = frame.*;
    child_frame_ptr.rax = 0; // Fork return in child = 0
    tasks[child_idx].saved_frame = child_frame_ptr;

    return child_idx;
}

pub fn exitCurrentTask(exit_status: i32) *SyscallFrame {
    const cur = currentTask();
    cur.state = .ZOMBIE;
    cur.exit_status = exit_status;
    cur.closeAllFds();
    wakeParentIfWaiting(cur.parent_pid);
    const next_idx = scheduleNextOrWait();
    activateTask(next_idx);
    return tasks[next_idx].saved_frame;
}

pub fn wakeParentIfWaiting(parent_pid: usize) void {
    for (&tasks) |*t| {
        if (t.pid == parent_pid and t.state == .WAITING_CHILD) {
            t.state = .READY;
        }
    }
}

pub fn wakePipeWaiters(pipe_idx: usize) void {
    for (&tasks) |*t| {
        if ((t.state == .WAITING_PIPE_READ or t.state == .WAITING_PIPE_WRITE) and t.wait_pipe_idx == pipe_idx) {
            t.state = .READY;
        }
    }
}

pub fn wakeSleepingTasks(now_ticks: u64) void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_SLEEP and now_ticks >= t.sleep_wake_tick) {
            t.state = .READY;
        }
    }
}

pub fn wakeTtyWaiters() void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_TTY) {
            t.state = .READY;
        }
    }
}

pub fn wakeSocketReadWaiters(sock_idx: usize) void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_SOCK_READ and t.wait_sock_idx == sock_idx) {
            t.state = .READY;
        }
    }
}

pub fn wakeSocketAcceptWaiters(sock_idx: usize) void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_SOCK_ACCEPT and t.wait_sock_idx == sock_idx) {
            t.state = .READY;
        }
    }
}

pub fn scheduleNextReady() ?usize {
    const start = (current_task_idx + 1) % MAX_TASKS;
    for (0..MAX_TASKS) |i| {
        const idx = (start + i) % MAX_TASKS;
        if (tasks[idx].state == .READY) {
            return idx;
        }
    }
    return null;
}

pub fn scheduleNextOrWait() usize {
    const timer = @import("../drivers/timer.zig");
    while (true) {
        wakeSleepingTasks(timer.getTicks());

        if (scheduleNextReady()) |next_idx| {
            return next_idx;
        }

        // If current task is still running, continue
        if (tasks[current_task_idx].state == .RUNNING) {
            return current_task_idx;
        }

        // Wait for interrupt
        timer.waitForNextTick();
    }
}
