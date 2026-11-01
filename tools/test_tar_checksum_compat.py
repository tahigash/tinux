#!/usr/bin/env python3
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Empirical validation of USTAR 8-space checksum rule vs GNU tar 1.34

import os
import sys
import subprocess
import tempfile
import shutil

def run_test():
    tmpdir = tempfile.mkdtemp(prefix="tinux_tar_test_")
    try:
        # Step 1: Create sample files
        test_files = {
            "small.txt": b"Hello world 12345\n",
            "exact512.bin": bytes([i % 256 for i in range(512)]),
            "multisector.dat": bytes([i % 251 for i in range(2500)]),
            "empty.txt": b""
        }
        for name, data in test_files.items():
            with open(os.path.join(tmpdir, name), "wb") as f:
                f.write(data)

        # Step 2: Use host GNU tar to create a ustar archive
        gnu_tar_path = os.path.join(tmpdir, "gnu.tar")
        cmd = ["tar", "--format=ustar", "-cf", gnu_tar_path, "-C", tmpdir] + list(test_files.keys())
        res = subprocess.run(cmd, capture_output=True, text=True)
        assert res.returncode == 0, f"GNU tar creation failed: {res.stderr}"

        # Step 3: Inspect GNU tar's checksums
        with open(gnu_tar_path, "rb") as f:
            tar_data = f.read()

        print(f"[TEST] GNU tar archive size: {len(tar_data)} bytes")
        offset = 0
        file_idx = 0
        while offset + 512 <= len(tar_data):
            block = bytearray(tar_data[offset:offset+512])
            if all(b == 0 for b in block):
                print(f"[TEST] EOA zero block at offset {offset}")
                offset += 512
                continue

            magic = block[257:263]
            name = block[0:100].split(b'\0')[0].decode('ascii', errors='replace')
            raw_chksum = block[148:156]
            size_str = block[124:136].split(b'\0')[0].strip()
            size = int(size_str, 8) if size_str else 0

            # Algorithm: sum all 512 bytes treating 148..156 as 8 ASCII spaces (0x20)
            block_for_sum = bytearray(block)
            block_for_sum[148:156] = b' ' * 8
            computed_sum = sum(block_for_sum)

            # Check format of raw_chksum
            # In GNU tar, raw_chksum is usually 6 octal digits + NUL + space or 7 digits + NUL
            chksum_val = int(raw_chksum.strip(b'\x00 ').decode('ascii'), 8)

            print(f"[TEST] File: '{name}', size={size}, raw_chksum={raw_chksum!r}, computed_sum=0o{computed_sum:06o}")
            assert chksum_val == computed_sum, f"Checksum mismatch for {name}: {chksum_val} != {computed_sum}"
            print(f"  -> MATCH: GNU tar checksum {chksum_val:#o} == 8-space sum {computed_sum:#o}")

            data_sectors = (size + 511) // 512
            offset += 512 * (1 + data_sectors)
            file_idx += 1

        print(f"[PASS] All {file_idx} files in GNU tar matched the 8-space checksum rule exactly.\n")

        # Step 4: Now synthesize a tar archive using Tinux tarfs algorithm in Python
        # and test if GNU tar accepts, extracts, and validates it.
        tinux_tar_path = os.path.join(tmpdir, "tinux_synth.tar")
        synth_bytes = bytearray()

        for name, data in test_files.items():
            hdr = bytearray(512)
            # name [0..100]
            name_bytes = name.encode('ascii')
            hdr[0:len(name_bytes)] = name_bytes
            # mode [100..108]: 7 octal digits + NUL
            hdr[100:108] = f"{0o644:07o}\x00".encode('ascii')
            # uid [108..116]
            hdr[108:116] = b"0000000\x00"
            # gid [116..124]
            hdr[116:124] = b"0000000\x00"
            # size [124..136]: 11 octal digits + NUL
            hdr[124:136] = f"{len(data):011o}\x00".encode('ascii')
            # mtime [136..148]
            hdr[136:148] = b"00000000000\x00"
            # chksum placeholder: 8 spaces
            hdr[148:156] = b" " * 8
            # typeflag [156]
            hdr[156] = ord('0')
            # magic [257..263]
            hdr[257:263] = b"ustar\x00"
            # version [263..265]
            hdr[263:265] = b"00"
            # uname [265..270]
            hdr[265:270] = b"root\x00"
            # gname [297..302]
            hdr[297:302] = b"root\x00"

            # Compute sum over 512 bytes with 8 spaces
            hdr_sum = sum(hdr)
            # Format checksum as 6 octal digits + NUL + space
            chk_field = f"{hdr_sum:06o}\x00 ".encode('ascii')
            assert len(chk_field) == 8
            hdr[148:156] = chk_field

            synth_bytes.extend(hdr)

            # Data sectors padded to 512
            if len(data) > 0:
                pad_len = (512 - (len(data) % 512)) % 512
                synth_bytes.extend(data)
                synth_bytes.extend(b"\x00" * pad_len)

        # End of archive: 2 zero blocks (1024 bytes)
        synth_bytes.extend(b"\x00" * 1024)

        with open(tinux_tar_path, "wb") as f:
            f.write(synth_bytes)

        # Step 5: Verify with host GNU tar: tar -tvf
        res = subprocess.run(["tar", "-tvf", tinux_tar_path], capture_output=True, text=True)
        print("[TEST] GNU tar -tvf on Tinux-synthesized archive:")
        print(res.stdout)
        assert res.returncode == 0, f"GNU tar -tvf failed: {res.stderr}"
        assert not res.stderr, f"GNU tar printed warnings: {res.stderr}"

        # Step 6: Extract with GNU tar into a fresh directory and check content equality
        extract_dir = os.path.join(tmpdir, "extracted")
        os.makedirs(extract_dir, exist_ok=True)
        res = subprocess.run(["tar", "-xf", tinux_tar_path, "-C", extract_dir], capture_output=True, text=True)
        assert res.returncode == 0, f"GNU tar -xf failed: {res.stderr}"
        assert not res.stderr, f"GNU tar printed warnings during extraction: {res.stderr}"

        for name, original_data in test_files.items():
            extracted_path = os.path.join(extract_dir, name)
            assert os.path.isfile(extracted_path), f"Extracted file missing: {name}"
            with open(extracted_path, "rb") as f:
                extracted_data = f.read()
            assert extracted_data == original_data, f"Data mismatch for {name}: len {len(extracted_data)} != {len(original_data)}"
            print(f"[PASS] Extracted '{name}' verified bit-identical ({len(extracted_data)} bytes)")

        print("\n[SUCCESS] Host GNU tar 1.34 strictly and cleanly accepts Tinux USTAR 8-space checksum formatting!")
        return True
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

if __name__ == "__main__":
    if not run_test():
        sys.exit(1)
