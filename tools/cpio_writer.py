#!/usr/bin/env python3
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0

"""
Tinux SVR4 newc CPIO archive writer.

Creates POSIX SVR4 newc (magic 070701) CPIO archives for initramfs images.
Replaces external cpio utility with a pure Python standard library implementation.

Usage:
    python tools/cpio_writer.py <source_dir> <output_cpio_path>
    python tools/cpio_writer.py --stdin <output_cpio_path>
"""

import os
import sys

def normalize_arcname(rel_path):
    p = rel_path.replace("\\", "/").strip()
    while p.startswith("./"):
        p = p[2:]
    return p.strip("/")

def determine_mode(file_path, arcname, is_dir):
    if is_dir:
        return 0o040755  # S_IFDIR | 0o755
    basename = os.path.basename(file_path)
    is_exec = (
        arcname.startswith("bin/") or
        arcname.startswith("lib/") or
        basename.endswith(".sh")
    )
    if not is_exec and os.path.isfile(file_path):
        try:
            with open(file_path, "rb") as fp:
                magic = fp.read(4)
                if magic == b"\x7fELF":
                    is_exec = True
        except OSError:
            pass
    if not is_exec and hasattr(os, "stat"):
        try:
            st = os.stat(file_path)
            if st.st_mode & 0o111:
                is_exec = True
        except OSError:
            pass
    return 0o100755 if is_exec else 0o100644  # S_IFREG | (0o755 or 0o644)

def write_entry(out, arcname, mode, data, ino):
    name_bytes = arcname.encode("utf-8") + b"\x00"
    namesize = len(name_bytes)
    pad1 = (4 - ((110 + namesize) % 4)) % 4
    filesize = len(data)
    pad2 = (4 - (filesize % 4)) % 4
    nlink = 2 if (mode & 0o170000) == 0o040000 else 1

    header = (
        f"070701"
        f"{ino:08x}"
        f"{mode:08x}"
        f"{0:08x}"       # uid
        f"{0:08x}"       # gid
        f"{nlink:08x}"
        f"{0:08x}"       # mtime
        f"{filesize:08x}"
        f"{0:08x}"       # devmajor
        f"{0:08x}"       # devminor
        f"{0:08x}"       # rdevmajor
        f"{0:08x}"       # rdevminor
        f"{namesize:08x}"
        f"{0:08x}"       # check
    ).encode("ascii")

    out.write(header)
    out.write(name_bytes)
    if pad1:
        out.write(b"\x00" * pad1)
    if filesize > 0:
        out.write(data)
    if pad2:
        out.write(b"\x00" * pad2)

def write_trailer(out):
    trailer_name = b"TRAILER!!!\x00"
    namesize = len(trailer_name)  # 11
    pad1 = (4 - ((110 + namesize) % 4)) % 4  # 3
    trailer_hdr = (
        f"070701"
        f"{0:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{1:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{0:08x}"
        f"{namesize:08x}"
        f"{0:08x}"
    ).encode("ascii")

    out.write(trailer_hdr)
    out.write(trailer_name)
    if pad1:
        out.write(b"\x00" * pad1)

    # Pad total archive to 512-byte boundary
    pad_final = (512 - (out.tell() % 512)) % 512
    if pad_final:
        out.write(b"\x00" * pad_final)

def write_cpio_archive(source_dir, output_path):
    source_dir = os.path.abspath(source_dir)
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    temp_output = output_path + ".tmp"
    ino = 1

    with open(temp_output, "wb") as out:
        if os.path.isdir(source_dir):
            for root, dirs, files in os.walk(source_dir):
                dirs.sort()
                files.sort()
                rel_dir = os.path.relpath(root, source_dir)
                if rel_dir != ".":
                    arcname = normalize_arcname(rel_dir)
                    if arcname:
                        write_entry(out, arcname, 0o040755, b"", ino)
                        ino += 1

                for fname in files:
                    fpath = os.path.join(root, fname)
                    rel_fpath = os.path.relpath(fpath, source_dir)
                    arcname = normalize_arcname(rel_fpath)
                    if not arcname:
                        continue
                    try:
                        with open(fpath, "rb") as fp:
                            data = fp.read()
                    except OSError:
                        data = b""
                    mode = determine_mode(fpath, arcname, is_dir=False)
                    write_entry(out, arcname, mode, data, ino)
                    ino += 1

        write_trailer(out)

    os.replace(temp_output, output_path)

def write_cpio_from_stdin(output_path):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    temp_output = output_path + ".tmp"
    ino = 1

    with open(temp_output, "wb") as out:
        for line in sys.stdin:
            path = line.strip()
            if not path:
                continue
            arcname = normalize_arcname(path)
            if not arcname or arcname == ".":
                continue
            is_dir = os.path.isdir(path)
            if is_dir:
                write_entry(out, arcname, 0o040755, b"", ino)
                ino += 1
            elif os.path.isfile(path):
                try:
                    with open(path, "rb") as fp:
                        data = fp.read()
                except OSError:
                    data = b""
                mode = determine_mode(path, arcname, is_dir=False)
                write_entry(out, arcname, mode, data, ino)
                ino += 1

        write_trailer(out)

    os.replace(temp_output, output_path)

def main():
    if len(sys.argv) < 3:
        if len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help"):
            print(f"Usage: {sys.argv[0]} <source_dir> <output_cpio_path>")
            sys.exit(0)
        print(f"Usage: {sys.argv[0]} <source_dir> <output_cpio_path>", file=sys.stderr)
        sys.exit(1)

    if sys.argv[1] == "--stdin":
        output_cpio = sys.argv[2]
        write_cpio_from_stdin(output_cpio)
    else:
        source_dir = sys.argv[1]
        output_cpio = sys.argv[2]
        write_cpio_archive(source_dir, output_cpio)

if __name__ == "__main__":
    main()
