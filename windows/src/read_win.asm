; READ.exe for Windows -- pure x86 (32-bit) NASM/Win32 rewrite of read_win.c,
; which was itself a faithful Win32 GDI port of the DOS Thai text viewer
; (read.asm). This file is a line-by-line transliteration of the already
; battle-tested read_win.c (no libc/CRT at all -- only kernel32/user32/gdi32,
; the three DLLs present on every Windows install). Every function below is
; labelled with the C function it mirrors so it can be checked against
; read_win.c directly.
;
; Calling convention used THROUGHOUT this file, for both Win32 API calls and
; our own internal functions: stdcall-style -- caller pushes arguments in
; declared (left-to-right) order via the CALLn macros below (which reverse
; them into the correct push order automatically), callee cleans the stack
; with `ret N`. eax/ecx/edx are caller-saved (any call may clobber them);
; ebx/esi/edi/ebp are callee-saved (every function that uses them pushes/
; pops them, so they survive across ANY call, ours or the API's).
;
; Build: nasm -f win32 read_win.asm -o read_win.o
;        i686-w64-mingw32-ld read_win.o -o read.exe -e _start
;            --subsystem windows -lkernel32 -luser32 -lgdi32
; (see build.bat / README.md for the Windows-side equivalent)

BITS 32

; ---------------- layout constants (mirrors read_win.c) --------------------
; CELLW/CELLH stay true compile-time constants -- the bitmap font is always
; 8x19, resizing the window reveals more/fewer whole cells rather than
; scaling the glyphs (scaling would blur the pixel font). COLS/BODY/WIN_W/
; WIN_H used to be fixed too but are now runtime state (g_cols/g_body/
; g_win_w/g_win_h in .bss, initialized in _start) so the window can be
; resized -- see the WM_SIZE handler in WndProc and fb_create.
%define CELLW   8
%define CELLH   19
%define COLS_INIT 80
%define BODY_INIT 24
%define WIN_W_INIT 640
%define WIN_H_INIT 475
; minimum usable size, enforced both defensively after a resize and via
; WM_GETMINMAXINFO so the window manager itself won't let the user drag it
; smaller than this
%define MIN_COLS 20
%define MIN_BODY 3

%define C_TERM  0x01
%define C_SWAL  0x02
%define C_STYLE 0x04
%define C_COMB  0x08
%define C_TAB   0x10

%define COL_BG     0x00101010
%define COL_FG     0x00C0C0C0
%define COL_BAR_BG 0x00303030

%define WS_STYLE_SIZABLE 0x00CF0000  ; WS_OVERLAPPEDWINDOW (includes WS_THICKFRAME
                                     ; + WS_MAXIMIZEBOX, so the window can be
                                     ; dragged/maximized to resize -- see the
                                     ; WM_SIZE/WM_GETMINMAXINFO handlers below)
%define WS_VISIBLE      0x10000000

; ---------------- argument-pushing helper macros ---------------------------
; CALLn funcname, arg1, arg2, ..., argn  -- pushes args in reverse (so arg1
; ends up at [esp+4] after `call`, matching the callee's declared parameter
; order) then calls funcname. Use `dword [..]` explicitly for any memory
; operand argument (push needs the size spelled out); bare labels (string/
; struct addresses) and registers need no size prefix.
%macro CALL1 2
    push %2
    call %1
%endmacro
%macro CALL2 3
    push %3
    push %2
    call %1
%endmacro
%macro CALL3 4
    push %4
    push %3
    push %2
    call %1
%endmacro
%macro CALL4 5
    push %5
    push %4
    push %3
    push %2
    call %1
%endmacro
%macro CALL5 6
    push %6
    push %5
    push %4
    push %3
    push %2
    call %1
%endmacro
%macro CALL6 7
    push %7
    push %6
    push %5
    push %4
    push %3
    push %2
    call %1
%endmacro
%macro CALL7 8
    push %8
    push %7
    push %6
    push %5
    push %4
    push %3
    push %2
    call %1
%endmacro
%macro CALL9 10
    push %10
    push %9
    push %8
    push %7
    push %6
    push %5
    push %4
    push %3
    push %2
    call %1
%endmacro
%macro CALL12 13
    push %13
    push %12
    push %11
    push %10
    push %9
    push %8
    push %7
    push %6
    push %5
    push %4
    push %3
    push %2
    call %1
%endmacro

; ---------------- Win32 imports used -----------------------------------
extern _GetProcessHeap@0
extern _HeapAlloc@12
extern _HeapFree@12
extern _HeapReAlloc@16
extern _GetCommandLineA@0
extern _CreateFileA@28
extern _GetFileSize@8
extern _ReadFile@20
extern _CloseHandle@4
extern _GetModuleHandleA@4
extern _ExitProcess@4

extern _GetDC@4
extern _ReleaseDC@8
extern _BeginPaint@8
extern _EndPaint@8
extern _InvalidateRect@12
extern _PostQuitMessage@4
extern _DefWindowProcA@16
extern _LoadCursorA@8
extern _RegisterClassA@4
extern _AdjustWindowRect@12
extern _CreateWindowExA@48
extern _GetMessageA@16
extern _TranslateMessage@4
extern _DispatchMessageA@4
extern _MessageBoxA@16

extern _CreateDIBSection@24
extern _CreateCompatibleDC@4
extern _SelectObject@8
extern _BitBlt@36
extern _GetStockObject@4
extern _DeleteObject@4
extern _DeleteDC@4

global _start

; =========================================================================
section .data

; cls_lo: classes for raw bytes 00h-1Fh (same table as read.asm / read_win.c)
cls_lo:
    db 2,2,4,2,2,4,2,2
    db 0,0x10,1,0,0,1,4,4
    db 0,0,4,4,4,4,4,4
    db 0,0,1,2,2,2,2,2

; cls_hi: classes for TIS-620 combining marks D1h-EEh
cls_hi:
    db 8,0,0,8,8,8,8,8,8,8,8
    db 0,0,0,0,0,0,0,0,0,0,0
    db 8,8,8,8,8,8,8,8

; stx: style_reg xor masks per WordStar style code 00h-17h
stx:
    db 0,0,0x01,0,0,0x02,0,0,0,0,0,0,0,0,0x10,0x20
    db 0,0,0x0C,0x08,0x20,0x40,0x10,0x40

class_name_str:  db "READWINCLASS",0
title_str:       db "READ.COM for Windows",0
help_title_str:  db "READ.COM Help",0
nofile_str:      db "(no file)",0
ku_str:          db "KU",0
tis_str:         db "TIS",0
sep_c_str:       db "  C:",0
sep_r_str:       db "  R:",0
dash_str:        db "-",0
sep2_str:        db "  ",0
cannot_open_str: db "Cannot open file",0

%include "data.inc"

; =========================================================================
section .bss

g_heap:        resd 1
g_ku_mode:     resd 1
g_filebuf:     resd 1
g_filelen:     resd 1
g_fname:       resb 260

; LineTab { Line *lines; int nlines; int cap; int maxlen; } -- 4 dwords.
; offsets: lines=+0 nlines=+4 cap=+8 maxlen=+12. A Line entry is
; { const unsigned char *ptr; int len; } -- 8 bytes, ptr=+0 len=+4.
g_tab:         resd 4
g_help_tab:    resd 4
g_help_built:  resd 1

g_top:         resd 1
g_hshift:      resd 1
g_topmax:      resd 1
g_maxh:        resd 1
g_help_mode:   resd 1
g_sv_top:      resd 1
g_sv_hshift:   resd 1
g_sv_ku:       resd 1
g_cur:         resd 1

g_dib:         resd 1
g_px:          resd 1
g_memdc:       resd 1
g_bg_color:    resd 1     ; set to COL_BG explicitly at startup (see _start)

g_hwnd:        resd 1
g_hinstance:   resd 1

; layout state -- used to be fixed COLS/BODY/WIN_W/WIN_H constants; now
; runtime so the window can be resized (WM_SIZE recomputes these and
; recreates the DIB section at the new size; WM_GETMINMAXINFO stops the
; window manager going below MIN_COLS/MIN_BODY). Initialized in _start.
g_cols:        resd 1
g_body:        resd 1
g_win_w:       resd 1
g_win_h:       resd 1

wc_buf:        resb 40    ; WNDCLASSA
rect_buf:      resb 16    ; RECT
rect_w:        resd 1
rect_h:        resd 1
msg_buf:       resb 28    ; MSG
arg1_buf:      resb 512
read_bytes_scratch: resd 1
status_left_buf: resb 256
bmi:           resb 44    ; BITMAPINFO (header + 1 reserved RGBQUAD slot)

; =========================================================================
section .text

; unsigned char classify(unsigned char b) -- [ebp+8], returns class in eax
classify:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    and eax, 0xFF
    cmp eax, 0x1F
    ja .not_lo
    movzx eax, byte [cls_lo + eax]
    jmp .done
.not_lo:
    cmp eax, 0xD1
    jb .zero
    cmp eax, 0xEE
    ja .zero
    sub eax, 0xD1
    movzx eax, byte [cls_hi + eax]
    jmp .done
.zero:
    xor eax, eax
.done:
    pop ebp
    ret 4

; unsigned char translate(unsigned char b) -- [ebp+8], returns eax
translate:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    and eax, 0xFF
    cmp dword [g_ku_mode], 0
    je .no
    cmp eax, 0x80
    jb .no
    mov ecx, eax
    sub ecx, 0x80
    movzx eax, byte [g_ku_tab + ecx]
.no:
    pop ebp
    ret 4

; void mem19(void *dst, const void *src) -- copies CELLH(19) bytes
mem19:
    push ebp
    mov ebp, esp
    push esi
    push edi
    mov edi, [ebp+8]
    mov esi, [ebp+12]
    mov ecx, 19
    cld
    rep movsb
    pop edi
    pop esi
    pop ebp
    ret 8

; void linetab_free(LineTab *t) -- [ebp+8]
linetab_free:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    mov ecx, [eax]           ; t->lines
    test ecx, ecx
    jz .skip_free
    CALL3 _HeapFree@12, dword [g_heap], 0, ecx
.skip_free:
    mov eax, [ebp+8]
    mov dword [eax], 0       ; lines = NULL
    mov dword [eax+4], 0     ; nlines = 0
    mov dword [eax+8], 0     ; cap = 0
    mov dword [eax+12], 0    ; maxlen = 0
    pop ebp
    ret 4

; void linetab_push(LineTab *t, const unsigned char *ptr, int len)
linetab_push:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]         ; t
    mov ecx, [eax+4]         ; nlines
    mov edx, [eax+8]         ; cap
    cmp ecx, edx
    jl .no_grow
    cmp edx, 0
    jne .double_it
    mov edx, 256
    jmp .newcap_ready
.double_it:
    shl edx, 1
.newcap_ready:
    mov [eax+8], edx          ; t->cap = newcap
    mov ecx, edx
    shl ecx, 3                 ; ecx = newcap*sizeof(Line)=newcap*8
    mov edx, [eax]             ; old t->lines (may be NULL)
    test edx, edx
    jnz .do_realloc
    CALL3 _HeapAlloc@12, dword [g_heap], 0, ecx
    mov ecx, [ebp+8]
    mov [ecx], eax
    jmp .no_grow
.do_realloc:
    CALL4 _HeapReAlloc@16, dword [g_heap], 0, edx, ecx
    mov ecx, [ebp+8]
    mov [ecx], eax
.no_grow:
    mov eax, [ebp+8]           ; t
    mov edx, [eax]             ; lines (fresh, possibly reallocated)
    mov ecx, [eax+4]           ; nlines
    lea edx, [edx + ecx*8]     ; &lines[nlines]
    mov ecx, [ebp+12]          ; ptr
    mov [edx], ecx
    mov ecx, [ebp+16]          ; len
    mov [edx+4], ecx
    inc dword [eax+4]          ; nlines++
    pop ebp
    ret 12

; void build_lines(LineTab *t, const unsigned char *buf, int len)
; locals: line_start=-4 col=-8 i=-12 raw=-16
build_lines:
    push ebp
    mov ebp, esp
    sub esp, 16
    CALL1 linetab_free, dword [ebp+8]
    mov dword [ebp-4], 0       ; line_start
    mov dword [ebp-8], 0       ; col
    mov dword [ebp-12], 0      ; i
.bl_while:
    mov eax, [ebp-12]
    cmp eax, [ebp+16]          ; len
    jge .bl_while_end
    mov eax, [ebp+12]          ; buf
    add eax, [ebp-12]
    movzx eax, byte [eax]
    mov [ebp-16], eax          ; raw
    ; classify the RAW byte, not translate()'s KU-translated one -- matches
    ; read.asm's bl_c, which indexes its class table with AL straight from
    ; the file with no KU translation at all (that only happens later, in
    ; the draw-time RDCH/trc path). On a KU file this can make maxlen come
    ; out larger than a "translate first" count would (a raw KU combining
    ; mark usually isn't in TIS-620's D1h-EEh range, so it counts as a full
    ; column instead of 0) -- confirmed against real DOS: that's the actual
    ; original scroll limit, not a bug, so this must match it rather than
    ; compute a "nicer" one of its own.
    CALL1 classify, dword [ebp-16]
    test eax, C_TERM
    jz .bl_not_term
    ; linetab_push(t, buf+line_start, i-line_start)
    mov ecx, [ebp+12]
    add ecx, [ebp-4]
    mov edx, [ebp-12]
    sub edx, [ebp-4]
    CALL3 linetab_push, dword [ebp+8], ecx, edx
    mov eax, [ebp+8]
    mov ecx, [eax+12]          ; t->maxlen
    mov edx, [ebp-8]           ; col
    cmp edx, ecx
    jle .bl_skip_maxlen1
    mov [eax+12], edx
.bl_skip_maxlen1:
    mov dword [ebp-8], 0       ; col = 0
    cmp dword [ebp-16], 0x1A   ; ^Z (Ctrl-Z): read.asm's bl_done stops
    je .bl_done                ; scanning entirely right here instead of
                                ; treating it as an ordinary line break --
                                ; many DOS text files carry trailing
                                ; printer/dot-matrix control bytes after a
                                ; ^Z that must never be displayed. The line
                                ; up to (not including) the ^Z was already
                                ; pushed above; skip straight to the
                                ; epilogue so nothing after it is scanned
                                ; or added to the table (t->nlines is >=1
                                ; here, so the epilogue's nlines==0 guard
                                ; is inert -- safe to join it directly).
    ; if (raw==0x0D && i+1<len && buf[i+1]==0x0A) i++
    mov eax, [ebp-16]
    cmp eax, 0x0D
    jne .bl_no_crlf
    mov eax, [ebp-12]
    add eax, 1
    cmp eax, [ebp+16]
    jge .bl_no_crlf
    mov ecx, [ebp+12]
    add ecx, eax
    movzx edx, byte [ecx]
    cmp edx, 0x0A
    jne .bl_no_crlf
    inc dword [ebp-12]
.bl_no_crlf:
    inc dword [ebp-12]
    mov eax, [ebp-12]
    mov [ebp-4], eax           ; line_start = i
    jmp .bl_while
.bl_not_term:
    test eax, C_TAB
    jz .bl_not_tab
    add dword [ebp-8], 8
    cmp dword [ebp-8], 255
    jle .bl_after_width
    mov dword [ebp-8], 255
    jmp .bl_after_width
.bl_not_tab:
    test eax, (C_SWAL|C_STYLE|C_COMB)
    jnz .bl_after_width
    inc dword [ebp-8]
    cmp dword [ebp-8], 255
    jle .bl_after_width
    mov dword [ebp-8], 255
.bl_after_width:
    inc dword [ebp-12]
    jmp .bl_while
.bl_while_end:
    mov eax, [ebp-12]
    cmp eax, [ebp-4]
    jg .bl_push_last
    mov eax, [ebp+8]
    cmp dword [eax+4], 0       ; t->nlines == 0
    jne .bl_skip_last
.bl_push_last:
    mov ecx, [ebp+12]
    add ecx, [ebp-4]
    mov edx, [ebp-12]
    sub edx, [ebp-4]
    CALL3 linetab_push, dword [ebp+8], ecx, edx
    mov eax, [ebp+8]
    mov ecx, [eax+12]
    mov edx, [ebp-8]
    cmp edx, ecx
    jle .bl_skip_last
    mov [eax+12], edx
.bl_skip_last:
    mov eax, [ebp+8]
    cmp dword [eax+4], 0
    jne .bl_done
    CALL3 linetab_push, dword [ebp+8], dword [ebp+12], 0
.bl_done:
    mov esp, ebp
    pop ebp
    ret 12

; void recompute_bounds(LineTab *t) -- [ebp+8]
recompute_bounds:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    mov ecx, [eax+4]          ; nlines
    sub ecx, [g_body]
    jns .tm_ok
    xor ecx, ecx
.tm_ok:
    mov [g_topmax], ecx
    mov edx, [eax+12]         ; maxlen
    sub edx, [g_cols]
    jns .mh_ok
    xor edx, edx
.mh_ok:
    mov [g_maxh], edx
    mov eax, [g_top]
    cmp eax, [g_topmax]
    jle .top_ok
    mov eax, [g_topmax]
    mov [g_top], eax
.top_ok:
    mov eax, [g_hshift]
    cmp eax, [g_maxh]
    jle .hs_ok
    mov eax, [g_maxh]
    mov [g_hshift], eax
.hs_ok:
    pop ebp
    ret 4

; void calc_limits(LineTab *t) -- [ebp+8]
calc_limits:
    push ebp
    mov ebp, esp
    CALL1 recompute_bounds, dword [ebp+8]
    mov dword [g_top], 0
    mov dword [g_hshift], 0
    pop ebp
    ret 4

; void detect_ku(const unsigned char *buf, int len)
; locals: n=-4 a3=-8 a5=-12 scanned=-16 i=-20
detect_ku:
    push ebp
    mov ebp, esp
    sub esp, 20
    mov eax, [ebp+12]         ; len
    cmp eax, 4096
    jl .n_is_len
    mov eax, 4096
.n_is_len:
    mov [ebp-4], eax
    mov dword [ebp-8], 0
    mov dword [ebp-12], 0
    mov dword [ebp-16], 0
    mov dword [ebp-20], 0
.dk_loop:
    mov eax, [ebp-20]
    cmp eax, [ebp-4]
    jge .dk_done
    mov eax, [ebp+8]
    add eax, [ebp-20]
    movzx ecx, byte [eax]      ; b
    cmp ecx, 0
    je .dk_done
    cmp ecx, 0x1A
    je .dk_done
    cmp ecx, 0xA3
    jne .chk_a5
    inc dword [ebp-8]
    jmp .dk_inc_scanned
.chk_a5:
    cmp ecx, 0xA5
    jne .dk_inc_scanned
    inc dword [ebp-12]
.dk_inc_scanned:
    inc dword [ebp-16]
    inc dword [ebp-20]
    jmp .dk_loop
.dk_done:
    mov dword [g_ku_mode], 0
    mov eax, [ebp-16]
    cmp eax, 0
    jle .dk_ret
    mov eax, [ebp-8]
    imul eax, 100
    mov ecx, [ebp-16]
    imul ecx, 2
    cmp eax, ecx
    jle .chk_a5_ratio
    mov dword [g_ku_mode], 1
.chk_a5_ratio:
    mov eax, [ebp-12]
    imul eax, 100
    mov ecx, [ebp-16]
    imul ecx, 2
    cmp eax, ecx
    jle .dk_ret
    mov dword [g_ku_mode], 1
.dk_ret:
    mov esp, ebp
    pop ebp
    ret 8

; void fb_create(HDC hdc) -- [ebp+8]
; Creates a DIB section sized [g_win_w] x [g_win_h] (the CURRENT window
; size, whatever it is right now). Called once at WM_CREATE and again on
; every WM_SIZE after g_win_w/g_win_h have been updated to the new size --
; the caller (WndProc) is responsible for releasing the OLD g_dib/g_memdc
; first (DeleteObject/DeleteDC) so recreating doesn't leak GDI handles.
fb_create:
    push ebp
    mov ebp, esp
    mov dword [bmi+0], 40        ; biSize
    mov eax, [g_win_w]
    mov dword [bmi+4], eax       ; biWidth
    mov eax, [g_win_h]
    neg eax
    mov dword [bmi+8], eax       ; biHeight (negative = top-down)
    mov word  [bmi+12], 1        ; biPlanes
    mov word  [bmi+14], 32       ; biBitCount
    mov dword [bmi+16], 0        ; biCompression = BI_RGB
    CALL6 _CreateDIBSection@24, dword [ebp+8], bmi, 0, g_px, 0, 0
    mov [g_dib], eax
    CALL1 _CreateCompatibleDC@4, dword [ebp+8]
    mov [g_memdc], eax
    CALL2 _SelectObject@8, dword [g_memdc], dword [g_dib]
    pop ebp
    ret 4

; void fb_clear(void)
fb_clear:
    push ebp
    mov ebp, esp
    push edi
    mov edi, [g_px]
    mov eax, COL_BG
    mov ecx, [g_win_w]
    imul ecx, [g_win_h]
    cld
    rep stosd
    pop edi
    pop ebp
    ret

; void fb_pixel(int x, int y, int on) -- [ebp+8] [ebp+12] [ebp+16]
fb_pixel:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]           ; x
    cmp eax, 0
    jl .fp_ret
    cmp eax, [g_win_w]
    jge .fp_ret
    mov ecx, [ebp+12]          ; y
    cmp ecx, 0
    jl .fp_ret
    cmp ecx, [g_win_h]
    jge .fp_ret
    imul ecx, [g_win_w]
    add ecx, eax                ; index
    mov edx, [ebp+16]           ; on
    cmp edx, 0
    je .fp_bg
    mov eax, COL_FG
    jmp .fp_store
.fp_bg:
    mov eax, [g_bg_color]
.fp_store:
    mov edx, [g_px]
    mov [edx + ecx*4], eax
.fp_ret:
    pop ebp
    ret 12

; void apply_style(Cell out, const Cell in, unsigned char style)
; [ebp+8]=out [ebp+12]=in [ebp+16]=style ; local tmp[19] at ebp-24
apply_style:
    push ebp
    mov ebp, esp
    sub esp, 24
    push ebx
    push esi
    push edi
    ; memcpy(out,in,19)
    mov esi, [ebp+12]
    mov edi, [ebp+8]
    mov ecx, 19
    cld
    rep movsb
    ; bold: out[r] |= in[r]>>1
    mov eax, [ebp+16]
    test eax, 0x01
    jz .no_bold
    xor ecx, ecx
.bold_loop:
    mov edi, [ebp+8]
    mov esi, [ebp+12]
    movzx eax, byte [esi+ecx]
    shr al, 1
    movzx edx, byte [edi+ecx]
    or dl, al
    mov [edi+ecx], dl
    inc ecx
    cmp ecx, 19
    jl .bold_loop
.no_bold:
    ; italic: shear top rows right
    mov eax, [ebp+16]
    test eax, 0x40
    jz .no_italic
    mov esi, [ebp+8]
    lea edi, [ebp-24]
    mov ecx, 19
    rep movsb
    xor ebx, ebx                 ; r = 0
.italic_loop:
    cmp ebx, 4
    jl .sh2
    cmp ebx, 12
    jl .sh1
    xor ecx, ecx
    jmp .sh_have
.sh1:
    mov ecx, 1
    jmp .sh_have
.sh2:
    mov ecx, 2
.sh_have:
    lea eax, [ebp-24]
    movzx eax, byte [eax+ebx]     ; tmp[r]
    shr al, cl
    mov edi, [ebp+8]
    mov [edi+ebx], al
    inc ebx
    cmp ebx, 19
    jl .italic_loop
.no_italic:
    ; subscript: shift rows down 3, zero rows 0-2
    mov eax, [ebp+16]
    test eax, 0x10
    jz .no_sub
    mov esi, [ebp+8]
    lea edi, [ebp-24]
    mov ecx, 19
    rep movsb
    mov ebx, 18                   ; r = CELLH-1
.sub_loop:
    lea eax, [ebp-24]
    movzx eax, byte [eax+ebx-3]   ; tmp[r-3]
    mov edi, [ebp+8]
    mov [edi+ebx], al
    dec ebx
    cmp ebx, 3
    jge .sub_loop
    mov edi, [ebp+8]
    mov byte [edi+0], 0
    mov byte [edi+1], 0
    mov byte [edi+2], 0
.no_sub:
    ; superscript: shift rows up 5, zero rows 14-18
    mov eax, [ebp+16]
    test eax, 0x20
    jz .no_sup
    mov esi, [ebp+8]
    lea edi, [ebp-24]
    mov ecx, 19
    rep movsb
    xor ebx, ebx                  ; r = 0
.sup_loop:
    lea eax, [ebp-24]
    movzx eax, byte [eax+ebx+5]   ; tmp[r+5]
    mov edi, [ebp+8]
    mov [edi+ebx], al
    inc ebx
    cmp ebx, 13
    jle .sup_loop
    mov edi, [ebp+8]
    mov byte [edi+14], 0
    mov byte [edi+15], 0
    mov byte [edi+16], 0
    mov byte [edi+17], 0
    mov byte [edi+18], 0
.no_sup:
    ; underline single/double (skip if descender ink already present)
    mov eax, [ebp+16]
    test eax, 0x08
    jz .no_ul
    mov esi, [ebp+12]              ; in
    cmp byte [esi+17], 0
    jne .no_ul
    mov edi, [ebp+8]
    mov byte [edi+17], 0xFF
    mov eax, [ebp+16]
    test eax, 0x04
    jz .no_ul
    cmp byte [esi+18], 0
    jne .no_ul
    mov byte [edi+18], 0xFF
.no_ul:
    pop edi
    pop esi
    pop ebx
    mov esp, ebp
    pop ebp
    ret 12

; void blit_cell(int col, int row_px_y, const Cell cell, int wide)
; [ebp+8]=col [ebp+12]=row_px_y [ebp+16]=cell [ebp+20]=wide
; ebx=r(0..18) esi=bit(0..7) edi=b=cell[r]  (all callee-saved, survive the
; fb_pixel calls inside the loops)
blit_cell:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi
    xor ebx, ebx
.bc_rloop:
    cmp ebx, 19
    jge .bc_done
    mov eax, [ebp+16]
    movzx edi, byte [eax+ebx]     ; b = cell[r]
    xor esi, esi                   ; bit = 0
.bc_bitloop:
    cmp esi, 8
    jge .bc_bit_done
    mov ecx, 7
    sub ecx, esi                   ; 7-bit
    mov eax, edi
    shr eax, cl
    and eax, 1                      ; on
    cmp dword [ebp+20], 0
    jne .bc_wide
    mov ecx, [ebp+8]
    imul ecx, CELLW
    add ecx, esi                    ; x = col*8+bit
    mov edx, [ebp+12]
    add edx, ebx                    ; y = row_px_y+r
    CALL3 fb_pixel, ecx, edx, eax
    jmp .bc_bit_next
.bc_wide:
    push eax                          ; save on -- fb_pixel clobbers eax
                                       ; (caller-saved), and it's reused
                                       ; below for the second of the two
                                       ; doubled pixels
    mov ecx, [ebp+8]
    imul ecx, CELLW
    mov edx, esi
    imul edx, 2
    add ecx, edx                     ; x = col*8+bit*2
    mov edx, [ebp+12]
    add edx, ebx
    CALL3 fb_pixel, ecx, edx, eax
    mov ecx, [ebp+8]
    imul ecx, CELLW
    mov edx, esi
    imul edx, 2
    add ecx, edx
    inc ecx                           ; x+1
    mov edx, [ebp+12]
    add edx, ebx
    pop eax                           ; restore on for the second pixel
    CALL3 fb_pixel, ecx, edx, eax
.bc_bit_next:
    inc esi
    jmp .bc_bitloop
.bc_bit_done:
    inc ebx
    jmp .bc_rloop
.bc_done:
    pop edi
    pop esi
    pop ebx
    mov esp, ebp
    pop ebp
    ret 16

; void draw_text(int row_px_y, int start_col, int hshift, int raw_tis,
;                const unsigned char *buf, int len)
; [ebp+8]=row_px_y [ebp+12]=start_col [ebp+16]=hshift [ebp+20]=raw_tis
; [ebp+24]=buf [ebp+28]=len
; locals: style=-4 cur_col=-8 cell_has=-12 pending_wide=-16 pending_col=-20
;         i=-24 raw=-28 ch=-32 cls=-36 scr/al_tmp=-40 loopvar=-44 mg=-48
;         cell[19]=-96..-78  styled[19]=-128..-110
draw_text:
    push ebp
    mov ebp, esp
    sub esp, 128
    mov dword [ebp-4], 0
    mov dword [ebp-8], 0
    mov dword [ebp-12], 0
    mov dword [ebp-16], 0
    mov dword [ebp-20], -1
    mov dword [ebp-24], 0
.dt_loop:
    mov eax, [ebp-24]
    cmp eax, [ebp+28]
    jge .dt_end
    mov eax, [ebp+24]
    add eax, [ebp-24]
    movzx eax, byte [eax]
    mov [ebp-28], eax              ; raw
    cmp dword [ebp+20], 0          ; raw_tis
    jne .dt_rawtis
    CALL1 translate, dword [ebp-28]
    mov [ebp-32], eax              ; ch
    jmp .dt_ch_done
.dt_rawtis:
    mov eax, [ebp-28]
    mov [ebp-32], eax
.dt_ch_done:
    CALL1 classify, dword [ebp-32]
    mov [ebp-36], eax              ; cls
    test eax, C_TERM
    jz .dt_not_term
    jmp .dt_end
.dt_not_term:
    mov eax, [ebp-36]
    test eax, C_STYLE
    jz .dt_not_style
    mov eax, [ebp-32]              ; ch
    cmp eax, 0x17
    jbe .dt_style_idx_ok
    xor eax, eax
.dt_style_idx_ok:
    movzx eax, byte [stx + eax]
    mov [ebp-40], eax              ; al
    test eax, 0x30
    jz .dt_no_clear
    mov ecx, eax
    xor ecx, 0x30
    not ecx
    and ecx, 0xFF
    mov edx, [ebp-4]
    and edx, ecx
    mov [ebp-4], edx
.dt_no_clear:
    mov eax, [ebp-4]
    xor eax, [ebp-40]
    and eax, 0xFF
    mov [ebp-4], eax               ; style ^= al
    jmp .dt_continue
.dt_not_style:
    mov eax, [ebp-36]
    test eax, C_SWAL
    jz .dt_not_swal
    jmp .dt_continue
.dt_not_swal:
    mov eax, [ebp-36]
    test eax, C_COMB
    jz .dt_not_comb
    cmp dword [ebp-12], 0          ; cell_has
    je .dt_not_comb
    ; comb-mark-onto-existing-cell path
    mov eax, [ebp-32]
    imul eax, CELLH
    add eax, g_font
    mov [ebp-48], eax              ; mg
    mov dword [ebp-44], 0          ; r
.dt_comb_loop:
    mov eax, [ebp-44]
    cmp eax, 19
    jge .dt_comb_loop_done
    lea ecx, [ebp-96]
    add ecx, eax                    ; &cell[r]
    mov edx, [ebp-48]
    add edx, eax                    ; &mg[r]
    movzx eax, byte [edx]
    or byte [ecx], al
    inc dword [ebp-44]
    jmp .dt_comb_loop
.dt_comb_loop_done:
    mov eax, [ebp-4]
    and eax, 0x02
    jz .dt_comb_pw0
    mov dword [ebp-16], 1
    jmp .dt_comb_pw_done
.dt_comb_pw0:
    mov dword [ebp-16], 0
.dt_comb_pw_done:
    lea eax, [ebp-96]
    lea ecx, [ebp-128]
    CALL3 apply_style, ecx, eax, dword [ebp-4]
    mov eax, [ebp+12]
    add eax, [ebp-20]
    sub eax, [ebp+16]
    mov [ebp-40], eax               ; scr
    cmp dword [ebp-40], 0
    jl .dt_comb_noblit
    cmp eax, [g_cols]           ; eax still == [ebp-40] (scr) here
    jge .dt_comb_noblit
    lea eax, [ebp-128]
    CALL4 blit_cell, dword [ebp-40], dword [ebp+8], eax, dword [ebp-16]
.dt_comb_noblit:
    jmp .dt_continue
.dt_not_comb:
    mov eax, [ebp-36]
    test eax, C_TAB
    jz .dt_base_char
    mov dword [ebp-44], 0          ; k
.dt_tab_loop:
    mov eax, [ebp-44]
    cmp eax, 8
    jge .dt_tab_done
    lea eax, [ebp-96]
    mov ecx, g_font
    add ecx, 0x20*CELLH
    CALL2 mem19, eax, ecx
    mov dword [ebp-12], 1
    mov eax, [ebp-8]
    mov [ebp-20], eax               ; pending_col = cur_col
    mov eax, [ebp-4]
    and eax, 0x02
    jz .dt_tabpw0
    mov dword [ebp-16], 1
    jmp .dt_tabpw_done
.dt_tabpw0:
    mov dword [ebp-16], 0
.dt_tabpw_done:
    lea eax, [ebp-96]
    lea ecx, [ebp-128]
    CALL3 apply_style, ecx, eax, dword [ebp-4]
    mov eax, [ebp+12]
    add eax, [ebp-20]
    sub eax, [ebp+16]
    mov [ebp-40], eax
    cmp dword [ebp-40], 0
    jl .dt_tab_noblit
    cmp eax, [g_cols]           ; eax still == [ebp-40] (scr) here
    jge .dt_tab_noblit
    lea eax, [ebp-128]
    CALL4 blit_cell, dword [ebp-40], dword [ebp+8], eax, dword [ebp-16]
.dt_tab_noblit:
    cmp dword [ebp-16], 0
    je .dt_tab_inc1
    add dword [ebp-8], 2
    jmp .dt_tab_incdone
.dt_tab_inc1:
    inc dword [ebp-8]
.dt_tab_incdone:
    inc dword [ebp-44]
    jmp .dt_tab_loop
.dt_tab_done:
    jmp .dt_continue
.dt_base_char:
    lea eax, [ebp-96]
    mov ecx, [ebp-32]               ; ch
    imul ecx, CELLH
    add ecx, g_font
    CALL2 mem19, eax, ecx
    mov dword [ebp-12], 1
    mov eax, [ebp-8]
    mov [ebp-20], eax
    mov eax, [ebp-4]
    and eax, 0x02
    jz .dt_basepw0
    mov dword [ebp-16], 1
    jmp .dt_basepw_done
.dt_basepw0:
    mov dword [ebp-16], 0
.dt_basepw_done:
    lea eax, [ebp-96]
    lea ecx, [ebp-128]
    CALL3 apply_style, ecx, eax, dword [ebp-4]
    mov eax, [ebp+12]
    add eax, [ebp-20]
    sub eax, [ebp+16]
    mov [ebp-40], eax
    cmp dword [ebp-40], 0
    jl .dt_base_noblit
    cmp eax, [g_cols]           ; eax still == [ebp-40] (scr) here
    jge .dt_base_noblit
    lea eax, [ebp-128]
    CALL4 blit_cell, dword [ebp-40], dword [ebp+8], eax, dword [ebp-16]
.dt_base_noblit:
    cmp dword [ebp-16], 0
    je .dt_base_inc1
    add dword [ebp-8], 2
    jmp .dt_base_incdone
.dt_base_inc1:
    inc dword [ebp-8]
.dt_base_incdone:
.dt_continue:
    inc dword [ebp-24]
    jmp .dt_loop
.dt_end:
    mov esp, ebp
    pop ebp
    ret 24

; int text_width(const unsigned char *buf, int len) -- returns eax
text_width:
    push ebp
    mov ebp, esp
    sub esp, 8
    mov dword [ebp-4], 0        ; col
    mov dword [ebp-8], 0        ; i
.tw_loop:
    mov eax, [ebp-8]
    cmp eax, [ebp+12]
    jge .tw_done
    mov eax, [ebp+8]
    add eax, [ebp-8]
    movzx eax, byte [eax]
    CALL1 classify, eax
    test eax, C_TAB
    jz .tw_not_tab
    add dword [ebp-4], 8
    jmp .tw_next
.tw_not_tab:
    test eax, (C_SWAL|C_STYLE|C_COMB)
    jnz .tw_next
    inc dword [ebp-4]
.tw_next:
    inc dword [ebp-8]
    jmp .tw_loop
.tw_done:
    mov eax, [ebp-4]
    mov esp, ebp
    pop ebp
    ret 8

; int append_cstr(unsigned char *dst, int pos, const char *src)
; copies bytes from src until a null byte; returns new pos
append_cstr:
    push ebp
    mov ebp, esp
    push esi
    push edi
    mov edi, [ebp+8]
    add edi, [ebp+12]
    mov esi, [ebp+16]
.ac_loop:
    mov al, [esi]
    cmp al, 0
    je .ac_done
    mov [edi], al
    inc esi
    inc edi
    jmp .ac_loop
.ac_done:
    mov eax, edi
    sub eax, [ebp+8]
    pop edi
    pop esi
    pop ebp
    ret 12

; unsigned int append_udec(unsigned char *dst, int pos, unsigned int val)
; writes the decimal digits of val at dst+pos; returns new pos
; local digit scratch buffer at ebp-16 (10 bytes suffice for 32-bit range)
append_udec:
    push ebp
    mov ebp, esp
    sub esp, 16
    push esi
    mov dword [ebp-4], 0        ; ndigits
    mov eax, [ebp+16]
    test eax, eax
    jnz .ud_gen
    mov byte [ebp-16], '0'
    mov dword [ebp-4], 1
    jmp .ud_write
.ud_gen:
.ud_genloop:
    test eax, eax
    jz .ud_write
    xor edx, edx
    mov ecx, 10
    div ecx
    add edx, '0'
    mov ecx, [ebp-4]
    lea esi, [ebp-16]
    mov [esi+ecx], dl
    inc dword [ebp-4]
    jmp .ud_genloop
.ud_write:
    mov ecx, 0                   ; j
.ud_wloop:
    cmp ecx, [ebp-4]
    jge .ud_wdone
    mov eax, [ebp-4]
    dec eax
    sub eax, ecx                  ; k = ndigits-1-j
    lea esi, [ebp-16]
    movzx edx, byte [esi+eax]
    mov eax, [ebp+8]
    add eax, [ebp+12]
    add eax, ecx
    mov [eax], dl
    inc ecx
    jmp .ud_wloop
.ud_wdone:
    mov eax, [ebp+12]
    add eax, [ebp-4]
    pop esi
    mov esp, ebp
    pop ebp
    ret 12

; void bounded_strcpy(char *dst, const char *src, int maxlen)
; copies up to maxlen bytes (stopping earlier at a null byte) then
; null-terminates dst
bounded_strcpy:
    push ebp
    mov ebp, esp
    push esi
    push edi
    mov edi, [ebp+8]
    mov esi, [ebp+12]
    mov ecx, [ebp+16]
.bs_loop:
    cmp ecx, 0
    je .bs_term
    mov al, [esi]
    cmp al, 0
    je .bs_term
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jmp .bs_loop
.bs_term:
    mov byte [edi], 0
    pop edi
    pop esi
    pop ebp
    ret 12

; void draw_status(void)
; locals: lo=-4 hi=-8 rlen=-12 rcols=-16 pos=-20 fname_ptr=-24
draw_status:
    push ebp
    mov ebp, esp
    sub esp, 32
    push edi
    mov edi, [g_px]
    mov eax, COL_BAR_BG
    mov ecx, [g_win_w]
    imul ecx, CELLH
    cld
    rep stosd
    mov dword [g_bg_color], COL_BAR_BG
    mov eax, [g_top]
    inc eax
    mov [ebp-4], eax            ; lo
    mov eax, [g_top]
    add eax, [g_body]
    mov [ebp-8], eax            ; hi
    mov eax, [g_cur]
    mov ecx, [eax+4]             ; nlines
    mov edx, [ebp-8]
    cmp edx, ecx
    jle .ds_hi_ok
    mov [ebp-8], ecx
.ds_hi_ok:
    mov eax, [g_cur]
    cmp dword [eax+4], 0
    jne .ds_lohi_ok
    mov dword [ebp-4], 0
    mov dword [ebp-8], 0
.ds_lohi_ok:
    cmp dword [g_help_mode], 0
    je .ds_not_help
    mov dword [ebp-24], help_title_str
    jmp .ds_fname_done
.ds_not_help:
    cmp byte [g_fname], 0
    je .ds_use_nofile
    mov dword [ebp-24], g_fname
    jmp .ds_fname_done
.ds_use_nofile:
    mov dword [ebp-24], nofile_str
.ds_fname_done:
    mov dword [ebp-20], 0        ; pos
    CALL3 append_cstr, status_left_buf, dword [ebp-20], dword [ebp-24]
    mov [ebp-20], eax
    CALL3 append_cstr, status_left_buf, dword [ebp-20], sep_c_str
    mov [ebp-20], eax
    CALL3 append_udec, status_left_buf, dword [ebp-20], dword [g_hshift]
    mov [ebp-20], eax
    CALL3 append_cstr, status_left_buf, dword [ebp-20], sep_r_str
    mov [ebp-20], eax
    CALL3 append_udec, status_left_buf, dword [ebp-20], dword [ebp-4]
    mov [ebp-20], eax
    CALL3 append_cstr, status_left_buf, dword [ebp-20], dash_str
    mov [ebp-20], eax
    CALL3 append_udec, status_left_buf, dword [ebp-20], dword [ebp-8]
    mov [ebp-20], eax
    CALL3 append_cstr, status_left_buf, dword [ebp-20], sep2_str
    mov [ebp-20], eax
    cmp dword [g_ku_mode], 0
    je .ds_use_tis
    CALL3 append_cstr, status_left_buf, dword [ebp-20], ku_str
    jmp .ds_kutis_done
.ds_use_tis:
    CALL3 append_cstr, status_left_buf, dword [ebp-20], tis_str
.ds_kutis_done:
    mov [ebp-20], eax
    CALL6 draw_text, 0, 0, 0, 1, status_left_buf, dword [ebp-20]
    mov dword [ebp-12], STL_RIGHT_LEN
    CALL2 text_width, g_stl_right, dword [ebp-12]
    mov [ebp-16], eax             ; rcols
    mov eax, [g_cols]
    sub eax, [ebp-16]
    CALL6 draw_text, 0, eax, 0, 1, g_stl_right, dword [ebp-12]
    mov dword [g_bg_color], COL_BG
    pop edi
    mov esp, ebp
    pop ebp
    ret

; void render_all(void)
; locals: r=-4 li=-8
render_all:
    push ebp
    mov ebp, esp
    sub esp, 8
    call fb_clear
    call draw_status
    mov dword [ebp-4], 0
.ra_loop:
    mov eax, [ebp-4]
    cmp eax, [g_body]
    jge .ra_done
    mov eax, [g_top]
    add eax, [ebp-4]
    mov [ebp-8], eax             ; li
    mov eax, [g_cur]
    mov ecx, [eax+4]              ; nlines
    cmp dword [ebp-8], ecx
    jge .ra_done
    mov eax, [g_cur]
    mov eax, [eax]                 ; lines ptr
    mov ecx, [ebp-8]
    lea eax, [eax+ecx*8]            ; &lines[li]
    mov edx, [eax]                  ; ptr
    mov ecx, [eax+4]                ; len
    mov eax, [ebp-4]
    inc eax
    imul eax, CELLH                  ; row_px_y = (r+1)*CELLH
    CALL6 draw_text, eax, 0, dword [g_hshift], 0, edx, ecx
    inc dword [ebp-4]
    jmp .ra_loop
.ra_done:
    mov esp, ebp
    pop ebp
    ret

; void load_file(const char *path) -- [ebp+8]
load_file:
    push ebp
    mov ebp, esp
    sub esp, 8                 ; hFile=-4 sz=-8
    CALL7 _CreateFileA@28, dword [ebp+8], 0x80000000, 1, 0, 3, 0x80, 0
    mov [ebp-4], eax
    cmp eax, -1                 ; INVALID_HANDLE_VALUE
    jne .lf_opened
    CALL4 _MessageBoxA@16, 0, dword [ebp+8], cannot_open_str, 0x10
    jmp .lf_ret
.lf_opened:
    CALL2 _GetFileSize@8, dword [ebp-4], 0
    mov [ebp-8], eax             ; sz
    mov eax, [g_filebuf]
    test eax, eax
    jz .lf_nofree
    CALL3 _HeapFree@12, dword [g_heap], 0, eax
.lf_nofree:
    mov eax, [ebp-8]
    test eax, eax
    jnz .lf_szok
    mov eax, 1
.lf_szok:
    CALL3 _HeapAlloc@12, dword [g_heap], 0, eax
    mov [g_filebuf], eax
    CALL5 _ReadFile@20, dword [ebp-4], dword [g_filebuf], dword [ebp-8], read_bytes_scratch, 0
    mov eax, [read_bytes_scratch]
    mov [g_filelen], eax
    CALL1 _CloseHandle@4, dword [ebp-4]
    CALL2 detect_ku, dword [g_filebuf], dword [g_filelen]
    CALL3 build_lines, g_tab, dword [g_filebuf], dword [g_filelen]
    mov dword [g_cur], g_tab
    CALL1 calc_limits, g_tab
    CALL3 bounded_strcpy, g_fname, dword [ebp+8], 259
.lf_ret:
    mov esp, ebp
    pop ebp
    ret 4

; void enter_help(void)
enter_help:
    push ebp
    mov ebp, esp
    cmp dword [g_help_mode], 0
    jne .eh_ret
    mov eax, [g_top]
    mov [g_sv_top], eax
    mov eax, [g_hshift]
    mov [g_sv_hshift], eax
    mov eax, [g_ku_mode]
    mov [g_sv_ku], eax
    mov dword [g_ku_mode], 0
    cmp dword [g_help_built], 0
    jne .eh_built
    CALL3 build_lines, g_help_tab, g_help_data, HELP_LEN
    mov dword [g_help_built], 1
.eh_built:
    mov dword [g_cur], g_help_tab
    CALL1 calc_limits, g_help_tab
    mov dword [g_help_mode], 1
.eh_ret:
    pop ebp
    ret

; void exit_help(void)
exit_help:
    push ebp
    mov ebp, esp
    cmp dword [g_help_mode], 0
    je .xh_ret
    mov eax, [g_sv_top]
    mov [g_top], eax
    mov eax, [g_sv_hshift]
    mov [g_hshift], eax
    mov eax, [g_sv_ku]
    mov [g_ku_mode], eax
    mov eax, [g_filebuf]
    test eax, eax
    jz .xh_use_help
    mov dword [g_cur], g_tab
    jmp .xh_cur_done
.xh_use_help:
    mov dword [g_cur], g_help_tab
.xh_cur_done:
    CALL1 recompute_bounds, dword [g_cur]
    mov dword [g_help_mode], 0
.xh_ret:
    pop ebp
    ret

; void clamp_top(int wanted) -- [ebp+8]
clamp_top:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    cmp eax, 0
    jge .ct_nn
    xor eax, eax
.ct_nn:
    cmp eax, [g_topmax]
    jle .ct_ok
    mov eax, [g_topmax]
.ct_ok:
    mov [g_top], eax
    pop ebp
    ret 4

; void clamp_hshift(int wanted) -- [ebp+8]
clamp_hshift:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    cmp eax, 0
    jge .ch_nn
    xor eax, eax
.ch_nn:
    cmp eax, [g_maxh]
    jle .ch_ok
    mov eax, [g_maxh]
.ch_ok:
    mov [g_hshift], eax
    pop ebp
    ret 4

; LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
; [ebp+8]=hwnd [ebp+12]=msg [ebp+16]=wp [ebp+20]=lp
; locals: ps[64] at ebp-64..ebp-1, redraw at ebp-68, hdc at ebp-72
WndProc:
    push ebp
    mov ebp, esp
    sub esp, 96
    mov eax, [ebp+12]
    cmp eax, 1                    ; WM_CREATE
    jne .wp_not_create
    CALL1 _GetDC@4, dword [ebp+8]
    mov [ebp-72], eax
    CALL1 fb_create, dword [ebp-72]
    CALL2 _ReleaseDC@8, dword [ebp+8], dword [ebp-72]
    xor eax, eax
    jmp .wp_ret
.wp_not_create:
    cmp dword [ebp+12], 0x14      ; WM_ERASEBKGND
    jne .wp_not_erase
    mov eax, 1
    jmp .wp_ret
.wp_not_erase:
    cmp dword [ebp+12], 0x0F      ; WM_PAINT
    jne .wp_not_paint
    lea eax, [ebp-64]
    CALL2 _BeginPaint@8, dword [ebp+8], eax
    mov [ebp-72], eax             ; hdc
    CALL9 _BitBlt@36, dword [ebp-72], 0, 0, dword [g_win_w], dword [g_win_h], dword [g_memdc], 0, 0, 0x00CC0020
    lea eax, [ebp-64]
    CALL2 _EndPaint@8, dword [ebp+8], eax
    xor eax, eax
    jmp .wp_ret
.wp_not_paint:
    cmp dword [ebp+12], 5          ; WM_SIZE
    jne .wp_not_size
    cmp dword [ebp+16], 1          ; SIZE_MINIMIZED -- width/height both 0,
    je .wp_size_skip               ; nothing useful to recompute; ignore
    mov eax, [ebp+20]              ; lp: LOWORD=new client width, HIWORD=height
    movzx ecx, ax                  ; ecx = new_w (px)
    shr eax, 16                    ; eax = new_h (px)
    mov [ebp-76], ecx              ; new_w local
    mov [ebp-80], eax              ; new_h local
    mov [g_win_w], ecx
    mov [g_win_h], eax
    mov eax, ecx                   ; new_cols = new_w / CELLW, floor MIN_COLS
    xor edx, edx
    mov ecx, CELLW
    div ecx
    cmp eax, MIN_COLS
    jge .wp_size_cols_ok
    mov eax, MIN_COLS
.wp_size_cols_ok:
    mov [g_cols], eax
    mov eax, [ebp-80]              ; new_body = new_h / CELLH - 1 (status row),
    xor edx, edx                   ; floor MIN_BODY
    mov ecx, CELLH
    div ecx
    dec eax
    cmp eax, MIN_BODY
    jge .wp_size_body_ok
    mov eax, MIN_BODY
.wp_size_body_ok:
    mov [g_body], eax
    CALL1 _DeleteObject@4, dword [g_dib]
    CALL1 _DeleteDC@4, dword [g_memdc]
    CALL1 _GetDC@4, dword [ebp+8]
    mov [ebp-72], eax
    CALL1 fb_create, dword [ebp-72]
    CALL2 _ReleaseDC@8, dword [ebp+8], dword [ebp-72]
    CALL1 recompute_bounds, dword [g_cur]  ; NOT calc_limits -- keep scroll pos
    call render_all
    CALL3 _InvalidateRect@12, dword [ebp+8], 0, 0
.wp_size_skip:
    xor eax, eax
    jmp .wp_ret
.wp_not_size:
    cmp dword [ebp+12], 0x24       ; WM_GETMINMAXINFO
    jne .wp_not_minmax
    mov eax, [ebp+20]              ; lp -> MINMAXINFO*; ptMinTrackSize at +24/+28
    mov dword [eax+24], (MIN_COLS*CELLW)
    mov dword [eax+28], ((MIN_BODY+1)*CELLH)
    xor eax, eax
    jmp .wp_ret
.wp_not_minmax:
    cmp dword [ebp+12], 0x100      ; WM_KEYDOWN
    jne .wp_not_keydown
    mov dword [ebp-68], 1           ; redraw = 1
    cmp dword [ebp+16], 0x26        ; VK_UP
    jne .k1
    mov eax, [g_top]
    dec eax
    CALL1 clamp_top, eax
    jmp .k_done
.k1:
    cmp dword [ebp+16], 0x28         ; VK_DOWN
    jne .k2
    mov eax, [g_top]
    inc eax
    CALL1 clamp_top, eax
    jmp .k_done
.k2:
    cmp dword [ebp+16], 0x21         ; VK_PRIOR (PgUp)
    jne .k3
    mov eax, [g_top]
    sub eax, [g_body]
    CALL1 clamp_top, eax
    jmp .k_done
.k3:
    cmp dword [ebp+16], 0x22          ; VK_NEXT (PgDn)
    jne .k4
    mov eax, [g_top]
    add eax, [g_body]
    CALL1 clamp_top, eax
    jmp .k_done
.k4:
    cmp dword [ebp+16], 0x20          ; VK_SPACE
    jne .k5
    mov eax, [g_top]
    add eax, [g_body]
    CALL1 clamp_top, eax
    jmp .k_done
.k5:
    cmp dword [ebp+16], 0x08          ; VK_BACK
    jne .k6
    mov eax, [g_top]
    sub eax, [g_body]
    CALL1 clamp_top, eax
    jmp .k_done
.k6:
    cmp dword [ebp+16], 0x24          ; VK_HOME
    jne .k7
    CALL1 clamp_top, 0
    jmp .k_done
.k7:
    cmp dword [ebp+16], 0x23          ; VK_END
    jne .k8
    CALL1 clamp_top, dword [g_topmax]
    jmp .k_done
.k8:
    cmp dword [ebp+16], 0x25          ; VK_LEFT
    jne .k9
    mov eax, [g_hshift]
    sub eax, 8
    CALL1 clamp_hshift, eax
    jmp .k_done
.k9:
    cmp dword [ebp+16], 0x27          ; VK_RIGHT
    jne .k10
    mov eax, [g_hshift]
    add eax, 8
    CALL1 clamp_hshift, eax
    jmp .k_done
.k10:
    cmp dword [ebp+16], 0x70          ; VK_F1
    jne .k11
    cmp dword [g_help_mode], 0
    je .k10_enter
    call exit_help
    jmp .k_done
.k10_enter:
    call enter_help
    jmp .k_done
.k11:
    cmp dword [ebp+16], 'C'
    jne .k12
    mov eax, [g_ku_mode]
    xor eax, 1
    mov [g_ku_mode], eax
    jmp .k_done
.k12:
    cmp dword [ebp+16], 0x1B          ; VK_ESCAPE
    jne .k13
    CALL1 _PostQuitMessage@4, 0
    mov dword [ebp-68], 0
    jmp .k_done
.k13:
    cmp dword [ebp+16], 'Q'
    jne .k_default
    CALL1 _PostQuitMessage@4, 0
    mov dword [ebp-68], 0
    jmp .k_done
.k_default:
    cmp dword [g_help_mode], 0
    je .k_default_notmode
    mov eax, [g_filebuf]
    test eax, eax
    jz .k_default_noquitfile
    call exit_help
    jmp .k_done
.k_default_noquitfile:
    CALL1 _PostQuitMessage@4, 0
    mov dword [ebp-68], 0
    jmp .k_done
.k_default_notmode:
    mov dword [ebp-68], 0
.k_done:
    cmp dword [ebp-68], 0
    je .wp_kd_end
    call render_all
    CALL3 _InvalidateRect@12, dword [ebp+8], 0, 0
.wp_kd_end:
    xor eax, eax
    jmp .wp_ret
.wp_not_keydown:
    cmp dword [ebp+12], 2             ; WM_DESTROY
    jne .wp_default
    CALL1 _PostQuitMessage@4, 0
    xor eax, eax
    jmp .wp_ret
.wp_default:
    CALL4 _DefWindowProcA@16, dword [ebp+8], dword [ebp+12], dword [ebp+16], dword [ebp+20]
.wp_ret:
    mov esp, ebp
    pop ebp
    ret 16

; int parse_arg1(void) -- returns eax = pointer to a null-terminated copy of
; the first command-line argument (in arg1_buf), or 0 if none was given.
; Simple parser: skips the program-name token (quoted or not), skips
; whitespace, then copies the next token (quoted or not) as argv[1].
parse_arg1:
    push ebp
    mov ebp, esp
    push esi
    push edi
    call _GetCommandLineA@0
    mov esi, eax
    cmp byte [esi], '"'
    jne .pa_prog_unquoted
    inc esi
.pa_prog_q_loop:
    cmp byte [esi], 0
    je .pa_after_prog
    cmp byte [esi], '"'
    je .pa_prog_q_end
    inc esi
    jmp .pa_prog_q_loop
.pa_prog_q_end:
    inc esi
    jmp .pa_after_prog
.pa_prog_unquoted:
.pa_prog_u_loop:
    cmp byte [esi], 0
    je .pa_after_prog
    cmp byte [esi], ' '
    je .pa_after_prog
    cmp byte [esi], 9
    je .pa_after_prog
    inc esi
    jmp .pa_prog_u_loop
.pa_after_prog:
.pa_ws_loop:
    cmp byte [esi], ' '
    je .pa_ws_next
    cmp byte [esi], 9
    je .pa_ws_next
    jmp .pa_ws_done
.pa_ws_next:
    inc esi
    jmp .pa_ws_loop
.pa_ws_done:
    cmp byte [esi], 0
    jne .pa_have_arg
    xor eax, eax
    jmp .pa_ret
.pa_have_arg:
    mov edi, arg1_buf
    cmp byte [esi], '"'
    jne .pa_arg_unquoted
    inc esi
.pa_arg_q_loop:
    mov al, [esi]
    cmp al, 0
    je .pa_arg_done
    cmp al, '"'
    je .pa_arg_done
    mov [edi], al
    inc esi
    inc edi
    jmp .pa_arg_q_loop
.pa_arg_unquoted:
.pa_arg_u_loop:
    mov al, [esi]
    cmp al, 0
    je .pa_arg_done
    cmp al, ' '
    je .pa_arg_done
    cmp al, 9
    je .pa_arg_done
    mov [edi], al
    inc esi
    inc edi
    jmp .pa_arg_u_loop
.pa_arg_done:
    mov byte [edi], 0
    mov eax, arg1_buf
.pa_ret:
    pop edi
    pop esi
    pop ebp
    ret

; ---------------- entry point (replaces WinMain -- no CRT at all) ---------
_start:
    call _GetProcessHeap@0
    mov [g_heap], eax
    mov dword [g_bg_color], COL_BG
    mov dword [g_cols], COLS_INIT     ; must be set before load_file/
    mov dword [g_body], BODY_INIT     ; enter_help below, which call
    mov dword [g_win_w], WIN_W_INIT   ; calc_limits -> recompute_bounds,
    mov dword [g_win_h], WIN_H_INIT   ; which reads g_cols/g_body
    call parse_arg1
    test eax, eax
    jz .st_noarg
    CALL1 load_file, eax
.st_noarg:
    mov eax, [g_filebuf]
    test eax, eax
    jnz .st_havefile
    call enter_help
    jmp .st_wc
.st_havefile:
    mov dword [g_cur], g_tab
.st_wc:
    mov dword [wc_buf+4], WndProc          ; lpfnWndProc
    CALL1 _GetModuleHandleA@4, 0
    mov [wc_buf+16], eax                    ; hInstance
    mov [g_hinstance], eax
    CALL2 _LoadCursorA@8, 0, 32512           ; IDC_ARROW
    mov [wc_buf+24], eax                     ; hCursor
    CALL1 _GetStockObject@4, 4                ; BLACK_BRUSH
    mov [wc_buf+28], eax                      ; hbrBackground
    mov dword [wc_buf+36], class_name_str     ; lpszClassName
    CALL1 _RegisterClassA@4, wc_buf
    mov dword [rect_buf+0], 0
    mov dword [rect_buf+4], 0
    mov eax, [g_win_w]
    mov [rect_buf+8], eax
    mov eax, [g_win_h]
    mov [rect_buf+12], eax
    CALL3 _AdjustWindowRect@12, rect_buf, WS_STYLE_SIZABLE, 0
    mov eax, [rect_buf+8]
    sub eax, [rect_buf+0]
    mov [rect_w], eax
    mov eax, [rect_buf+12]
    sub eax, [rect_buf+4]
    mov [rect_h], eax
    CALL12 _CreateWindowExA@48, 0, class_name_str, title_str, (WS_STYLE_SIZABLE|WS_VISIBLE), \
        0x80000000, 0x80000000, dword [rect_w], dword [rect_h], 0, 0, dword [g_hinstance], 0
    mov [g_hwnd], eax
    call render_all
    CALL3 _InvalidateRect@12, dword [g_hwnd], 0, 0
.st_msgloop:
    CALL4 _GetMessageA@16, msg_buf, 0, 0, 0
    test eax, eax
    jz .st_msgloop_end
    CALL1 _TranslateMessage@4, msg_buf
    CALL1 _DispatchMessageA@4, msg_buf
    jmp .st_msgloop
.st_msgloop_end:
    CALL1 _ExitProcess@4, 0
