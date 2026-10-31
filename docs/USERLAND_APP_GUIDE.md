# Tinux Userland Application Guide

> **Scope:** Compiling and executing standard static and dynamic C, Zig, and Rust binaries on the Tinux kernel.

---

## 1. Overview & Compatibility

The Tinux kernel supports the standard Linux x86_64 syscall ABI, System V process initialization stack (`argc`, `argv`, `envp`, `auxv`), Thread-Local Storage (`arch_prctl`), POSIX signals, non-blocking I/O, sockets, multi-threading, and persistent block storage (VirtIO-Block + TarFS).

No special OS SDK is required. Standard static Linux binaries built with Zig (`zig build-exe`, `zig cc`), C (`musl-gcc`), or Rust (`rustc --target x86_64-unknown-linux-musl`) execute directly on Tinux.

### Recommended Compiler Options by Toolchain

| Toolchain | Recommended Build Command | Binary Characteristics |
| :--- | :--- | :--- |
| `zig build-exe` | `zig build-exe app.zig -target x86_64-linux-none -O ReleaseSmall -fno-pie` | Zero libc dependency, fully static ELF64, fixed address load |
| `zig cc` (C) | `zig cc app.c -target x86_64-linux-musl -static -O2 -o app` | Statically linked with musl libc, full standard C runtime |
| `rustc` (Rust) | `rustc --target x86_64-unknown-linux-musl -C panic=abort -C opt-level=z app.rs` | Static Rust binary, libstd support |

---

## 2. Standard C Application (`user_apps/hello_c.c`)

A standard C example using musl libc for `printf`, `malloc`, and file operations:

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    printf("[USERLAND_C] Hello from Tinux userspace!\n");
    printf("[USERLAND_C] PID: %d, PPID: %d\n", getpid(), getppid());
    
    char *buf = malloc(128);
    if (!buf) {
        perror("malloc failed");
        return 1;
    }
    snprintf(buf, 128, "Dynamic buffer allocated successfully.\n");
    printf("%s", buf);
    free(buf);
    
    return 0;
}
```

### Build and Packaging

Compile `user_apps/hello_c.c` and install it into `initramfs.cpio` as `/bin/hello_c`:

```bash
zig cc user_apps/hello_c.c -target x86_64-linux-musl -static -O2 -o .cache/initramfs_root/bin/hello_c
```

---

## 3. High-Performance TCP Key-Value Server (`user_apps/kv_server.zig`)

An in-memory key-value store server listening on TCP port 8080 and answering `SET key val` and `GET key` commands:

```zig
const std = @import("std");
const net = std.net;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("[KV_SERVER] Starting in-memory KV server on 127.0.0.1:8080...\n", .{});

    const address = try net.Address.parseIp4("127.0.0.1", 8080);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var map = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    defer map.deinit();

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();

        var buf: [512]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) continue;

        const line = std.mem.trim(u8, buf[0..n], " \r\n");
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;

        if (std.mem.eql(u8, cmd, "SET")) {
            const key = it.next() orelse continue;
            const val = it.next() orelse continue;
            const key_dup = try std.heap.page_allocator.dupe(u8, key);
            const val_dup = try std.heap.page_allocator.dupe(u8, val);
            try map.put(key_dup, val_dup);
            try conn.stream.writeAll("OK\n");
        } else if (std.mem.eql(u8, cmd, "GET")) {
            const key = it.next() orelse continue;
            if (map.get(key)) |val| {
                try conn.stream.writeAll(val);
                try conn.stream.writeAll("\n");
            } else {
                try conn.stream.writeAll("(nil)\n");
            }
        } else {
            try conn.stream.writeAll("ERR unknown command\n");
        }
    }
}
```

---

## 4. Rust Application (`user_apps/hello_rs.rs`)

Rust applications using `std` (`HashMap`, threads, networking) compile against the musl target and run directly on Tinux:

```rust
use std::collections::HashMap;

fn main() {
    println!("[USERLAND_RUST] Hello from Rust running on Tinux kernel!");
    
    let mut scores = HashMap::new();
    scores.insert("Tinux", 100);
    scores.insert("Linux", 100);
    
    for (key, val) in &scores {
        println!("  - {}: {} pts", key, val);
    }
}
```

Build command:

```bash
rustc --target x86_64-unknown-linux-musl -C panic=abort -C opt-level=z user_apps/hello_rs.rs -o .cache/initramfs_root/bin/hello_rs
```

---

## 5. Execution in Interactive Shell

Start the interactive Tinux shell (`./scripts/verify_qemu.sh TASK-012 --interactive`) and execute the built binaries:

```sh
/bin/hello_c
/bin/hello_rs
/bin/kv_server &
```
