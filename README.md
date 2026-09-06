# READ.COM — Thai text reader for DOS (optimized)

Full-screen Thai text viewer written in 8086 assembly (NASM, `.COM`).
Runs on CGA / EGA / VGA / Hercules, direct VRAM rendering, AXV 8×19 Thai font
with WordStar-style inline attributes (bold, double-width, italic, underline,
double underline, super/subscript), KU/TIS-620 auto-detect, built-in help.

This is a size- and speed-optimized rewrite of the original `read.asm`. It is
**pixel-for-pixel identical** to the original on real text, is **~52% smaller**,
runs **~2.1–2.7× fewer cycles at startup and up to ~4.7× fewer per keypress**,
and fixes several latent rendering bugs (see *Correctness & bug fixes* below).

## Files

| File | Purpose |
|---|---|
| `read.asm` | the whole program |
| `STRS.INC` | strings + KU→TIS table label |
| `KU.INC` | KU → TIS-620 translation table |
| `STATUS.INC` | status bar labels |
| `AXV.FON` | 8×19 Thai font, 256 glyphs (binary, packed at build) |
| `HELP.TXT` | built-in help text (TIS-620 + style codes, packed at build) |
| `build_read.py` | build script (packs data, runs NASM, strips the pad) |

## Build

Requires [NASM](https://nasm.us/) (2.x or 3.x).

```
python build_read.py
```

The script first run-length packs `AXV.FON` + `HELP.TXT` into `packed.bin`
(regenerated each build), assembles `read.asm`, and strips the 0x100h pad that
NASM 3.x emits because it ignores `org` in `-f bin` mode. Output: `read.com`.

## Run

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

## Results

Measured against the original build (`read_orig.com`, 15,349 bytes):

| Metric | Original | Optimized | Improvement |
|---|---:|---:|---:|
| Binary size | 15,349 B | 7,525 B | **51.0% smaller (2.04×)** |
| Startup + first draw (cycles) | ~6.0–7.9 M | ~2.2–3.3 M | **~2.4–2.7× faster** |
| Redraw per keypress (cycles) | ~1.3–2.1 M | ~0.36–0.89 M | **~2.3–4.7× faster** |

Cycle counts are from an 8086 timing model over an instruction-accurate
emulator (Unicorn), averaged across the help page and mixed Thai/TIS/KU
content in every video mode.

## How it was made faster and smaller

- **256-entry class/translate table** (`trc`): one table lookup replaces the
  long chains of `cmp`/`je` that classified every byte (terminator, style
  toggle, combining mark, swallowed control) and applied KU→TIS translation.
  Rebuilt only when the code page toggles.
- **Inline fast path for plain glyphs**: an un-styled base character in a
  planar mode (EGA/VGA) is blitted straight from the font to VRAM with an
  unrolled `movsb` loop and a running VRAM pointer — no cell copy, no style
  pass, no dispatch.
- **Scanline LUT everywhere** (`vrow_tab`): one address table serves every
  video mode (planar and interleaved), so the hot paths never multiply to find
  a scanline.
- **Word-wide fills and copies**: screen clears, the inverse status band, cell
  composition and VRAM scrolling move two bytes at a time.
- **Key-dispatch table** replaces the linear key `cmp` ladder.
- **Packed data**: the font and help text ship run-length compressed
  (6,164 → ~3,660 bytes) and are unpacked into the BSS at startup.
- **Zero-initialised data in BSS**: all scratch/state is reserved (not stored
  in the file) and cleared once at startup, cutting the on-disk image.
- **Dead code removed**: the never-reached tone-composition path, the unused
  cell-height flag, and other leftovers are gone.

## Correctness & bug fixes

Verified pixel-identical to a corrected reference across the built-in help, the
KU/TIS translation tables, every video mode, and ~600 randomly generated files
(mixed Thai bases, combining marks, all WordStar styles, long lines, odd line
terminators, empty/one-line/no-EOL files, missing files), scrolling with every
key.

Along the way the rewrite also fixes latent bugs present in the original:

1. **Status bar corruption while scrolling.** When the visible line-range grew
   a digit (e.g. `R:1-24` → `R:11-34` at line 11), the original's byte-by-byte
   shadow-diff misaligned and repainted the *filename* columns with the wrong
   glyphs — the doubled/garbled `\cw\CWi6.DOC` you could see when scrolling.
   The rewrite repaints the digit columns only when the digit count is
   unchanged, and does a clean full repaint otherwise.
2. **Stale `exp_prev` after an expanded glyph**, which mis-placed a following
   combining mark by one column.
3. **Partial VRAM scroll** now redraws *all* newly-exposed rows (the original
   redrew only one), so fast multi-line scrolls never leave stale rows.
4. **`cur_col` no longer wraps** past 255 on pathological >255-column lines
   (which drew stray marks at column 0).
5. Minor last-column / wide-glyph wrap guards and `ESC`-stripping consistency
   between the loader and the renderer.
6. **Embedded `00` bytes no longer truncate the file.** The original treated
   any literal `00` byte inside the file's content as end-of-text — both when
   counting lines and when drawing them — so a real-world document that uses
   `00` bytes as filler glyphs (e.g. a box-drawing table row) got cut off far
   short of its real end. `00` is now just another swallowed control byte;
   only `0D`/`0A` end a line, `1A` (`^Z`) keeps its conventional end-of-file
   meaning, and a single recorded "true end of loaded text" position (set once
   by the loader) is what actually stops scanning/drawing — not the value of
   any particular byte.
7. **`/t` selftest no longer waits 15 seconds.** It now shows its result and
   returns to DOS as soon as any key is pressed.
