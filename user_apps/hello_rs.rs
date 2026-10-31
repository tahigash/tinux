// Prep (once): rustup target add x86_64-unknown-linux-musl
// Build: rustc --target x86_64-unknown-linux-musl -C target-feature=+crt-static -C relocation-model=static -C linker=zig-cc hello_rs.rs
use std::fs;
use std::process;

fn main() {
    println!("[RUST-APP] Hello from Rust std on Tinux! (PID={})", process::id());

    if let Ok(version) = fs::read_to_string("/proc/version") {
        print!("[RUST-APP] Kernel /proc/version: {}", version);
    }

    fs::write("/tmp/rust_note.txt", "Rust std::fs works on Tinux!\n")
        .expect("Failed to write /tmp/rust_note.txt");
    let read_back = fs::read_to_string("/tmp/rust_note.txt").unwrap();
    print!("[RUST-APP] Read back from tmpfs: {}", read_back);
}
