@echo off
REM Build read.exe from pure x86 assembly (no C, no CRT) on Windows.
REM
REM Needs two tools on PATH:
REM   1) NASM          - https://www.nasm.us/  (assembler)
REM   2) MinGW-w64 32-bit (i686) - https://winlibs.com/  (only used for its
REM      linker `ld.exe` and the kernel32/user32/gdi32 import libraries -
REM      no C compiler or CRT is invoked, the .exe has zero CRT dependency)
REM   Pick the "i686" / "Win32" build from winlibs.com, NOT the x86_64 one,
REM   since this assembles a 32-bit executable.

if not exist output mkdir output

nasm -f win32 -Isrc\ src\read_win.asm -o output\read_win.o
if %ERRORLEVEL% NEQ 0 (
    echo Assemble failed
    exit /b 1
)

ld -e _start --subsystem windows -o output\read.exe output\read_win.o -lkernel32 -luser32 -lgdi32
if %ERRORLEVEL% NEQ 0 (
    echo Link failed
    exit /b 1
)

strip output\read.exe
echo Built output\read.exe
