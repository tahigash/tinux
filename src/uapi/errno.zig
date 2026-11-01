const std = @import("std");

pub const Errno = error{
    EPERM,
    ENOENT,
    ESRCH,
    EINTR,
    EIO,
    ENXIO,
    E2BIG,
    ENOEXEC,
    EBADF,
    ECHILD,
    EAGAIN,
    ENOMEM,
    EACCES,
    EFAULT,
    EBUSY,
    EEXIST,
    EXDEV,
    ENODEV,
    ENOTDIR,
    EISDIR,
    EINVAL,
    ENFILE,
    EMFILE,
    ENOTTY,
    ENOSPC,
    ESPIPE,
    EROFS,
    EPIPE,
    ERANGE,
    ENOSYS,
    ENOTEMPTY,
    ENOTSOCK,
    EOPNOTSUPP,
    EAFNOSUPPORT,
    EADDRINUSE,
    EADDRNOTAVAIL,
    ENETUNREACH,
    ECONNABORTED,
    ECONNRESET,
    ENOBUFS,
    EISCONN,
    ENOTCONN,
    ETIMEDOUT,
    ECONNREFUSED,
    OutOfMemory,
};

pub const ErrnoCode = enum(u16) {
    EPERM = 1,
    ENOENT = 2,
    ESRCH = 3,
    EINTR = 4,
    EIO = 5,
    ENXIO = 6,
    E2BIG = 7,
    ENOEXEC = 8,
    EBADF = 9,
    ECHILD = 10,
    EAGAIN = 11,
    ENOMEM = 12,
    EACCES = 13,
    EFAULT = 14,
    EBUSY = 16,
    EEXIST = 17,
    EXDEV = 18,
    ENODEV = 19,
    ENOTDIR = 20,
    EISDIR = 21,
    EINVAL = 22,
    ENFILE = 23,
    EMFILE = 24,
    ENOTTY = 25,
    ENOSPC = 28,
    ESPIPE = 29,
    EROFS = 30,
    EPIPE = 32,
    ERANGE = 34,
    ENOSYS = 38,
    ENOTEMPTY = 39,
    ENOTSOCK = 88,
    EOPNOTSUPP = 95,
    EAFNOSUPPORT = 97,
    EADDRINUSE = 98,
    EADDRNOTAVAIL = 99,
    ENETUNREACH = 101,
    ECONNABORTED = 103,
    ECONNRESET = 104,
    ENOBUFS = 105,
    EISCONN = 106,
    ENOTCONN = 107,
    ETIMEDOUT = 110,
    ECONNREFUSED = 111,
};

pub inline fn toReturn(err: anytype) isize {
    const T = @TypeOf(err);
    if (T == Errno or @typeInfo(T) == .ErrorSet) {
        if (err == error.EPERM) return -1;
        if (err == error.ENOENT) return -2;
        if (err == error.ESRCH) return -3;
        if (err == error.EINTR) return -4;
        if (err == error.EIO) return -5;
        if (err == error.ENXIO) return -6;
        if (err == error.E2BIG) return -7;
        if (err == error.ENOEXEC) return -8;
        if (err == error.EBADF) return -9;
        if (err == error.ECHILD) return -10;
        if (err == error.EAGAIN) return -11;
        if (err == error.ENOMEM or err == error.OutOfMemory) return -12;
        if (err == error.EACCES) return -13;
        if (err == error.EFAULT) return -14;
        if (err == error.EBUSY) return -16;
        if (err == error.EEXIST) return -17;
        if (err == error.EXDEV) return -18;
        if (err == error.ENODEV) return -19;
        if (err == error.ENOTDIR) return -20;
        if (err == error.EISDIR) return -21;
        if (err == error.EINVAL) return -22;
        if (err == error.ENFILE) return -23;
        if (err == error.EMFILE) return -24;
        if (err == error.ENOTTY) return -25;
        if (err == error.ENOSPC) return -28;
        if (err == error.ESPIPE) return -29;
        if (err == error.EROFS) return -30;
        if (err == error.EPIPE) return -32;
        if (err == error.ERANGE) return -34;
        if (err == error.ENOSYS) return -38;
        if (err == error.ENOTEMPTY) return -39;
        if (err == error.ENOTSOCK) return -88;
        if (err == error.EOPNOTSUPP) return -95;
        if (err == error.EAFNOSUPPORT) return -97;
        if (err == error.EADDRINUSE) return -98;
        if (err == error.EADDRNOTAVAIL) return -99;
        if (err == error.ENETUNREACH) return -101;
        if (err == error.ECONNABORTED) return -103;
        if (err == error.ECONNRESET) return -104;
        if (err == error.ENOBUFS) return -105;
        if (err == error.EISCONN) return -106;
        if (err == error.ENOTCONN) return -107;
        if (err == error.ETIMEDOUT) return -110;
        if (err == error.ECONNREFUSED) return -111;
        return -22;
    } else {
        switch (err) {
            .EPERM => return -1,
            .ENOENT => return -2,
            .ESRCH => return -3,
            .EINTR => return -4,
            .EIO => return -5,
            .ENXIO => return -6,
            .E2BIG => return -7,
            .ENOEXEC => return -8,
            .EBADF => return -9,
            .ECHILD => return -10,
            .EAGAIN => return -11,
            .ENOMEM => return -12,
            .EACCES => return -13,
            .EFAULT => return -14,
            .EBUSY => return -16,
            .EEXIST => return -17,
            .EXDEV => return -18,
            .ENODEV => return -19,
            .ENOTDIR => return -20,
            .EISDIR => return -21,
            .EINVAL => return -22,
            .ENFILE => return -23,
            .EMFILE => return -24,
            .ENOTTY => return -25,
            .ENOSPC => return -28,
            .ESPIPE => return -29,
            .EROFS => return -30,
            .EPIPE => return -32,
            .ERANGE => return -34,
            .ENOSYS => return -38,
            .ENOTEMPTY => return -39,
            .ENOTSOCK => return -88,
            .EOPNOTSUPP => return -95,
            .EAFNOSUPPORT => return -97,
            .EADDRINUSE => return -98,
            .EADDRNOTAVAIL => return -99,
            .ENETUNREACH => return -101,
            .ECONNABORTED => return -103,
            .ECONNRESET => return -104,
            .ENOBUFS => return -105,
            .EISCONN => return -106,
            .ENOTCONN => return -107,
            .ETIMEDOUT => return -110,
            .ECONNREFUSED => return -111,
            else => return -22,
        }
    }
}
