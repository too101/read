#!/usr/bin/env python3
"""Dev-time script that derives HELP_WIN.TXT from ../dos/HELP.TXT: adapts
the DOS help screen for the Windows ports (no CGA/Hercules/EGA/VGA mode
list, no /c /h /e /v /t command-line options -- read.exe takes none of
those; window is resizable, starting at 80x25). Preserves the box-drawing
bytes and the entire right (keys) column byte-for-byte -- only the
DOS-specific left-column text is replaced, padded to the exact same visible
columns (0/20/23/37/79) so the box stays aligned.

Not normally needed to re-run -- HELP_WIN.TXT is already checked into this
directory and is usually edited directly. Re-run this only if HELP.TXT's
key-bindings column changes upstream and HELP_WIN.TXT needs re-deriving
from scratch (and always re-check the result with render_help.py after).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from render_help import classify, C_TAB, C_SWAL, C_STYLE, C_COMB

SRC = os.path.join(HERE, '..', 'dos', 'HELP.TXT')
OUT = os.path.join(HERE, 'HELP_WIN.TXT')

BOLD, ITAL = 0x02, 0x17

def vwidth(b):
    """visible-column cost of a single raw byte, same rule as draw_text/build_lines"""
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
assert 0x1A in data
data = data[:data.index(0x1A)]  # drop the trailing ^Z + whatever follows it (dot-matrix codes) -- not part of the displayed help text

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

# ---- line 1: drop the CGA/Hercules/EGA/VGA mention ----
lines[1] = bytearray('Windows Port by too101 & ZCode & Claude Code'.encode('tis-620'))

# ---- line 5 (usage row): "READ file [option]" -> "read.exe file" ----
raw5 = bytes(lines[5])
div_col20_off = 28   # byte offset of the col-20 divider in the ORIGINAL line 5 (from the marker scan)
tail5 = raw5[div_col20_off:]  # keep byte-for-byte from the col-20 divider onward (key/description columns, untouched)
field1 = b' ' + bytes([BOLD]) + b'read.exe' + bytes([BOLD]) + b' ' + bytes([ITAL]) + 'ไฟล์'.encode('tis-620') + bytes([ITAL])
field1 = pad_to(field1, 19)
lines[5] = bytearray(raw5[:2] + field1) + bytearray(tail5)  # raw5[:2] = the two border bytes (1B 96)

# ---- rows 7-13 (options column) -> Windows-appropriate notes, incl. the
#      resizable-window feature (row 10) ----
new_field1_text = {
    7:  'ไม่มีตัวเลือก',
    8:  '',
    9:  'ขนาดเริ่มต้น',
    10: '80x25 คอลัมน์',
    11: 'ย่อ-ขยายได้',
    12: '',
    13: '',
}
div_col20_off_by_row = {7: 25, 8: 21, 9: 21, 10: 21, 11: 21, 12: 21, 13: 25}
for row, text in new_field1_text.items():
    raw = bytes(lines[row])
    off = div_col20_off_by_row[row]
    tail = raw[off:]
    field1 = b' ' + text.encode('tis-620')
    field1 = pad_to(field1, 19)
    lines[row] = bytearray(raw[:2] + field1) + bytearray(tail)

out = bytearray()
for idx, ln in enumerate(lines):
    out += ln
    if idx != len(lines) - 1:
        out += b'\r\n'
out += bytes([0x1A])  # keep the ^Z terminator (correctly respected by build_lines)

with open(OUT, 'wb') as f:
    f.write(out)
print('wrote', OUT, len(out), 'bytes')
