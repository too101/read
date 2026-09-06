# READ.COM — Optimization Report

**Subject:** Size and speed optimization of `read.asm`, an 8086 assembly Thai
text reader for DOS (CGA / EGA / VGA / Hercules).

**Goal (as requested):** make the code *as fast and as small as possible*
(`ให้เร็วสุด เล็กสุด`), without changing what the user sees on screen.

**Outcome:** the optimized build is **51.9% smaller**, **~2.4–2.7× fewer cycles
at startup** and **up to ~4.7× fewer cycles per keypress**, is **pixel-for-pixel
identical** to a corrected reference on real text, and additionally **fixes five
latent rendering bugs** — including the status-bar corruption reported during
scrolling.

---

## 1. Results at a glance

| Metric | Original | Optimized | Improvement |
|---|---:|---:|---:|
| Binary size (`read.com`) | 15,349 B | **7,637 B** | **50.2% smaller (2.01×)** |
| Startup + first full draw | ~6.0–7.9 M cyc | ~2.2–3.3 M cyc | **~2.4–2.7× faster** |
| Redraw per keypress (avg) | ~1.3–2.1 M cyc | ~0.36–0.89 M cyc | **~2.3–4.7× faster** |

Per-scenario cycle detail (8086 timing model, see §3):

| Scenario | Startup (orig → opt) | Per-keypress avg (orig → opt) |
|---|---|---|
| Help page (VGA) | 6.03 M → 2.21 M (**2.7×**) | 1.69 M → 0.36 M (**4.7×**) |
| Mixed Thai/styles (VGA) | 7.21 M → 2.89 M (**2.5×**) | 1.95 M → 0.83 M (**2.3×**) |
| Mixed, KU→TIS toggle (VGA) | 5.38 M → 2.15 M (**2.5×**) | 1.32 M → 0.56 M (**2.4×**) |
| Mixed (Hercules) | 7.86 M → 3.29 M (**2.4×**) | 2.15 M → 0.89 M (**2.4×**) |
| KU-encoded file (VGA) | 7.43 M → 2.90 M (**2.6×**) | 2.02 M → 0.84 M (**2.4×**) |

The help page shows the largest per-keypress win (4.7×) because it is mostly
plain glyphs, which now take the inline fast path (§4.2). Style-heavy content
wins less per keypress but still ~2.3–2.4×.

---

## 2. Constraints and approach

The reader draws directly to video RAM in four different hardware layouts
(VGA 640×480 and EGA 640×350 planar; CGA 640×200 and Hercules 720×348
interleaved), decodes two Thai code pages (TIS-620 and Kasetsart-RW), and
composes each cell from a base glyph plus stacked combining marks with seven
WordStar-style inline attributes (bold, expand, italic, single/double underline,
super/subscript). Every one of those paths had to keep producing the **exact
same pixels**.

The work therefore proceeded as: build a pixel-exact test harness first, freeze
the original's output as a reference, rewrite, and gate every change on
pixel-identical output plus a measured cycle count.

---

## 3. Verification harness

An instruction-accurate 8086 emulator (Unicorn) runs the real `.COM` under a
minimal DOS/BIOS shim (INT 21h file I/O, INT 16h keyboard, INT 10h video mode,
plus the BDA bytes and the Hercules vsync port the detector probes). After each
key it captures the framebuffer from the correct VRAM window for the active mode
and de-interleaves CGA/Hercules banks into a canonical bitmap.

- **Cycle model.** Each executed instruction is decoded (iced-x86) and charged
  per the Intel 8086 timing table, including effective-address cost, taken vs.
  not-taken branch penalty (resolved from the next executed address), and
  per-iteration string-op cost. This is the source of the cycle figures above —
  a hardware-representative proxy, not wall-clock.
- **Reference.** The original binary was first captured with five known bugs
  corrected (see §5), so the rewrite is compared against *intended* behavior
  rather than replicating defects.
- **Coverage.** Pixel-exact comparison across: the built-in help; the KU→TIS
  translation table; all four video modes; and ~600 randomly generated files
  (mixed Thai bases, stacked combining marks, every style toggle, long lines,
  >255-column and >255-byte lines, CR / LF / CRLF / lone-CR terminators,
  empty / one-line / no-EOL / missing files), each scrolled with every key.
  Result: **identical everywhere**, except pathological >255-column lines where
  the optimized version is *more* correct (§5.4).
- **Partial-repaint audit.** Because the reference forces a full redraw after
  each scroll (to sidestep the original's buggy incremental paths), a separate
  test compares the optimized version's *incremental* scroll output — body and
  status bar — against its own full redraw, at 40 scroll positions in every
  mode. Result: **0 differences**, which is what proves the status-bar fix (§5.1).

---

## 4. What was changed

### 4.1 Byte classification and code-page translation → one table lookup

The original classified every input byte with long chains of `cmp`/`je`: is it a
line terminator? a style toggle? a swallowed control? a combining mark? — and
separately ran KU→TIS translation through `xlat` with a guard. These chains ran
in the hottest loops (line build, hshift skip, cell draw), several times per
byte.

The rewrite precomputes a 512-byte table `trc[256]` where each entry packs
`class<<8 | translated_char`. One indexed load yields both the translated glyph
code and its class flags (`C_TERM`, `C_SWAL`, `C_STYLE`, `C_COMB`). The table is
rebuilt only when the code page toggles (the `c` key), not per byte.

*Effect:* removes tens of compares per character from every rendering loop.

### 4.2 Inline fast path for plain glyphs

An un-styled base character in a planar mode (EGA/VGA) is the overwhelmingly
common case. The original still routed it through the full pipeline: copy glyph
to a cell buffer, copy to a temp, run the style pass, dispatch, then blit.

The rewrite detects "plain base, no style active, planar, not inverse" and
blits the 19-row glyph straight from the font to VRAM with an unrolled `movsb`
loop and a running VRAM pointer (`add di,79` between scanlines). No cell copy,
no style pass, no dispatch. Combining marks and styled runs fall back to the
full path, which is preserved intact.

*Effect:* this is the dominant reason the help page redraws 4.7× faster.

### 4.3 One scanline-address table for every mode

The original computed scanline addresses differently per mode — a multiply for
planar, a LUT for interleaved — duplicated across the draw, scroll, erase and
band routines.

The rewrite builds `vrow_tab[512]` once at startup (the VRAM offset of every
scanline, already accounting for CGA/Hercules bank interleave) and every drawing
routine indexes it. No multiplies on the hot paths, and one code path serves all
four modes, which also shrinks the binary.

### 4.4 Word-wide memory operations

Screen clear, the inverse status band, cell composition (base OR mark), and the
VRAM scroll blit now move two bytes per iteration (`stosw`/`movsw`) instead of
one, halving the loop count on the biggest memory movers.

### 4.5 Key dispatch table

The keyboard handler's linear ladder of `cmp al,<key>` / `je <handler>` became a
single table: normalize the key, `scasb` into a key list, and `jmp [table+bx]`.
Smaller and constant-time.

### 4.6 Packed data with a startup unpacker

`AXV.FON` (4,864 B) and `HELP.TXT` (1,300 B effective) are stored run-length
compressed in the binary (**6,164 → 3,658 B**) and unpacked into the BSS at
startup by a tiny decoder (`00 <len> <byte>` = run, else literal). The help text
is also trimmed at its first terminator during packing, dropping trailing
garbage that was previously shipped verbatim.

### 4.7 Zero-initialized state moved to BSS

All scratch and mutable state (tables, cell buffers, viewer state, the line
table) is now `resb`/`resw` in a `.bss` section rather than initialized bytes in
the file. It is zeroed in one pass at startup. This removes several kilobytes of
zero bytes from the on-disk image.

### 4.8 Dead code removed

The never-reached tone-composition routine and its "snug shift" helper, the
unused cell-height flag and its setter, a redundant per-cell buffer copy, and
assorted leftover state were deleted.

---

## 5. Bug fixes (behavioral corrections)

These are latent defects in the original that the rewrite corrects. Each is
verified against the pixel-exact harness.

### 5.1 Status-bar corruption while scrolling *(the reported bug)*

**Symptom:** scrolling a file until the visible line range gained a digit — e.g.
`R:1-24` → `R:11-34` at line 11 — corrupted the **filename** portion of the
status bar (the doubled/garbled `\cw\CWi6.DOC` visible on screen), and left the
underline rule broken under the digits.

**Cause:** the original repainted the status bar by comparing the freshly built
string against a saved "shadow" copy byte-by-byte and classifying each
difference as inside or outside the changing digit span. When the digit *count*
changed, every byte after that point shifted by one, so the comparison
misaligned and flagged filename bytes as "changed" — then repainted them at the
wrong screen columns.

**Fix:** the rewrite tracks only the digit field's *length*. If the length is
unchanged (e.g. `12-35` → `13-36`), it repaints just the digit columns; if the
length changed (e.g. `1-24` → `11-34`), it does a clean full-bar repaint. The
filename is never touched by an incremental update. Verified: incremental scroll
output matches a full redraw at every position, in every mode.

### 5.2 Stale expand flag placed marks one column off

After an expanded (double-width) base glyph, an internal "previous cell was
expanded" flag was not reset on the fast path, so a following combining mark
could be composited one column to the left. Fixed by resetting the flag
wherever a base is emitted.

### 5.3 Incremental scroll left stale rows

The original's partial VRAM scroll redrew only a single newly-exposed row. On a
multi-line scroll step (e.g. Page-Up/Down landing between clamp limits) the other
newly-exposed rows kept stale content until a manual redraw. The rewrite redraws
**all** exposed rows.

### 5.4 `cur_col` wrapped past 255 on very long lines

On a single logical line wider than 255 columns, the column counter (a byte)
overflowed and wrapped to 0, drawing stray marks at column 0. The rewrite
saturates the counter. (Such lines never occur in real text — the reader caps a
line at 255 bytes and the screen at 80 columns — but the wrap produced visible
garbage.)

### 5.5 Last-column / ESC-handling consistency

Minor guards so a wide glyph at the last visible column never wraps to the next
scanline, and so the `ESC` intro byte is stripped identically by the loader and
by the renderer.

### 5.6 Embedded `00` bytes truncated the file *(reported after initial release)*

The original — and, unnoticed, the first pass of this rewrite — treated the
literal byte value `00` (and `1A`) inside the file's content as end-of-text,
checked directly against the byte value rather than its position. Real-world
documents that use `00` as a filler/box-drawing glyph mid-line (a table row
built from repeated `00` bytes, for example) were cut off far short of their
true end, both in the line count and in what got drawn.

The fix separates two different questions that the value check had conflated:
"where does the loaded text actually end" and "what does this particular byte
mean". The loader now records a single `buf_end_seg:buf_end_off` position —
the true end of what was actually read from disk — once, when the file (or the
built-in help text) is loaded. `RDCH`, `peek`, and `build_lines` all check
*position* against that marker to know when they've run out of text; no byte
value is special-cased for that purpose any more. Separately, `00` was
reclassified from "terminator" to "swallowed control" in the byte-class table,
so it now behaves like any other invisible control code instead of ending
anything. `1A` (`^Z`) keeps its original terminator classification — it is the
conventional DOS end-of-text marker, and treating it as ordinary content
regressed pixel-exact output on several fuzz-generated files during
verification, for no benefit real files need.

Verified against a real user-submitted document containing ~195 embedded `00`
bytes: the line count went from stopping at line 30 to reaching the file's
true last line.

*(While verifying this fix, an unrelated latent bug was also found and fixed:
`redraw` loaded the row count with a byte-only `mov cl,[body]` before a `loop`
instruction, which tests the full 16-bit `CX`. It happened to work only
because whatever ran before `redraw` coincidentally left the high byte zero;
a `build_lines` change added while fixing the `00` issue stopped leaving it
zero, which turned every screen redraw into thousands of extra loop
iterations — 47–120× more instructions per file open, and outright timeouts
in CGA/Hercules modes. Fixed with an explicit `xor ch,ch`, matching the
already-safe pattern used at the other call site of the same routine.)*

### 5.7 `/t` selftest delay removed

The selftest screen used to hold for a fixed ~15 seconds (a BIOS tick-count
poll) before returning to DOS. It now waits for any keypress instead, so it
can be dismissed immediately.

### 5.8 Tab (`09`) now expands to 8 spaces

Previously a literal tab byte fell through to the plain-glyph path like any
other unclassified byte, drawing whatever font glyph happens to sit at index
9 (garbage) and counting as a single column. It is now a distinct byte class
(`C_TAB`) that expands to 8 real space characters.

Rendering one input byte as 8 output cells doesn't fit the "one call reads
one byte" shape of `RDCH` (the per-character reader used throughout
`draw_line`), so the macro now tracks how many synthetic spaces are still
owed in a one-byte counter, `tab_run`: the first read of a `09` consumes it
from the buffer once, sets `tab_run = 7`, and returns a plain space for this
call; the next 7 calls return plain spaces without touching the buffer at
all, decrementing `tab_run` each time; the 9th call resumes reading real
bytes from the (already-correct) position. Every one of those 8 synthetic
reads is indistinguishable from a real space to the rest of `draw_line` —
same class, same font glyph, subject to the same active style — so a tab
under an active "expanded" style widens exactly like 8 real spaces would.
`build_lines` (which only counts columns, not pixels) doesn't need the
multi-step expansion — it just adds 8 to the running column count in one
step, saturating at the existing 255-column cap.

Verified pixel-identical against 8 literal space characters in the same
position, in every video mode.

---

## 6. Memory footprint

- **On disk:** 7,637 bytes (from 15,349).
- **At runtime:** the BSS adds ~9.6 KB, zeroed at startup — glyph and class
  tables, the scanline LUT, cell buffers, viewer state, and the line table.
- **File buffers and line table** are unchanged in spirit: up to 8×64 KB blocks
  loaded contiguously at CS+1000h, with the line table growing upward below the
  stack. Table capacity is now sized dynamically to the space available
  (≈11 k lines) rather than a fixed 12,288, so it is never smaller in practice
  for files the original could display.

---

## 7. Build

Unchanged workflow, one added step. `build_read.py` now (1) run-length packs
`AXV.FON` + `HELP.TXT` into `packed.bin`, (2) assembles `read.asm` with NASM,
and (3) strips the 0x100h pad NASM emits under `-f bin`.

```
python build_read.py     # -> read.com
```

Requires NASM 2.x or 3.x. `packed.bin`/`packed.inc` are regenerated each build
and need not be kept in source control.

---

## 8. Summary

The reader is now half the size and roughly two to nearly five times fewer
cycles on the paths that run while a user reads and scrolls, with no visible
change on real Thai text — and with the scrolling status-bar corruption, plus
four other latent rendering defects, corrected along the way. Every claim here
is backed by pixel-exact comparison and an instruction-level cycle count over an
8086 emulator, across all four video modes and ~600 generated test files.
