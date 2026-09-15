#!/usr/bin/env python3
"""Reference renderer mirroring read_win.c's classify/apply_style/blit_cell/
draw_text exactly, used to visually verify HELP.TXT edits without needing
Wine. Renders each logical line of a help-text byte buffer using AXV.FON."""
import os, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

CELLW, CELLH = 8, 19
COLS, ROWS = 80, 24
WIN_W, WIN_H = COLS*CELLW, ROWS*CELLH

C_TERM, C_SWAL, C_STYLE, C_COMB, C_TAB = 1,2,4,8,16

cls_lo = [2,2,4,2,2,4,2,2, 0,16,1,0,0,1,4,4, 0,0,4,4,4,4,4,4, 0,0,1,2,2,2,2,2]
cls_hi = [8,0,0,8,8,8,8,8,8,8,8, 0,0,0,0,0,0,0,0,0,0,0, 8,8,8,8,8,8,8,8]  # 0xD1..0xEE

def classify(b):
    if b <= 0x1F:
        return cls_lo[b]
    if 0xD1 <= b <= 0xEE:
        return cls_hi[b-0xD1]
    return 0

stx = [0,0,0x01,0,0,0x02,0,0,0,0,0,0,0,0,0x10,0x20,
       0,0,0x0C,0x08,0x20,0x40,0x10,0x40]

font = open(os.path.join(HERE, '..', 'dos', 'AXV.FON'), 'rb').read()

def glyph(ch):
    return font[ch*CELLH:(ch+1)*CELLH]

def apply_style(cell, style):
    out = bytearray(cell)
    if style & 0x01:
        for r in range(CELLH):
            out[r] |= (cell[r] >> 1) & 0xFF
    if style & 0x40:
        tmp = bytes(out)
        for r in range(CELLH):
            shift = 2 if r < 4 else (1 if r < 12 else 0)
            out[r] = tmp[r] >> shift
    if style & 0x10:
        tmp = bytes(out)
        for r in range(CELLH-1, 2, -1):
            out[r] = tmp[r-3]
        out[0]=out[1]=out[2]=0
    if style & 0x20:
        tmp = bytes(out)
        for r in range(0, CELLH-5):
            out[r] = tmp[r+5]
        for r in range(CELLH-5, CELLH):
            out[r] = 0
    if style & 0x08:
        if cell[17] == 0:
            out[17] = 0xFF
            if style & 0x04:
                if cell[18] == 0:
                    out[18] = 0xFF
    return bytes(out)

def blit_cell(px, col, row_px_y, cell, wide):
    x0 = col*CELLW
    for r in range(CELLH):
        b = cell[r]
        y = row_px_y + r
        if y < 0 or y >= WIN_H:
            continue
        for bit in range(8):
            on = (b >> (7-bit)) & 1
            if not wide:
                x = x0+bit
                if 0 <= x < WIN_W:
                    px[x,y] = (192,192,192) if on else (16,16,16)
            else:
                for xx in (x0+bit*2, x0+bit*2+1):
                    if 0 <= xx < WIN_W:
                        px[xx,y] = (192,192,192) if on else (16,16,16)

def draw_text(px, row_px_y, buf):
    style = 0
    cur_col = 0
    cell = None
    pending_wide = 0
    pending_col = -1
    for raw in buf:
        ch = raw
        cls = classify(ch)
        if cls & C_TERM:
            break
        if cls & C_STYLE:
            al = stx[ch] if ch <= 0x17 else 0
            if al & 0x30:
                style &= (~(al ^ 0x30)) & 0xFF
            style ^= al
            continue
        if cls & C_SWAL:
            continue
        if cls & C_COMB and cell is not None:
            mg = glyph(ch)
            cell = bytes((cell[r] | mg[r]) & 0xFF for r in range(CELLH))
            pending_wide = 1 if (style & 0x02) else 0
            styled = apply_style(cell, style)
            scr = pending_col
            if 0 <= scr < COLS:
                blit_cell(px, scr, row_px_y, styled, pending_wide)
            continue
        if cls & C_TAB:
            for k in range(8):
                cell = glyph(0x20)
                pending_col = cur_col
                pending_wide = 1 if (style & 0x02) else 0
                styled = apply_style(cell, style)
                scr = pending_col
                if 0 <= scr < COLS:
                    blit_cell(px, scr, row_px_y, styled, pending_wide)
                cur_col += 2 if pending_wide else 1
            continue
        cell = glyph(ch)
        pending_col = cur_col
        pending_wide = 1 if (style & 0x02) else 0
        styled = apply_style(cell, style)
        scr = pending_col
        if 0 <= scr < COLS:
            blit_cell(px, scr, row_px_y, styled, pending_wide)
        cur_col += 2 if pending_wide else 1

def render(data, out_path, max_rows=24):
    # split into logical lines like build_lines (CR/LF only for this test; ^Z stops)
    lines = []
    start = 0
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0x1A:
            lines.append(data[start:i])
            break
        if b in (0x0D, 0x0A):
            lines.append(data[start:i])
            if b == 0x0D and i+1 < len(data) and data[i+1] == 0x0A:
                i += 1
            i += 1
            start = i
            continue
        i += 1
    else:
        lines.append(data[start:])

    img = Image.new('RGB', (WIN_W, WIN_H), (16,16,16))
    px = img.load()
    for row, ln in enumerate(lines[:max_rows]):
        draw_text(px, row*CELLH, ln)
    img.save(out_path)
    print('rendered', len(lines), 'lines ->', out_path)

if __name__ == '__main__':
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'HELP_LINUX.TXT')
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'help_preview.png')
    data = open(src, 'rb').read()
    render(data, out)
