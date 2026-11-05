# Tinux Virtual File System (VFS) Specification

> **Purpose:**
> Documents the architecture, in-memory structures, path resolution algorithm, and filesystem providers of the Tinux Virtual File System.

---

## 1. Overview and Design Principles

The Tinux Virtual File System (VFS) provides a unified POSIX-compatible filesystem interface for all storage, devices, pseudo-filesystems, and inter-process communication pipes.

All filesystem code is an independent from-scratch implementation written in Zig without copying source code or header definitions from the Linux kernel.

Default userland programs, utilities, and interactive shells (such as the in-tree Zig micro-userland) interact with the VFS exclusively via standard Linux System V AMD64 system calls (`open`, `read`, `write`, `close`, `lseek`, `stat`, `fstat`, `getdents64`, `openat`), without requiring external GPL-licensed BusyBox or coreutils binaries.

---

## 2. In-Memory Data Structures (`src/fs/vfs.zig`)

The VFS manages files, directories, and devices using a fixed-capacity table of nodes and open file descriptions.

### Core Limits
* `MAX_VFS_NODES`: 128 active nodes.
* `MAX_OPEN_FILES`: 32 global open file instances.
* `MAX_PATH_LEN`: 128 bytes maximum path length.

### Standard File Types and Modes
The high 4 bits of `st_mode` determine the node type:
* `S_IFDIR` (`0o040000`): Directory.
* `S_IFCHR` (`0o020000`): Character device (e.g. `/dev/tty`, `/dev/null`).
* `S_IFBLK` (`0o060000`): Block device (e.g. `/dev/vda`).
* `S_IFREG` (`0o100000`): Regular file.
* `S_IFIFO` (`0o010000`): Named or anonymous FIFO pipe.
* `S_IFLNK` (`0o120000`): Symbolic link.
* `S_IFSOCK` (`0o140000`): Unix domain socket endpoint.

### Linux Stat Structure (`LinuxStat`)
Layout matches the Linux x86_64 ABI:
```zig
pub const LinuxStat = extern struct {
    st_dev: u64 = 1,
    st_ino: u64 = 1,
    st_nlink: u64 = 1,
    st_mode: u32 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    __pad0: u32 = 0,
    st_rdev: u64 = 0,
    st_size: i64 = 0,
    st_blksize: i64 = 4096,
    st_blocks: i64 = 0,
    st_atime: i64 = 0,
    st_atime_nsec: i64 = 0,
    st_mtime: i64 = 0,
    st_mtime_nsec: i64 = 0,
    st_ctime: i64 = 0,
    st_ctime_nsec: i64 = 0,
    __unused: [3]i64 = [_]i64{0} ** 3,

    comptime {
        std.debug.assert(@sizeOf(LinuxStat) == 144);
        std.debug.assert(@offsetOf(LinuxStat, "st_mode") == 24);
        std.debug.assert(@offsetOf(LinuxStat, "st_size") == 48);
        std.debug.assert(@offsetOf(LinuxStat, "st_mtime") == 88);
    }
};
```

---

## 3. Path Resolution Algorithm (`walk_path`)

Path resolution translates a path string into a node index:

1. **Root vs Relative Resolution:**
   * If the path begins with `/`, resolution starts at the root node (index 0).
   * If the path does not begin with `/`, resolution starts at the calling task's current working directory (or directory specified by `dfd` in `openat`).
2. **Segment Parsing:**
   * The path is split into non-empty segments separated by `/`.
   * Segment `.` references the current node (no-op).
   * Segment `..` references the node's parent directory.
3. **Symbolic Link Expansion:**
   * When a directory path component resolves to a symbolic link (`S_IFLNK`), the target path is read and traversed recursively.
   * A maximum hop counter of 8 link dereferences is enforced. If exceeded, resolution halts with `-ELOOP`.
4. **Final Component Evaluation:**
   * For creation calls (`O_CREAT`), if the final component does not exist and the parent directory is writable, a new node is allocated.
   * If `O_CREAT | O_EXCL` is specified and the destination node already exists, resolution fails with `-EEXIST`.

---

## 4. Subsystems and Mount Points

### 1. Root Ramfs (`/`)
An in-memory hierarchical directory structure initialized at boot. Directories (`/bin`, `/dev`, `/proc`, `/tmp`, `/etc`, `/mnt`) are created directly in RAM.

### 2. CPIO Initramfs Unpacker (`src/fs/cpio.zig`)
During kernel boot, `cpio.unpackInitramfs` processes the initial ramdisk image:
* Reads SVR4 newc header records (`070701` / `070702`).
* Reconstructs directory hierarchies and creates regular file nodes with contents.
* Installs in-tree userland executables into `/bin/`.

### 3. Device Filesystem (`/dev`)
Character and block device nodes are exposed under `/dev`:
* `/dev/null`: Writes discard all data and return the input count. Reads return zero bytes (EOF).
* `/dev/zero`: Writes succeed. Reads return the requested number of zero bytes (`0x00`).
* `/dev/tty`: Direct access to the controlling terminal. Reads and writes interact with UART COM1 via the TTY line discipline.
* `/dev/console`: Kernel serial logging console.
* `/dev/urandom`: Cryptographic pseudorandom byte generator.

### 4. Process Pseudo-Filesystem (`/proc`, `src/fs/procfs.zig`)
Exposes kernel state and process metrics as dynamic read-only text streams:
* `/proc/version`: Kernel banner, build date, and toolchain version.
* `/proc/meminfo`: Physical memory usage, total frames, and free frames.
* `/proc/cpuinfo`: CPU model, frequency, and processor core count.
* `/proc/uptime`: System uptime in seconds and fractional ticks.
* `/proc/syscalls`: Profiler summary of invoked syscalls sorted by cycle consumption.
* `/proc/[pid]/stat`: Process state line formatted for standard process monitors.
* `/proc/[pid]/cmdline`: Process command-line argument vector.

### 5. TarFS Archive Filesystem (`/mnt`, `src/fs/tarfs.zig`)
Read-only filesystem driver that mounts POSIX USTAR archives directly from VirtIO block storage (`/dev/vda`):
* Reads 512-byte USTAR header blocks.
* Validates `ustar\0` magic at byte offset 257.
* Maps archive file entries into VFS directory nodes under `/mnt/`.

### 6. PipeFS (`src/fs/pipe.zig`)
Provides unidirectional anonymous byte pipes for IPC:
* Ring buffer with 4096-byte capacity.
* Readers block when the pipe is empty unless `O_NONBLOCK` is active.
* Writers block when the pipe is full.
* Writing to a pipe with no active readers delivers `SIGPIPE` and returns `-EPIPE`.

### 7. Epoll Multiplexing (`src/fs/epoll.zig`)
Event multiplexing subsystem supporting edge-triggered (`EPOLLET`) and level-triggered monitoring for sockets, pipes, and terminals via `sys_epoll_create1`, `sys_epoll_ctl`, and `sys_epoll_wait`.

---

## 5. File Descriptor Lifecycle

Each process (`Task`) maintains a file descriptor table (`fd_table`):
1. **Allocation:** File descriptor integers are assigned using the lowest available non-negative index (`0, 1, 2, ...`).
2. **Standard Descriptors:**
   * FD 0: Standard Input (`stdin`) connected to `/dev/tty`.
   * FD 1: Standard Output (`stdout`) connected to `/dev/tty`.
   * FD 2: Standard Error (`stderr`) connected to `/dev/tty`.
3. **Duplication:** `sys_dup` and `sys_dup2` increment the underlying open file reference count and assign an additional descriptor slot.
4. **Execution Cleanup:** Descriptors marked with `O_CLOEXEC` or `FD_CLOEXEC` are automatically closed during `sys_execve`.
