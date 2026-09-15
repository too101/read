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
