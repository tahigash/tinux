const task = @import("task.zig");
pub const FUTEX_WAIT: usize = 0;
pub const FUTEX_WAKE: usize = 1;
pub const FUTEX_WAIT_BITSET: usize = 9;
pub const FUTEX_WAKE_BITSET: usize = 10;
pub const FUTEX_CMD_MASK: usize = 0x7F;
pub fn wakeByPaddr(paddr: usize, max_wake: usize) usize {
    var woken: usize = 0;
    if (max_wake == 0) return 0;
    for (&task.tasks) |*t| {
        if (t.state == .WAITING_FUTEX and t.wait_futex_paddr == paddr) {
            t.state = .READY;
            t.wait_futex_paddr = 0;
            woken += 1;
            if (woken >= max_wake) break;
        }
    }
    return woken;
}
