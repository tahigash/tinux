// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Clean-room Adversarial Virtual Memory Isolation and Fork Verifier

const std = @import("std");

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call testMain
    );
}

inline fn sys0(n: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
        : "rcx", "r11", "memory"
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}

inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
        : "rcx", "r11", "memory"
    );
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
          [d] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}

inline fn sys6(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
          [d] "{r10}" (a4),
          [e] "{r8}" (a5),
          [f] "{r9}" (a6),
        : "rcx", "r11", "memory"
    );
}

fn print(msg: []const u8) void {
    _ = sys3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("[ADVERSARIAL_FAIL] ");
    print(msg);
    print("\n");
    _ = sys1(60, code);
    unreachable;
}

// Global data to verify data section isolation across fork
var global_canary: u64 = 0x1122_3344_5566_7788;
var global_array: [8]u32 = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80 };

pub export fn testMain() callconv(.C) noreturn {
    print("\n[ADVERSARIAL_TEST] START: VMM Isolation & Fork Stress Suite\n");

    // =========================================================================
    // Challenge 1: cloneUserPml4 Deep Copy (Child writes must NOT mutate parent)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Running Challenge 1: cloneUserPml4 Deep Copy...\n");
    var stack_canary: u64 = 0xCAFE_BABE_DEAD_BEEF;

    // Allocate heap memory via brk
    const init_brk = @as(usize, @intCast(sys1(12, 0)));
    const heap_base = @as(usize, @intCast(sys1(12, init_brk + 4096)));
    if (heap_base <= init_brk) fail(101, "Challenge 1: brk allocation failed");
    const heap_canary_ptr = @as(*volatile u64, @ptrFromInt(init_brk));
    heap_canary_ptr.* = 0x1357_2468_AABB_CCDD;

    // Allocate mmap memory
    const mmap_res = sys6(9, 0, 4096, 3, 0x22, @bitCast(@as(isize, -1)), 0);
    if (mmap_res < 0) fail(102, "Challenge 1: mmap allocation failed");
    const mmap_canary_ptr = @as(*volatile u64, @ptrFromInt(@as(usize, @intCast(mmap_res))));
    mmap_canary_ptr.* = 0x9988_7766_5544_3322;

    const pid1 = sys0(57); // sys_fork
    if (pid1 < 0) fail(103, "Challenge 1: sys_fork failed");

    if (pid1 == 0) {
        // In Child Process: Verify initial values inherited, then mutate them
        if (global_canary != 0x1122_3344_5566_7788) fail(104, "Child 1: global canary mismatch");
        if (stack_canary != 0xCAFE_BABE_DEAD_BEEF) fail(105, "Child 1: stack canary mismatch");
        if (heap_canary_ptr.* != 0x1357_2468_AABB_CCDD) fail(106, "Child 1: heap canary mismatch");
        if (mmap_canary_ptr.* != 0x9988_7766_5544_3322) fail(107, "Child 1: mmap canary mismatch");

        // Mutate all canaries in child address space
        global_canary = 0xDEAD_DEAD_DEAD_DEAD;
        stack_canary = 0xBEEF_BEEF_BEEF_BEEF;
        heap_canary_ptr.* = 0xFEED_FEED_FEED_FEED;
        mmap_canary_ptr.* = 0xFACE_FACE_FACE_FACE;
        global_array[3] = 9999;

        _ = sys1(60, 42); // sys_exit(42)
        unreachable;
    }

    // In Parent Process: Wait for child to finish mutating
    var status1: i32 = 0;
    const reaped1 = sys4(61, @intCast(pid1), @intFromPtr(&status1), 0, 0);
    if (reaped1 != pid1) fail(108, "Challenge 1: wait4 returned wrong pid");
    if ((status1 >> 8) != 42) fail(109, "Challenge 1: child exit code wrong");

    // Adversarial verification: Parent values must remain intact!
    if (global_canary != 0x1122_3344_5566_7788) fail(110, "MUTATION LEAK: Child mutated parent global canary!");
    if (stack_canary != 0xCAFE_BABE_DEAD_BEEF) fail(111, "MUTATION LEAK: Child mutated parent stack canary!");
    if (heap_canary_ptr.* != 0x1357_2468_AABB_CCDD) fail(112, "MUTATION LEAK: Child mutated parent heap canary!");
    if (mmap_canary_ptr.* != 0x9988_7766_5544_3322) fail(113, "MUTATION LEAK: Child mutated parent mmap canary!");
    if (global_array[3] != 40) fail(114, "MUTATION LEAK: Child mutated parent global array element!");
    print("[ADVERSARIAL_TEST] PASS: Challenge 1 (cloneUserPml4 deep copy) verified.\n");

    // =========================================================================
    // Challenge 2: Page Table Unsharing & Mapping Leakage
    // =========================================================================
    print("[ADVERSARIAL_TEST] Running Challenge 2: Page Table Unsharing...\n");
    const pid2 = sys0(57);
    if (pid2 < 0) fail(201, "Challenge 2: sys_fork failed");

    // Address to map exclusively in child: 0x2400_0000 (well above current mmap base)
    const child_exclusive_vaddr: usize = 0x2400_0000;

    if (pid2 == 0) {
        // Child creates an explicit private page mapping
        const child_map = sys6(9, child_exclusive_vaddr, 4096, 3, 0x32, @bitCast(@as(isize, -1)), 0);
        if (child_map < 0) fail(202, "Child 2: mmap failed");
        const ptr = @as(*volatile u64, @ptrFromInt(child_exclusive_vaddr));
        ptr.* = 0xCAFE_1234_5678_BABE;
        if (ptr.* != 0xCAFE_1234_5678_BABE) fail(203, "Child 2: mapped page readback failed");
        _ = sys1(60, 55);
        unreachable;
    }

    var status2: i32 = 0;
    const reaped2 = sys4(61, @intCast(pid2), @intFromPtr(&status2), 0, 0);
    if (reaped2 != pid2 or (status2 >> 8) != 55) fail(204, "Challenge 2: wait4 failed");

    // Parent must NOT have child_exclusive_vaddr mapped in its page tables.
    // Testing write(1, child_exclusive_vaddr, 8): validateUserBuffer must return -EFAULT.
    const leak_check = sys3(1, 1, child_exclusive_vaddr, 8);
    if (leak_check >= 0) {
        fail(205, "PAGE TABLE LEAK: Child mapping leaked into parent page table!");
    }
    print("[ADVERSARIAL_TEST] PASS: Challenge 2 (page table unsharing) verified.\n");

    // =========================================================================
    // Challenge 3: Heap Independence (sys_brk isolation)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Running Challenge 3: Heap Independence (sys_brk)...\n");
    const parent_pre_brk = @as(usize, @intCast(sys1(12, 0)));

    const pid3 = sys0(57);
    if (pid3 < 0) fail(301, "Challenge 3: sys_fork failed");

    if (pid3 == 0) {
        // In Child: verify initial brk equals parent brk
        const child_init_brk = @as(usize, @intCast(sys1(12, 0)));
        if (child_init_brk != parent_pre_brk) fail(302, "Child 3: initial brk mismatch");

        // Expand child brk by 8 KiB (2 pages)
        const child_new_brk = @as(usize, @intCast(sys1(12, child_init_brk + 8192)));
        if (child_new_brk != child_init_brk + 8192) fail(303, "Child 3: sys_brk expansion failed");

        // Write signature into expanded heap
        const c_ptr1 = @as(*volatile u64, @ptrFromInt(child_init_brk + 128));
        const c_ptr2 = @as(*volatile u64, @ptrFromInt(child_init_brk + 4200));
        c_ptr1.* = 0xAA55_AA55_AA55_AA55;
        c_ptr2.* = 0x55AA_55AA_55AA_55AA;

        _ = sys1(60, 66);
        unreachable;
    }

    var status3: i32 = 0;
    const reaped3 = sys4(61, @intCast(pid3), @intFromPtr(&status3), 0, 0);
    if (reaped3 != pid3 or (status3 >> 8) != 66) fail(304, "Challenge 3: wait4 failed");

    // Parent brk must be completely untouched
    const parent_post_brk = @as(usize, @intCast(sys1(12, 0)));
    if (parent_post_brk != parent_pre_brk) {
        fail(305, "HEAP CORRUPTION: Parent brk was altered by child sys_brk!");
    }

    // Now parent expands its OWN heap by 8 KiB
    const parent_expanded_brk = @as(usize, @intCast(sys1(12, parent_pre_brk + 8192)));
    if (parent_expanded_brk != parent_pre_brk + 8192) fail(306, "Parent heap expansion failed");

    // Verify parent's newly mapped heap contains clean zeroed pages, NOT child data!
    const p_ptr1 = @as(*volatile u64, @ptrFromInt(parent_pre_brk + 128));
    const p_ptr2 = @as(*volatile u64, @ptrFromInt(parent_pre_brk + 4200));
    if (p_ptr1.* != 0 or p_ptr2.* != 0) {
        fail(307, "HEAP DATA LEAK: Parent saw child heap data in newly allocated brk pages!");
    }

    p_ptr1.* = 0x1111_2222_3333_4444;
    p_ptr2.* = 0x5555_6666_7777_8888;
    if (p_ptr1.* != 0x1111_2222_3333_4444 or p_ptr2.* != 0x5555_6666_7777_8888) {
        fail(308, "Parent heap readback mismatch");
    }
    print("[ADVERSARIAL_TEST] PASS: Challenge 3 (heap independence) verified.\n");

    // =========================================================================
    // Challenge 4: Stress Test Repeated Fork/Exit Cycles Under QEMU
    // =========================================================================
    print("[ADVERSARIAL_TEST] Running Challenge 4: 50 Repeated Fork/Exit Cycles...\n");
    var cycle: usize = 0;
    while (cycle < 50) : (cycle += 1) {
        const p = sys0(57);
        if (p < 0) {
            fail(401, "Stress cycle: sys_fork failed");
        }
        if (p == 0) {
            // Child modifies local state and exits with cycle-dependent code
            var local_var: usize = cycle * 7 + 3;
            local_var += 1;
            const exit_code = (cycle + 1) & 0x7F;
            _ = sys1(60, exit_code);
            unreachable;
        }

        var st: i32 = 0;
        const r = sys4(61, @intCast(p), @intFromPtr(&st), 0, 0);
        if (r != p) fail(402, "Stress cycle: wait4 returned wrong pid");
        const expected_code: i32 = @intCast((cycle + 1) & 0x7F);
        if ((st >> 8) != expected_code) {
            fail(403, "Stress cycle: wait4 returned unexpected exit status");
        }
    }
    print("[ADVERSARIAL_TEST] PASS: Challenge 4 (50 repeated fork/exit cycles) verified.\n");

    // =========================================================================
    // Challenge 5: Multi-generation Hierarchy (Parent -> Child -> Grandchild)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Running Challenge 5: Multi-generation Hierarchy...\n");
    var multi_gen_canary: u64 = 0xAAAA_BBBB_CCCC_DDDD;

    const pid_child = sys0(57);
    if (pid_child < 0) fail(501, "Multi-gen: parent fork failed");

    if (pid_child == 0) {
        // In Child
        if (multi_gen_canary != 0xAAAA_BBBB_CCCC_DDDD) fail(502, "Child: canary mismatch");
        multi_gen_canary = 0x1111_1111_1111_1111;

        const pid_grandchild = sys0(57);
        if (pid_grandchild < 0) fail(503, "Multi-gen: child fork failed");

        if (pid_grandchild == 0) {
            // In Grandchild
            if (multi_gen_canary != 0x1111_1111_1111_1111) fail(504, "Grandchild: canary mismatch");
            multi_gen_canary = 0x9999_9999_9999_9999;
            _ = sys1(60, 77);
            unreachable;
        }

        // Child waits for Grandchild
        var st_gc: i32 = 0;
        const r_gc = sys4(61, @intCast(pid_grandchild), @intFromPtr(&st_gc), 0, 0);
        if (r_gc != pid_grandchild or (st_gc >> 8) != 77) fail(505, "Child: wait4 on grandchild failed");
        if (multi_gen_canary != 0x1111_1111_1111_1111) fail(506, "LEAK: Grandchild mutated child canary!");

        _ = sys1(60, 88);
        unreachable;
    }

    var st_c: i32 = 0;
    const r_c = sys4(61, @intCast(pid_child), @intFromPtr(&st_c), 0, 0);
    if (r_c != pid_child or (st_c >> 8) != 88) fail(507, "Parent: wait4 on child failed");
    if (multi_gen_canary != 0xAAAA_BBBB_CCCC_DDDD) fail(508, "LEAK: Child/Grandchild mutated parent canary!");
    print("[ADVERSARIAL_TEST] PASS: Challenge 5 (multi-generation hierarchy) verified.\n");

    print("\n[ADVERSARIAL_TEST] ALL 5 ADVERSARIAL CHALLENGES CONFIRMED AND PASSED!\n");
    _ = sys1(60, 0);
    unreachable;
}

pub fn main() void {}
