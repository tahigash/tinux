const std = @import("std");
const task = @import("task.zig");
const vmm = @import("../mm/vmm.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;
const errno_mod = @import("../uapi/errno.zig");
pub const SIGHUP: usize = 1;
pub const SIGINT: usize = 2;
pub const SIGQUIT: usize = 3;
pub const SIGILL: usize = 4;
pub const SIGABRT: usize = 6;
pub const SIGKILL: usize = 9;
pub const SIGUSR1: usize = 10;
pub const SIGSEGV: usize = 11;
pub const SIGUSR2: usize = 12;
pub const SIGPIPE: usize = 13;
pub const SIGALRM: usize = 14;
pub const SIGTERM: usize = 15;
pub const SIGCHLD: usize = 17;
pub const SIGCONT: usize = 18;
pub const SIGSTOP: usize = 19;
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;
pub const SA_SIGINFO: u64 = 0x0000_0004;
pub const SA_RESTORER: u64 = 0x0400_0000;
pub const SA_RESTART: u64 = 0x1000_0000;
pub const SA_NODEFER: u64 = 0x4000_0000;
pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;
pub const UNMASKABLE_SIGNALS: u64 = (@as(u64, 1) << (SIGKILL - 1)) | (@as(u64, 1) << (SIGSTOP - 1));
pub const KernelSigAction = extern struct {
    sa_handler: usize align(1) = SIG_DFL,
    sa_flags: u64 align(1) = 0,
    sa_restorer: usize align(1) = 0,
    sa_mask: u64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(KernelSigAction) == 32);
        std.debug.assert(@offsetOf(KernelSigAction, "sa_restorer") == 16);
    }
};
pub const SignalFrame = extern struct {
    pretcode: u64 align(1),
    trampoline: [16]u8 align(1),
    saved_sigmask: u64 align(1),
    saved_regs: SyscallFrame align(1),
    comptime {
        std.debug.assert(@sizeOf(SignalFrame) == 160);
        std.debug.assert(@offsetOf(SignalFrame, "trampoline") == 8);
        std.debug.assert(@offsetOf(SignalFrame, "saved_sigmask") == 24);
        std.debug.assert(@offsetOf(SignalFrame, "saved_regs") == 32);
    }
};
pub const LinuxItimerval = extern struct {
    it_interval_sec: i64 align(1) = 0,
    it_interval_usec: i64 align(1) = 0,
    it_value_sec: i64 align(1) = 0,
    it_value_usec: i64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxItimerval) == 32);
    }
};


161 ---
// x86_64 machine code: movq $15, %rax ; syscall ; nop...
pub const TRAMPOLINE_BYTES: [16]u8 = .{
    0x48, 0xC7, 0xC0, 0x0F, 0x00, 0x00, 0x00, // movq $15, %rax (SYS_rt_sigreturn)
    0x0F, 0x05,                               // syscall
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, // nop padding
};
pub fn sendSignalToTask(t: *task.Task, sig: usize) void {
    // Builder sets bit (sig - 1) in t.pending_signals and wakes t if in .WAITING_SIGNAL / .WAITING_SLEEP
}
pub fn deliverPendingSignals(frame: *SyscallFrame) *SyscallFrame {
    // Builder checks deliverable signals on task.currentTask(), builds SignalFrame on user stack
    // if a custom user handler is registered, and redirects frame.user_rip / frame.user_rsp / frame.rdi
}
pub fn restoreSignalFrame(frame: *SyscallFrame) *SyscallFrame {
    // Builder restores SyscallFrame and sig_mask from cur.last_sigframe_vaddr
}
