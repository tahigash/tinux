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

// x86_64 machine code: movq $15, %rax ; syscall ; nop...
pub const TRAMPOLINE_BYTES: [16]u8 = .{
    0x48, 0xC7, 0xC0, 0x0F, 0x00, 0x00, 0x00, // movq $15, %rax (SYS_rt_sigreturn)
    0x0F, 0x05,                               // syscall
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, // nop padding
};

fn validateUserAddress(addr: usize, len: usize) bool {
    if (len == 0) return true;
    if (addr < 0x1000 or addr >= 0x0000_8000_0000_0000) return false;
    const end_addr = std.math.add(usize, addr, len - 1) catch return false;
    if (end_addr >= 0x0000_8000_0000_0000) return false;
    const pml4 = vmm.readCr3();
    var page = addr & ~@as(usize, 0xFFF);
    const last_page = end_addr & ~@as(usize, 0xFFF);
    while (true) {
        const flags = vmm.getPteFlags(pml4, page) orelse return false;
        if ((flags & vmm.PTE_USER) == 0 or (flags & vmm.PTE_WRITABLE) == 0) return false;
        if (page == last_page) break;
        page += vmm.PAGE_SIZE;
    }
    return true;
}

pub fn sendSignalToTask(t: *task.Task, sig: usize) void {
    if (sig == 0 or sig > 64) return;
    const sig_bit = @as(u64, 1) << @intCast(sig - 1);
    t.pending_signals |= sig_bit;

    if (sig == SIGKILL) {
        if (t != task.currentTask()) {
            t.state = .ZOMBIE;
            t.exit_status = 128 + @as(i32, @intCast(sig));
            t.term_sig = @intCast(sig);
            t.closeAllFds();
            task.wakeParentIfWaiting(t.parent_pid);
            if (task.getTaskByPid(t.parent_pid)) |parent| {
                sendSignalToTask(parent, SIGCHLD);
            }
            return;
        }
    }

    const is_unmasked = (sig_bit & ~t.sig_mask) != 0 or (sig_bit & UNMASKABLE_SIGNALS) != 0;
    if (is_unmasked) {
        if (t.state == .WAITING_SIGNAL or t.state == .WAITING_SLEEP) {
            t.state = .READY;
        } else if (sig == SIGKILL and t.state.isBlocked()) {
            t.state = .READY;
        }
    }
}

pub fn deliverPendingSignals(frame: *SyscallFrame) *SyscallFrame {
    const cur = task.currentTask();
    if (cur.state == .UNUSED or cur.state == .ZOMBIE) return frame;
    if (cur.in_signal_handler) return frame;

    const unmasked = ~cur.sig_mask | UNMASKABLE_SIGNALS;

    while (true) {
        const deliverable = cur.pending_signals & unmasked;
        if (deliverable == 0) return frame;

        const sig_idx = @ctz(deliverable);
        const sig: usize = sig_idx + 1;
        const sig_bit = @as(u64, 1) << @intCast(sig_idx);
        cur.pending_signals &= ~sig_bit;

        const act = cur.sigactions[sig];

        // 1. Explicitly Ignored
        if (act.sa_handler == SIG_IGN) {
            continue;
        }

        // 2. Default Disposition
        if (act.sa_handler == SIG_DFL) {
            switch (sig) {
                SIGCHLD, 23, 28 => continue, // SIGCHLD (17), SIGURG (23), SIGWINCH (28) ignored by default
                SIGCONT, SIGSTOP => continue,
                else => {
                    cur.exit_status = 128 + @as(i32, @intCast(sig));
                    cur.term_sig = @intCast(sig);
                    return task.exitCurrentTask(cur.exit_status);
                },
            }
        }

        // 3. Custom User Handler (act.sa_handler > 1)
        const frame_total = 128 + @sizeOf(SignalFrame) + 16;
        if (frame.user_rsp < frame_total) {
            cur.exit_status = 128 + @as(i32, @intCast(SIGSEGV));
            cur.term_sig = @intCast(SIGSEGV);
            return task.exitCurrentTask(cur.exit_status);
        }

        const raw_top = frame.user_rsp - 128 - @sizeOf(SignalFrame);
        const sigframe_vaddr = (raw_top & ~@as(usize, 0xF)) - 8;

        if (sigframe_vaddr < 0x1000 or sigframe_vaddr >= 0x0000_8000_0000_0000 or !validateUserAddress(sigframe_vaddr, @sizeOf(SignalFrame))) {
            cur.exit_status = 128 + @as(i32, @intCast(SIGSEGV));
            cur.term_sig = @intCast(SIGSEGV);
            return task.exitCurrentTask(cur.exit_status);
        }

        const pretcode: u64 = if ((act.sa_flags & SA_RESTORER) != 0 and act.sa_restorer != 0)
            act.sa_restorer
        else
            sigframe_vaddr + 8;

        const sf_ptr = @as(*SignalFrame, @ptrFromInt(sigframe_vaddr));
        sf_ptr.* = .{
            .pretcode = pretcode,
            .trampoline = TRAMPOLINE_BYTES,
            .saved_sigmask = cur.sig_mask,
            .saved_regs = frame.*,
        };

        cur.last_sigframe_vaddr = sigframe_vaddr;
        cur.in_signal_handler = true;

        var new_mask = cur.sig_mask | act.sa_mask;
        if ((act.sa_flags & SA_NODEFER) == 0) {
            new_mask |= sig_bit;
        }
        cur.sig_mask = new_mask & ~UNMASKABLE_SIGNALS;

        frame.user_rip = act.sa_handler;
        frame.user_rsp = sigframe_vaddr;
        frame.rdi = sig;

        return frame;
    }
}

pub fn restoreSignalFrame(frame: *SyscallFrame) *SyscallFrame {
    const cur = task.currentTask();
    if (cur.last_sigframe_vaddr == 0) return frame;

    const sf_vaddr = cur.last_sigframe_vaddr;
    if (!validateUserAddress(sf_vaddr, @sizeOf(SignalFrame))) {
        return frame;
    }

    const sf_ptr = @as(*const SignalFrame, @ptrFromInt(sf_vaddr));

    cur.sig_mask = sf_ptr.saved_sigmask & ~UNMASKABLE_SIGNALS;
    cur.in_signal_handler = false;
    cur.last_sigframe_vaddr = 0;

    frame.* = sf_ptr.saved_regs;
    return deliverPendingSignals(frame);
}
