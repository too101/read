#!/usr/bin/env python3
"""Dev-time script that derives HELP_LINUX.TXT from ../windows/HELP_WIN.TXT
(itself HELP.TXT adapted for Windows -- see ../windows/build_help_win.py):
swaps the two platform-specific bits (author/platform line, and the
executable name in the usage row) for Linux. Everything else -- the box
layout, key bindings, style demo, font credit, resizable-window notes --
is already platform-neutral and shared as-is.

Not normally needed to re-run -- HELP_LINUX.TXT is already checked into
this directory and is usually edited directly. Re-run this only if
HELP_WIN.TXT changes upstream and HELP_LINUX.TXT needs re-deriving from
scratch (and always re-check the result with render_help.py after).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from render_help import classify, C_TAB, C_SWAL, C_STYLE, C_COMB

SRC = os.path.join(HERE, '..', 'windows', 'HELP_WIN.TXT')
OUT = os.path.join(HERE, 'HELP_LINUX.TXT')

BOLD, ITAL = 0x02, 0x17

def vwidth(b):
    cls = classify(b)
    if cls & C_TAB:
        return 8
    if cls & (C_SWAL | C_STYLE | C_COMB):
        return 0
    return 1

def text_width(bs):
    return sum(vwidth(b) for b in bs)

def pad_to(bs, target_cols):
    w = text_width(bs)
    assert w <= target_cols, (bs, w, target_cols)
    return bs + b' ' * (target_cols - w)

data = open(SRC, 'rb').read()
if 0x1A in data:
    data = data[:data.index(0x1A)]

lines = []
start = 0
i = 0
while i < len(data):
    b = data[i]
    if b in (0x0D, 0x0A):
        lines.append(bytearray(data[start:i]))
        if b == 0x0D and i + 1 < len(data) and data[i+1] == 0x0A:
            i += 1
        i += 1
        start = i
        continue
    i += 1
lines.append(bytearray(data[start:]))

# ---- line 1: platform/author line ----
lines[1] = bytearray('Linux Port (X11) by too101 & ZCode & Claude Code'.encode('tis-620'))

# ---- line 5 (usage row): "read.exe file" -> "./read file", same column budget (19 cols, cols 1-19) ----
raw5 = bytes(lines[5])
div_col20_off = 26  # byte offset of the col-20 divider IN HELP_WIN.TXT's row 5 (found by
                     # locating the 0x96 divider bytes directly -- NOT the same offset as
                     # in the original DOS HELP.TXT, since "read.exe" padded differently)
tail5 = raw5[div_col20_off:]
field1 = b' ' + bytes([BOLD]) + b'./read' + bytes([BOLD]) + b' ' + bytes([ITAL]) + 'ไฟล์'.encode('tis-620') + bytes([ITAL])
field1 = pad_to(field1, 19)
lines[5] = bytearray(raw5[:2] + field1) + bytearray(tail5)

# rows 7-13 (options column) are already platform-neutral ("no options" /
# "starting size" / "80x25 columns" / "resizable") -- no change needed.

out = bytearray()
for idx, ln in enumerate(lines):
    out += ln
    if idx != len(lines) - 1:
        out += b'\r\n'
out += bytes([0x1A])

with open(OUT, 'wb') as f:
    f.write(out)
print('wrote', OUT, len(out), 'bytes')
