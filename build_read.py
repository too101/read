#!/usr/bin/env python3
"""Build READ.COM: assembles read.asm with NASM and strips the 0x100h pad.

Requires NASM in PATH (or set the NASM environment variable to its path).
Output: read.com (this is the DOS executable).
"""
import os
import subprocess
import sys

nasm = os.environ.get("NASM", "nasm")

r = subprocess.run([nasm, "-f", "bin", "read.asm", "-o", "read_raw.com"],
                   capture_output=True, text=True)
if r.stdout:
    print(r.stdout)
if r.stderr:
    print(r.stderr)
if r.returncode != 0:
    print("BUILD FAILED")
    sys.exit(1)

data = open("read_raw.com", "rb").read()
print("raw size=%d (0x%X)" % (len(data), len(data)))

# NASM 3.02 ignores 'org' in -f bin mode, so the source pads 0x100h zero
# bytes at the start; strip them so every label equals the real DOS load
# address (file byte 0 -> CS:0100).
if data[:0x100] != bytes(0x100) or data[0x100] != 0xFC:
    print("UNEXPECTED: first 0x100 bytes are not zero-padding or 0x100 is not 'cld'")
    sys.exit(1)

final = data[0x100:]
open("read.com", "wb").write(final)
print("read.com size=%d (0x%X)" % (len(final), len(final)))
