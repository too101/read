#!/usr/bin/env python3
"""Build READ.COM.

1. packs AXV.FON + HELP.TXT (cut at the first 00/1A byte) into packed.bin
   with a tiny run-length code (00 <len> <byte> = run, anything else = literal)
2. assembles read.asm with NASM
3. strips the 0x100h pad (NASM 3.x ignores 'org' in -f bin mode)

Requires NASM in PATH (or set the NASM environment variable to its path).
Output: output/read.com (the "output" folder is created next to this
script / read.asm if it doesn't exist yet)
"""
import os
import subprocess
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)) or ".")
OUT_DIR = "output"
os.makedirs(OUT_DIR, exist_ok=True)

# ---- 1. pack font + help --------------------------------------------------
font = open("AXV.FON", "rb").read()
assert len(font) == 256 * 19, "AXV.FON must be 256 glyphs x 19 rows"
help_ = open("HELP.TXT", "rb").read()
cut = [i for i in (help_.find(b"\x00"), help_.find(b"\x1a")) if i >= 0]
if cut:
    help_ = help_[:min(cut)]
help_ += b"\x00"                       # blob terminator

def rle(d):
    out = bytearray()
    i = 0
    while i < len(d):
        j = i
        while j < len(d) and d[j] == d[i] and j - i < 255:
            j += 1
        n = j - i
        if n >= 3 or d[i] == 0:
            out += bytes((0, n, d[i]))
            i = j
        else:
            out.append(d[i])
            i += 1
    return bytes(out)

packed = rle(font + help_)
open("packed.bin", "wb").write(packed)
open("packed.inc", "w").write("FONT_LEN equ %d\nHELP_LEN equ %d\n" % (len(font), len(help_)))
print("packed font+help: %d -> %d bytes" % (len(font) + len(help_), len(packed)))

# ---- 2. assemble ----------------------------------------------------------
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

# ---- 3. strip the pad -----------------------------------------------------
data = open("read_raw.com", "rb").read()
if data[:0x100] != bytes(0x100) or data[0x100] != 0xFC:
    print("UNEXPECTED: first 0x100 bytes are not zero-padding or 0x100 is not 'cld'")
    sys.exit(1)
final = data[0x100:]
out_path = os.path.join(OUT_DIR, "read.com")
open(out_path, "wb").write(final)
os.remove("read_raw.com")
print("%s size=%d (0x%X)" % (out_path, len(final), len(final)))
