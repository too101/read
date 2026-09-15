# READ — a Thai-language text reader (TIS-620)

*[อ่านเป็นภาษาไทย](README.md)*

A full-screen text viewer for Thai-language text files. Supports TIS-620
encoding, combining-mark composition of vowels/tone marks over base
consonants, and WordStar-style inline character attributes (bold, italic,
underline, etc.). Originally written as pure x86 assembly for DOS, later
ported to Windows and Linux while keeping the core logic (byte
classification, KU/TIS code conversion, glyph composition) identical —
only the platform windowing layer differs.

Three ports live in this repository:

| Folder | Platform | Written in | Status |
|---|---|---|---|
| [`dos/`](dos) | MS-DOS | pure x86 asm (NASM) | in real use for years, most thoroughly tested |
| [`windows/`](windows) | Windows (Win32 GUI) | pure x86 asm (NASM, no CRT) | builds cleanly, verified statically (no Wine available to test-run in this environment) |
| [`linux/`](linux) | Linux (X11/Xlib) | C | builds cleanly and confirmed with real screenshots (Xvfb) |

Each folder has its own README with build/usage instructions and
platform-specific technical detail.

## Getting started

Go to the folder for the platform you want and see its README — quick
summary:

```
# DOS (or DOSBox)
cd dos && python3 build_read.py && output\read.com [file]

# Windows
cd windows && build.bat && read.exe [file]

# Linux
cd linux && ./build.sh && ./read [file]
```

No filename = shows the built-in help page. Basic controls are the same
across all three ports: arrow keys/PgUp/PgDn/Home/End to scroll,
`C` to toggle KU/TIS encoding, `F1` to open/close the built-in help
page, `Q`/Esc to quit.

Both the Windows and Linux ports support a **resizable window** — drag to
resize and the number of columns/rows shown adjusts to the actual size
(see each port's own README for detail).

## Can `read` open genuine WordStar files?

Short answer: no, not the file format produced by the real WordStar
word processor — but yes to the WordStar-*style* inline attribute codes
that Thai word processors of that era (CW and RW) used, which is what
`read` (and its ancestor, `TREAD`, per [`dos/STORY.md`](dos/STORY.md))
was actually built to display.

What `read` supports: a fixed set of single-byte control codes embedded
directly in otherwise plain TIS-620/KU text —
`0x02`/`0x05`/`0x0E`/`0x0F`/`0x12`/`0x13`/`0x14`/`0x15`/`0x16`/`0x17` —
toggling bold, double-width, italic (both the CW and the RW italic code,
since the two programs didn't agree on one), single/double underline,
and superscript/subscript, exactly as CW/RW documents wrote them. This
is the "WordStar-style attributes" referenced throughout the docs — it's
the CW/RW convention, not a reimplementation of WordStar's own file
format from scratch.

What `read` does **not** support, and structurally cannot: a genuine
document written by the actual WordStar software sets the high bit
(bit 7) on certain ASCII bytes as part of its own word-wrap bookkeeping
(marking the end of a soft-wrapped line, soft hyphens, and similar) —
a convention baked into plain 7-bit English text. TIS-620 (and KU)
Thai encoding already uses the high bit for every real Thai character
byte (the whole `0xA1`–`0xFE` range and the KU equivalents), so there is
no way to tell a genuine WordStar soft-wrap marker apart from a real
Thai character byte — they occupy the exact same bit. `read` has never
tried to parse that convention, and neither did `TREAD` before it. On
top of that, real WordStar documents can carry a file-format header and
plain-text "dot command" lines (`.pl`, `.bp`, `.ul`, ...) for page
layout, none of which `read` parses — they would just show up as
literal text.

In short: if the file actually came out of CW, RW, or `read`/`TREAD`
itself, it'll display correctly. A `.WS` document written by real
WordStar for English text is not something this format was ever meant
to open.

## More documentation

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — a detailed optimization report
  for the DOS port (binary size reduction, instruction-count reduction,
  techniques used)
- [`dos/READ_TECHNICAL.md`](dos/READ_TECHNICAL.md) — the full technical
  writeup of the DOS port: architecture, memory map, test system, bugs
  found along the way
- [`dos/STORY.md`](dos/STORY.md) — the project's origin story

## Screenshot

![screenshot](dos/screenshot.png)

## License

[MIT](LICENSE)
