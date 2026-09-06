# READ.COM — Thai text reader for DOS

Full-screen Thai text viewer written in 8086 assembly (NASM, `.COM`).
Runs on CGA / EGA / VGA / Hercules, direct VRAM rendering, AXV 8×19 Thai font
with WordStar-style inline attributes (bold, double-width, italic, underline,
double underline, super/subscript), KU/TIS-620 auto-detect, built-in help.

## Files

| File | Purpose |
|---|---|
| `read.asm` | the whole program (~2,900 lines) |
| `STRS.INC` | strings |
| `KU.INC` | KU → TIS-620 translation table |
| `STATUS.INC` | status bar labels |
| `AXV.FON` | 8×19 Thai font, 256 glyphs (binary, incbin) |
| `HELP.TXT` | built-in help text (TIS-620 + style codes, incbin) |
| `build_read.py` | build script (Python 3) |

## Build

Requires [NASM](https://nasm.us/) (2.x or 3.x).

```
python build_read.py
```

or assemble by hand:

```
nasm -f bin read.asm -o read_raw.com
python -c "open('read.com','wb').write(open('read_raw.com','rb').read()[0x100:])"
```

(The source pads 0x100h zero bytes at the start because NASM 3.x ignores
`org` in `-f bin` mode; the script strips them so every label equals the
real DOS load address.)

## Run

Copy `read.com` anywhere DOS can reach, then:

```
READ filename            autodetect video card
READ filename /v|/e|/c|/h   force VGA / EGA / CGA / Hercules
READ /t                  selftest
```

## Keys

```
Up/Dn        one line          PgUp/PgDn or Space/BS  one page
Home/End     top/bottom        Left/Right             8 columns
c            KU <-> TIS        r / R                  full screen redraw
q or Esc     quit              F1                     built-in help
```
