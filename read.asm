;-----------------------------------------------------------------------
; READ.COM -- Thai text reader, CGA / EGA / VGA / HGC, 8x19 font (8086)
;
;   read file.txt [/v|/e|/c|/h]      read /t = selftest
;
;   keys:  Up/Dn = 1 line      PgUp/PgDn = page (Space/BS too)
;          Home/End = top/bottom
;          Left/Right = horizontal scroll 8 cols (long lines)
;          c = toggle Kaset-RW <-> TIS-620 decoding (live)
;          F1 = help          q / Esc = quit
;
; File is read into up to 8 x 64KB blocks at CS+1000h.. (contiguous, so a
; line may run across a block edge), a line table (seg:off per line) is
; built at lin_tab.  The font and the help text are stored run-length
; packed and unpacked into the BSS at startup.
;
; Build: python build_read.py   (packs the data, runs NASM, strips the pad)
;-----------------------------------------------------------------------
        cpu     8086
        ; NASM 3.x ignores 'org' in -f bin: pad to 0100h instead, the build
        ; script strips the pad so every label = its real DOS load address.
        times   100h db 0

%include "packed.inc"                ; FONT_LEN / HELP_LEN (from build_read.py)

CELLH   equ 19                       ; cell height = font height (AXV 8x19)
MAXBLK  equ 8
HELP_LINEMAX equ 32                  ; help table capacity (help doc is tiny)
VPARM_SZ equ 12

; byte classes (cls table)
C_TERM  equ 01h                      ; 0A 0D (real line breaks only; the
                                      ; true end of loaded text is tracked
                                      ; separately via buf_end_seg/off, see
                                      ; RDCH/peek -- 00/1A are content bytes
                                      ; that must not truncate a file, so
                                      ; they classify as C_SWAL below)
C_SWAL  equ 02h                      ; invisible controls, eat nothing
C_STYLE equ 04h                      ; WordStar style toggles
C_COMB  equ 08h                      ; combining mark (upper or lower)
C_TAB   equ 10h                      ; 09 (tab): expands to 8 spaces

; read next byte of the line: ES:SI -> AL = translated char, AH = class
; (at the recorded true end of loaded text: report as if a terminator was
;  read, whatever byte value physically follows in memory. A real 09 byte
;  is consumed once but reported back as 8 separate plain-space reads --
;  [tab_run] counts how many of those 8 are still owed.)
%macro  RDCH 0
        cmp     byte [tab_run], 0
        je      %%chk
        dec     byte [tab_run]
        mov     ax, [trc+40h]        ; trc[' '] -- always class 0, plain space
        jmp     %%done
%%chk:  mov     bx, es
        cmp     bx, [buf_end_seg]
        jne     %%rd
        cmp     si, [buf_end_off]
        jne     %%rd
        mov     ah, C_TERM
        jmp     %%done
%%rd:   mov     al, [es:si]
        inc     si
        jnz     %%ok
        mov     bx, es               ; the line runs into the next block
        add     bx, 1000h
        mov     es, bx
%%ok:   xor     ah, ah
        mov     bx, ax
        shl     bx, 1
        mov     ax, [trc+bx]
        test    ah, C_TAB
        jz      %%done
        mov     byte [tab_run], 7    ; this read + 7 more = 8 spaces total
        mov     ax, [trc+40h]
%%done:
%endmacro

;=======================================================================
start:
        cld
        mov     di, bss_start        ; ES = CS (DOS): zero the BSS
        mov     cx, (bss_end-bss_start+1)/2
        xor     ax, ax
        rep     stosw
        mov     si, packed           ; unpack font + help text:
        mov     di, font8x19         ;   00 <n> <b> = run, else literal
up_l:   lodsb
        test    al, al
        jz      up_run
        stosb
up_n:   cmp     di, help_data+HELP_LEN
        jb      up_l
        jmp     up_d
up_run: lodsb
        mov     cl, al
        lodsb
        rep     stosb
        jmp     up_n
up_d:
        mov     si, cls_lo           ; byte class table: 00-1F and D1-EE
        mov     di, cls
        mov     cl, 20h
        rep     movsb
        mov     si, cls_hi
        mov     di, cls+0D1h
        mov     cl, 0EEh-0D1h+1
        rep     movsb
        mov     di, tbl_hi           ; pixel-doubling tables (expanded style)
        xor     cx, cx
        mov     bx, nib16
tb_l:   mov     al, cl
        push    cx
        mov     cl, 4
        shr     al, cl
        pop     cx
        xlat
        mov     [di], al             ; tbl_hi[i] = high nibble doubled
        mov     al, cl
        and     al, 0Fh
        xlat
        mov     [di+256], al         ; tbl_lo[i] = low nibble doubled
        inc     di
        inc     cl
        jnz     tb_l
        mov     di, gofs             ; glyph offset table: font + 19*c
        mov     ax, font8x19
gf_l:   stosw
        add     ax, CELLH
        cmp     ax, font8x19+FONT_LEN
        jb      gf_l
        mov     word [lin_base], lin_tab
        mov     word [lin_lim], LIN_LIM
        ; flush stale keystrokes (e.g. the autoexec's Enter)
fk1:    mov     ah, 1
        int     16h
        jz      fk2
        xor     ah, ah
        int     16h
        jmp     fk1
fk2:    mov     ah, 0Fh              ; save current video mode
        int     10h
        mov     [old_mode], al
        call    parse_tail
        cmp     byte [forced], 0
        jne     m_set
        call    detect_video
m_set:  call    gfx_on
        cmp     byte [test_mode], 0
        je      m_st
        call    clear_screen
        call    selftest
        jmp     v_quit
m_st:   cmp     byte [have_file], 0
        jne     m_file
        call    enter_help           ; no file: show the help page
        jmp     view_loop
m_file: call    load_file            ; CY=1 on error
        jnc     m_ok
        xor     al, al
        call    set_row
        mov     si, s_err_open
        call    puts
        mov     si, fname
        call    puts
        mov     si, s_errwd
        call    puts
        mov     di, numbuf
        mov     al, [open_err+1]
        call    hexdi
        mov     al, [open_err]
        call    hexdi
        mov     byte [di], 0
        mov     si, numbuf
        call    puts
        xor     ax, ax               ; wait for a key, then quit
        int     16h
        jmp     v_quit
m_ok:   call    detect_ku
        call    build_lines
        call    calc_limits
        jmp     view_loop

; detect_ku: KU files carry byte A3h or A5h over 2% of the first 4KB
detect_ku:
        mov     bx, dk_tab           ; 1 = A3h, 2 = A5h, 3 = end of text
        mov     byte [bx+0A3h], 1
        mov     byte [bx+0A5h], 2
        mov     byte [bx+000h], 3
        mov     byte [bx+01Ah], 3
        mov     es, [blk0]
        xor     si, si
        xor     di, di               ; A3h count
        xor     dx, dx               ; A5h count
        mov     cx, 4096
dk_l:   es lodsb
        xlat
        test    al, al
        jnz     dk_sp
dk_n:   loop    dk_l
        jmp     dk_d
dk_sp:  cmp     al, 3
        je      dk_d
        dec     al
        jnz     dk_5
        inc     di
        jmp     dk_n
dk_5:   inc     dx
        jmp     dk_n
dk_d:   mov     ax, 4096
        sub     ax, cx               ; bytes scanned
        mov     bx, dx
        xor     dx, dx
        mov     cx, 50
        div     cx                   ; threshold = 2% of scanned
        mov     cl, 1
        cmp     di, ax
        ja      set_ku
        cmp     bx, ax
        ja      set_ku
        dec     cx
        ; fall through: AL = 0 = TIS

; set_ku: CL = mode (0 TIS / 1 KU). Rebuilds trc: trc[b] = class<<8 | char
set_ku: mov     [ku_mode], cl
        push    es
        push    ds
        pop     es
        xor     bx, bx
        mov     di, trc
sk_l:   mov     al, bl
        test    al, al
        jns     sk_id                ; < 80h: never translated
        cmp     byte [ku_mode], 0
        je      sk_id
        push    bx
        mov     bx, ku_tab-80h
        xlat
        pop     bx
sk_id:  xor     ah, ah
        mov     si, ax
        mov     ah, [cls+si]
        stosw
        inc     bl
        jnz     sk_l
        pop     es
        ret

;---------------- help page (F1 / no parameter) -------------------------
; The help keeps its OWN line table, built once; the file's table survives.
enter_help:
        cmp     byte [help_mode], 0
        jne     eh_ret
        push    ds
        pop     es
        mov     si, top              ; save top/hshift/nlines/maxlen/ku_mode
        mov     di, sv_top
        mov     cx, 5
        rep     movsw
        mov     ax, [buf_end_seg]    ; save/replace the file's true-end
        mov     [sv_buf_end_seg], ax ; marker with the help text's own
        mov     ax, [buf_end_off]
        mov     [sv_buf_end_off], ax
        mov     ax, ds
        mov     [buf_end_seg], ax
        mov     word [buf_end_off], help_data+HELP_LEN
        mov     [blk0], ds           ; help bytes live in CS
        mov     ax, ds
        add     ax, 1000h
        mov     [blk_end], ax
        mov     word [hshift], 0
        xor     cx, cx
        call    set_ku               ; help is TIS
        mov     word [lin_base], help_lin_tab
        mov     word [lin_lim], help_lin_tab+HELP_LINEMAX*4
        mov     ax, [help_nlines]
        cmp     byte [help_built], 0
        jne     eh_have
        mov     word [build_start], help_data
        call    build_lines
        mov     word [build_start], 0
        mov     byte [help_built], 1
        mov     ax, [nlines]
        mov     [help_nlines], ax
eh_have:
        mov     [nlines], ax
        call    calc_limits          ; also recomputes maxh from help's own
        mov     byte [help_mode], 1  ; maxlen -- must not inherit the file's
eh_ret: ret

exit_help:
        cmp     byte [help_mode], 0
        je      eh_ret
        mov     byte [help_mode], 0
        push    ds
        pop     es
        mov     si, sv_top
        mov     di, top
        mov     cx, 5
        rep     movsw
        mov     ax, [sv_buf_end_seg]
        mov     [buf_end_seg], ax
        mov     ax, [sv_buf_end_off]
        mov     [buf_end_off], ax
        call    set_blk
        mov     cl, [ku_mode]
        call    set_ku
        call    calc_top
        mov     word [lin_base], lin_tab
        mov     word [lin_lim], LIN_LIM
        ret

; set_blk: file buffers = CS+1000h .. CS+8FFFh
set_blk:
        mov     ax, cs
        add     ax, 1000h
        mov     [blk0], ax
        add     ax, 8000h
        mov     [blk_end], ax
        ret

; calc_top: topmax = max(nlines - body, 0)
calc_top:
        mov     ax, [nlines]
        sub     al, [body]
        sbb     ah, 0
        jnc     ct1
        xor     ax, ax
ct1:    mov     [topmax], ax
        ret

; calc_limits: topmax, top/hshift = 0, maxh = max(maxlen-text_cols, 0)
; text_cols is mode-specific (80 for CGA/EGA/VGA, 90 for Hercules -- see
; vparm) so the scroll threshold matches what draw_line actually fits on
; screen in the active mode, not a fixed 80 that would falsely enable
; scroll on HGC for lines 81-90 columns wide (which fit HGC fine).
calc_limits:
        call    calc_top
        mov     word [top], 0
        mov     word [hshift], 0
        mov     ax, [maxlen]
        mov     bl, [text_cols]
        xor     bh, bh
        sub     ax, bx
        jnc     cl2
        xor     ax, ax
cl2:    mov     [maxh], ax
        ret

;---------------- viewer -----------------------------------------------
view_loop:
        call    redraw
v_key:  xor     ax, ax
        int     16h
        cmp     ah, 3Bh              ; F1 -> toggle help
        jne     v_nf1
        cmp     byte [help_mode], 0
        jne     v_fback
        call    enter_help
        jmp     view_loop
v_fback:
        call    exit_help
        jmp     view_loop
v_nf1:  test    al, al
        jnz     v_ascii
        mov     al, ah               ; extended key: scan code | 80h
        or      al, 80h
        jmp     v_look
v_ascii:
        cmp     byte [help_mode], 0
        je      v_a2
        cmp     byte [have_file], 0
        je      v_quit               ; demo help: any key quits
        jmp     v_fback              ; else: back to the file
v_a2:   cmp     al, 'A'
        jb      v_look
        or      al, 20h
v_look: push    ds
        pop     es
        mov     di, keytab
        mov     cx, KEYN
        repne   scasb
        jne     v_key
        mov     bx, di
        sub     bx, keytab+1
        shl     bx, 1
        jmp     [keyhnd+bx]

k_up:   mov     ax, [top]
        dec     ax
        jmp     k_scroll
k_dn:   mov     ax, [top]
        inc     ax
        jmp     k_scroll
k_pu:   mov     ax, [top]
        sub     al, [body]
        sbb     ah, 0
        jmp     k_scroll
k_pd:   mov     ax, [top]
        add     al, [body]
        adc     ah, 0
        jmp     k_scroll
k_home: xor     ax, ax
        jmp     k_scroll
k_end:  mov     ax, [topmax]
k_scroll:
        call    do_scroll
        jmp     v_key
k_left: mov     ax, [hshift]
        test    ax, ax
        jz      v_key
        sub     ax, 8                ; scroll 8 columns per press
        jnc     k_hs
        xor     ax, ax
        jmp     k_hs
k_right:
        mov     ax, [hshift]
        cmp     ax, [maxh]
        jae     v_key
        add     ax, 8
        cmp     ax, [maxh]
        jbe     k_hs
        mov     ax, [maxh]
k_hs:   mov     [hshift], ax
        jmp     view_loop
k_ku:   mov     cl, [ku_mode]        ; toggle KU decoding
        xor     cl, 1
        call    set_ku
        jmp     view_loop

v_quit: call    gfx_off
        mov     ax, 4C00h
        int     21h

;---------------- scrolling --------------------------------------------
; do_scroll: AX = wanted top (signed, unclamped). Blits the overlapping
; body rows within VRAM and redraws only the exposed rows + status digits;
; a change of a page or more is a full redraw.
do_scroll:
        test    ax, ax
        jns     ds_a
        xor     ax, ax
ds_a:   cmp     ax, [topmax]
        jbe     ds_b
        mov     ax, [topmax]
ds_b:   mov     dx, ax
        sub     dx, [top]            ; DX = delta (signed)
        jz      ds_ret
        mov     [top], ax
        mov     [sb_delta], dx
        mov     ax, dx
        jns     ds_c
        neg     ax
ds_c:   mov     cl, [body]
        xor     ch, ch
        cmp     ax, cx
        jb      ds_blit
        jmp     redraw               ; a page or more: full redraw
ds_blit:
        mov     cx, ax               ; CX = |delta| = exposed rows
        mov     al, 1                ; content moved down: rows 1..|delta|
        test    dx, dx
        js      ds_d
        mov     al, [body]           ; moved up: the last |delta| rows
        sub     al, cl
        inc     al
ds_d:   push    ax
        push    cx
        call    scroll_body
        pop     cx
        pop     ax
        call    draw_rows
        jmp     st_refresh
ds_ret: ret

; scroll_body: move the body rows by [sb_delta] lines (|delta| < body),
; one scanline at a time through the vrow_tab LUT (works in every mode).
scroll_body:
        mov     al, [body]
        xor     ah, ah
        sub     ax, cx               ; rows to move
        mov     cl, CELLH
        mul     cl                   ; AX = scanlines to move
        mov     cx, ax
        mov     ax, [sb_delta]
        mov     dl, CELLH
        imul    dl                   ; AX = delta*19 (signed)
        shl     ax, 1                ; *2: vrow_tab index delta
        mov     bp, CELLH*2          ; dst = row 1, src = row 1+delta
        mov     bx, bp
        add     bx, ax
        mov     dx, 2                ; ascending
        test    ax, ax
        jns     sb_go
        mov     bx, cx               ; moving down: start from the last line
        dec     bx
        shl     bx, 1
        add     bx, CELLH*2          ; src = last moved line
        mov     bp, bx
        sub     bp, ax               ; dst = src + |delta|*19
        mov     dx, -2               ; descending
sb_go:  mov     es, [vseg]
        push    ds
        mov     ds, [vseg]
sb_l:   mov     si, [cs:vrow_tab+bx]
        mov     di, [vrow_tab+bp]    ; (SS = CS)
        push    cx
        mov     cx, [cs:row_bytes]
        shr     cx, 1
        rep     movsw
        pop     cx
        add     bx, dx
        add     bp, dx
        loop    sb_l
        pop     ds
        ret

; draw_rows: draw screen rows AL .. AL+CL-1
draw_rows:
        push    ax
        push    cx
        call    draw_row
        pop     cx
        pop     ax
        inc     al
        loop    draw_rows
        ret

; draw_row: draw file line [top]+AL-1 on screen row AL (if it exists)
draw_row:
        mov     [dl_row], al
        xor     ah, ah
        dec     ax
        add     ax, [top]
        cmp     ax, [nlines]
        jb      dr_ok
        mov     al, [dl_row]         ; past the end: blank row
        call    set_row
        xor     bp, bp
        mov     dx, [row_bytes]
        jmp     dl_blank
dr_ok:
        shl     ax, 1
        shl     ax, 1
        add     ax, [lin_base]
        mov     bx, ax
        mov     ax, [bx]
        mov     [dl_seg], ax
        mov     ax, [bx+2]
        mov     [dl_off], ax
        jmp     draw_line

;---------------- screen redraw ----------------------------------------
redraw: mov     byte [r_len], 0      ; forces a full status bar
        mov     al, 1                ; body starts below the status row
        mov     cl, [body]
        xor     ch, ch               ; CH must not carry stale bits into
                                      ; draw_rows' "loop" (full CX, not CL)
        call    draw_rows
        ; fall through into st_refresh (r_len = 0 forces the full bar)

;---------------- status bar -------------------------------------------
; st_refresh: repaint only the R: digits when their length is unchanged
; (band columns + glyphs of that span), otherwise the whole bar.
st_refresh:
        call    fmt_digits           ; numbuf = "a-b", AL = length
        cmp     al, [r_len]
        jne     st_full
        mov     bl, [r_c0]
        xor     bh, bh
        mov     bp, bx               ; first byte column of the digits
        cbw
        mov     dx, ax               ; byte count
        call    vband                ; white band across the digit span
        call    st_begin
        mov     al, [r_c0]
        mov     [cur_col], al
        mov     si, numbuf
        call    puts
st_end: mov     byte [inv_flag], 0
        ret
st_full:
        mov     [r_len], al
        xor     bp, bp
        mov     dx, [row_bytes]
        call    vband
        call    st_begin
        mov     byte [cur_col], 0
        mov     si, st_tpl
        call    puts_tpl
        ; ---- right-aligned hint block (bold codes are invisible) ----
        mov     si, stl_right
        xor     cx, cx
rs_len: lodsb
        test    al, al
        jz      rs_d
        cmp     al, 02h
        je      rs_len
        inc     cx
        jmp     rs_len
rs_d:   mov     al, [text_cols]
        sub     al, cl
        mov     [cur_col], al
        mov     si, stl_right
        call    puts
        jmp     st_end

; st_begin: inverse text at row 0
st_begin:
        mov     byte [inv_flag], 0FFh
        mov     byte [style_reg], 0
        xor     al, al
        jmp     set_row

; vband: white band rows 0..CELLH-1, byte columns [BP, BP+DX)
vband:  xor     bx, bx
        mov     cx, CELLH
        mov     al, 0FFh
        ; fall through
; fill_rows: fill CX scanlines from vrow_tab index BX (=2*y) with byte AL,
;            byte columns [BP, BP+DX)
fill_rows:
        mov     es, [vseg]
        mov     ah, al
fr_l:   mov     di, [vrow_tab+bx]
        add     di, bp
        push    cx
        mov     cx, dx
        shr     cx, 1
        rep     stosw
        jnc     fr_1
        stosb
fr_1:   pop     cx
        inc     bx
        inc     bx
        loop    fr_l
        ret

; puts_tpl: like puts, but 01h = file name, 03h = hshift, 04h = R digits
;           (records their column), 06h = KU/TIS label
puts_tpl:
        lodsb
        test    al, al
        jz      pt_ret
        cmp     al, 01h
        jne     pt_2
        push    si
        mov     si, fname
pt_p:   call    puts
        pop     si
        jmp     puts_tpl
pt_2:   cmp     al, 03h
        jne     pt_3
        push    si
        mov     ax, [hshift]
        mov     di, numbuf
        call    dec_word
        mov     byte [di], 0
pt_n:   mov     si, numbuf
        jmp     pt_p
pt_3:   cmp     al, 04h
        jne     pt_4
        mov     al, [cur_col]
        mov     [r_c0], al
        push    si
        call    fmt_digits
        jmp     pt_n
pt_4:   cmp     al, 06h
        jne     pt_5
        push    si
        mov     si, sw_tis
        cmp     byte [ku_mode], 0
        je      pt_p
        mov     si, sw_ku
        jmp     pt_p
pt_5:   call    draw_char
        jmp     puts_tpl
pt_ret: ret

; fmt_digits: numbuf = "<top+1>-<last row>", AL = length
fmt_digits:
        mov     di, numbuf
        mov     ax, [top]
        inc     ax
        call    dec_word
        mov     byte [di], '-'
        inc     di
        mov     ax, [top]
        add     al, [body]
        adc     ah, 0                ; 1-based last row on screen
        cmp     ax, [nlines]
        jbe     fd1
        mov     ax, [nlines]         ; clamp at end of file
fd1:    call    dec_word
        mov     byte [di], 0
        mov     ax, di
        sub     ax, numbuf
        ret

; dec_word: write AX as decimal at [DI], advance DI
dec_word:
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
dw1:    xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     dw1
dw2:    pop     ax
        add     al, '0'
        mov     [di], al
        inc     di
        loop    dw2
        pop     dx
        pop     cx
        pop     bx
        ret

; hexdi: write AL as 2 hex chars at [DI]
hexdi:  push    ax
        push    cx
        mov     cl, 4
        shr     al, cl
        call    hexn
        pop     cx
        pop     ax
        push    ax
        and     al, 0Fh
        call    hexn
        pop     ax
        ret
hexn:   add     al, '0'
        cmp     al, '9'
        jbe     hn1
        add     al, 'A'-'0'-10
hn1:    mov     [di], al
        inc     di
        ret

;---------------- line renderer ----------------------------------------
; draw_line: render line [dl_seg]:[dl_off] at row [dl_row] with [hshift]
draw_line:
        mov     byte [style_reg], 0  ; styles are line-local
        mov     byte [exp_prev], 0
        mov     byte [tab_run], 0    ; no tab expansion owed at line start
        mov     al, [dl_row]
        call    set_row
        mov     bx, [cur_y2]
        mov     bx, [vrow_tab+bx]
        mov     [dl_vrow], bx        ; VRAM offset of the row's first scanline
        mov     byte [cur_col], 0
        mov     byte [cell_has], 0
        mov     es, [dl_seg]
        mov     si, [dl_off]
        mov     cx, [hshift]
        jcxz    dl_skm
        xor     dx, dx               ; columns consumed
        ; --- skip hshift columns (style-aware: style codes toggle the
        ;     running style and eat 0 columns, marks eat 0 columns,
        ;     a base eats 1 column, or 2 when expanded) ---
dl_sk:  RDCH
        test    ah, C_TERM
        jnz     dl_done
        test    ah, C_STYLE
        jz      dl_sk1
        call    style_toggle
        jmp     dl_sk
dl_sk1: test    ah, C_SWAL|C_COMB
        jnz     dl_sk
        inc     dx
        test    byte [style_reg], 02h
        jz      dl_sk2
        inc     dx                   ; expanded base = 2 columns
dl_sk2: cmp     dx, cx
        jb      dl_sk
        ; skip the trailing marks of the last skipped base / leading marks
dl_skm: call    peek
        test    ah, C_TERM
        jnz     dl_done
        test    ah, C_COMB
        jz      dl_go
        call    adv
        jmp     dl_skm
dl_go:  mov     cl, 255              ; guard: max bytes per line
        call    dl_fix               ; CH = fast path ok, dl_vdi = VRAM ptr
dl_l:   mov     al, [cur_col]
        cmp     al, [text_cols]
        jae     dl_ovf               ; past the right edge: marks only
        RDCH
        test    ah, C_TERM
        jnz     dl_done
        test    ah, ah
        jnz     dl_slow
        test    ch, ch
        jz      dl_slow
        ; ---- fast path: plain base, no style, planar, not inverse:
        ;      blit the font glyph straight to VRAM ----
        push    si
        push    es
        mov     bx, ax               ; AH = class = 0
        shl     bx, 1
        mov     si, [gofs+bx]        ; glyph
        mov     [cell_src], si       ; a following mark composes on it
        mov     di, [dl_vdi]
        mov     es, [vseg]
%rep CELLH-1
        movsb
        add     di, 79
%endrep
        movsb
        pop     es
        pop     si
        inc     word [dl_vdi]
        inc     byte [cur_col]
        mov     word [cell_has], 0001h   ; cell_has = 1, exp_prev = 0
        dec     cl
        jnz     dl_l
dl_done:                             ; every cell up to cur_col was written:
        mov     al, [text_cols]      ; blank the rest of the row
        sub     al, [cur_col]
        jbe     dl_ret
        xor     ah, ah
        mov     dx, ax
        mov     al, [cur_col]
        mov     bp, ax
dl_blank:
        mov     bx, [cur_y2]
        mov     cx, CELLH
        xor     al, al
        jmp     fill_rows
dl_ret: ret
dl_slow:
        call    draw_char_c
        call    dl_fix
        dec     cl
        jnz     dl_l
        jmp     dl_done

; dl_fix: after a slow-path byte: CH = fast path allowed (planar and no
;         style active), dl_vdi = VRAM address of the current cell
dl_fix: mov     al, [cur_col]
        xor     ah, ah
        add     ax, [dl_vrow]
        mov     [dl_vdi], ax
        mov     ch, [planar]
        cmp     byte [style_reg], 0
        je      df_r
        xor     ch, ch
df_r:   ret
dl_ovf: RDCH
        test    ah, C_TERM
        jnz     dl_done
        test    ah, C_COMB
        jz      dl_cnt
        call    draw_char_c          ; mark: still drawn on the last cell
        jmp     dl_ovf
dl_cnt: cmp     byte [cur_col], 255  ; off-screen base: count only
        je      dl_ovf               ; (saturate: the count must not wrap)
        inc     byte [cur_col]
        jmp     dl_ovf

; peek: AL/AH = translated char/class at ES:SI (no advance)
peek:   mov     bx, es
        cmp     bx, [buf_end_seg]
        jne     pk_rd
        cmp     si, [buf_end_off]
        jne     pk_rd
        mov     ah, C_TERM           ; true end of loaded text
        ret
pk_rd:  mov     al, [es:si]
        xor     ah, ah
        mov     bx, ax
        shl     bx, 1
        mov     ax, [trc+bx]
        ret
; adv: SI++ with block wrap
adv:    inc     si
        jnz     adv_r
        mov     ax, es
        add     ax, 1000h
        mov     es, ax
adv_r:  ret

; style_toggle: apply style code AL to [style_reg]
style_toggle:
        xor     ah, ah
        mov     bx, ax
        mov     al, [stx+bx]         ; xor mask
        test    al, 30h              ; sub/super clear each other
        jz      st_x
        mov     ah, al
        xor     ah, 30h
        not     ah
        and     [style_reg], ah
st_x:   xor     [style_reg], al
        ret

;---------------- text layer -------------------------------------------
; puts: draw ASCIZ string [SI] at cur_row/cur_col
puts:   mov     byte [cell_has], 0
puts_j: lodsb
        test    al, al
        jz      puts_d
        call    draw_char
        jmp     puts_j
puts_d: ret

; set_row: AL = text row -> cur_row, cur_y2 (= row*19*2, vrow_tab index)
set_row:
        mov     [cur_row], al
        xor     ah, ah
        shl     ax, 1
        mov     bx, ax
        shl     ax, 1
        add     bx, ax               ; 6r
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1                ; 32r
        add     ax, bx               ; 38r
        mov     [cur_y2], ax
        ret

;---------------- cell renderer ----------------------------------------
; draw_char: AL = raw byte (not translated). Preserves SI, CX, ES.
draw_char:
        xor     ah, ah
        mov     bx, ax
        mov     ah, [cls+bx]
; draw_char_c: AL = char, AH = class
draw_char_c:
        test    ah, C_STYLE
        jnz     style_toggle
        test    ah, C_SWAL|C_TERM
        jnz     dc_ret               ; invisible, eats nothing
        test    ah, C_COMB
        jz      dc_base
        cmp     byte [cell_has], 0
        je      dc_base              ; mark with no base: draw as a base
        ; ---- combining mark: OR into the current cell, redraw it ----
        push    si
        push    cx
        push    es
        push    ds
        pop     es
        mov     ah, [exp_prev]
        inc     ah
        mov     [back], ah           ; 1 normal, 2 after an expanded base
        cmp     word [cell_src], cell_buf
        je      dc_m1
        push    ax
        mov     si, [cell_src]       ; first mark: materialise the cell
        mov     di, cell_buf
        mov     cx, CELLH
        rep     movsb
        mov     word [cell_src], cell_buf
        pop     ax
dc_m1:  call    glyph_ptr
        mov     di, cell_buf
        mov     cx, CELLH/2
dc_o:   lodsw
        or      [di], ax
        inc     di
        inc     di
        loop    dc_o
        lodsb
        or      [di], al
        call    dc_draw
        pop     es
        pop     cx
        pop     si
dc_ret: ret

; dc_base: AL = base char: draw it at cur_col, advance
dc_base:
        push    si
        push    cx
        push    es
        call    glyph_ptr
        mov     [cell_src], si
        mov     byte [back], 0
        call    dc_draw
        pop     es
        pop     cx
        pop     si
        mov     byte [cell_has], 1
        inc     byte [cur_col]
        mov     byte [exp_prev], 0
        test    byte [style_reg], 02h
        jz      dc_ret
        mov     byte [exp_prev], 1   ; marks after this cell shift back by 2
        inc     byte [cur_col]       ; expanded char occupies 2 columns
        ret

; glyph_ptr: AL = char -> SI = font glyph (19 bytes)
glyph_ptr:
        xor     ah, ah
        mov     si, ax
        shl     si, 1
        mov     si, [gofs+si]
        ret

; dc_draw: draw cell [cell_src] at column cur_col-[back], row cur_row,
;          with the current style; nothing is drawn beyond text_cols.
dc_draw:
        mov     al, [cur_col]
        sub     al, [back]
        jnc     dd1
        xor     al, al
dd1:    xor     ah, ah
        mov     bp, ax               ; column = byte column
        mov     bx, [cur_y2]
        mov     si, [cell_src]
        mov     dl, [inv_flag]
        mov     ah, [style_reg]
        test    ah, ah
        jnz     dd_sty
        cmp     al, [text_cols]
        jae     dd_ret
        jmp     put_glyph
dd_sty: push    ax
        push    ds
        pop     es
        mov     di, cell_tmp         ; cell_tmp = styled copy of the cell
        mov     cx, CELLH
        rep     movsb
        mov     si, [cell_src]
        call    apply_style
        pop     ax
        mov     bx, [cur_y2]
        mov     si, cell_tmp
        test    ah, 02h
        jnz     dd_wide
        cmp     al, [text_cols]
        jae     dd_ret
        jmp     put_glyph
dd_wide:
        mov     dh, [text_cols]
        dec     dh
        cmp     al, dh
        ja      dd_ret
        jmp     put_wide             ; DH = last column: right half only
dd_ret: ret

; apply_style: transform cell_tmp per AH = style_reg (SI = unstyled cell)
apply_style:
        test    ah, 01h              ; ---- bold
        jz      as_shear
        xor     bx, bx
as_b1:  mov     al, [cell_tmp+bx]
        shr     al, 1
        or      [cell_tmp+bx], al
        inc     bx
        cmp     bl, CELLH
        jb      as_b1
as_shear:
        test    ah, 40h              ; ---- italic shear (in-cell)
        jz      as_sub
        xor     bx, bx
as_s1:  mov     cl, 2                ; rows 0-3 >>2, 4-11 >>1, 12-18 >>0
        cmp     bl, 4
        jb      as_s2
        dec     cl
        cmp     bl, 12
        jb      as_s2
        dec     cl
as_s2:  shr     byte [cell_tmp+bx], cl
        inc     bx
        cmp     bl, CELLH
        jb      as_s1
as_sub: test    ah, 10h              ; ---- subscript: shift down 3
        jz      as_sup
        mov     bx, 15
as_u1:  mov     al, [cell_tmp+bx]
        mov     [cell_tmp+bx+3], al
        dec     bx
        jns     as_u1
        mov     word [cell_tmp], 0
        mov     byte [cell_tmp+2], 0
as_sup: test    ah, 20h              ; ---- superscript: shift up 5
        jz      as_ul
        mov     bx, 5
as_p1:  mov     al, [cell_tmp+bx]
        mov     [cell_tmp+bx-5], al
        inc     bx
        cmp     bl, CELLH
        jb      as_p1
        mov     word [cell_tmp+14], 0
        mov     word [cell_tmp+16], 0
        mov     byte [cell_tmp+18], 0
as_ul:  test    ah, 08h              ; ---- underline single
        jz      as_ret
        cmp     byte [si+17], 0      ; descender/lower-mark ink on the
        jnz     as_ret               ; rule row: skip it
        mov     byte [cell_tmp+17], 0FFh
        test    ah, 04h              ; ---- underline double
        jz      as_ret
        cmp     byte [si+18], 0
        jnz     as_ret
        mov     byte [cell_tmp+18], 0FFh
as_ret: ret

; put_glyph: blit 19 rows [SI] at vrow_tab index BX, byte column BP,
;            DL = 0 normal / FFh inverse. Clobbers AX CX DI ES.
put_glyph:
        mov     es, [vseg]
        test    dl, dl
        jnz     pg_lut
        cmp     byte [planar], 0
        je      pg_lut
        mov     di, [vrow_tab+bx]    ; planar: 80 bytes per scanline
        add     di, bp
%rep CELLH-1
        movsb
        add     di, 79
%endrep
        movsb
        ret
pg_lut: mov     cx, CELLH            ; interleaved (or inverse): LUT per row
pg_l:   mov     di, [vrow_tab+bx]
        lodsb
        xor     al, dl
        mov     [es:bp+di], al
        inc     bx
        inc     bx
        loop    pg_l
        ret

; put_wide: blit [SI] pixel-doubled (16 px wide); DH = last text column
put_wide:
        push    ds
        pop     es
        mov     di, cell_wide
        mov     cx, CELLH
        cmp     al, dh
        mov     dx, bx               ; keep the vrow_tab index (BX -> tables)
        je      pw_last
pw_s:   lodsb                        ; stretch: 8 px -> 16 px
        mov     ah, al
        mov     bx, tbl_hi
        xlat
        stosb
        mov     al, ah
        mov     bx, tbl_lo
        xlat
        stosb
        loop    pw_s
        mov     bx, dx
        mov     es, [vseg]
        mov     si, cell_wide
        mov     cx, CELLH
pw_b:   mov     di, [vrow_tab+bx]
        add     di, bp
        movsw
        inc     bx
        inc     bx
        loop    pw_b
        ret
pw_last:                             ; last column: left halves only
        lodsb
        mov     bx, tbl_hi
        xlat
        stosb
        loop    pw_last
        mov     bx, dx
        mov     si, cell_wide
        xor     dl, dl
        jmp     put_glyph

;---------------- file load --------------------------------------------
load_file:
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jnc     lf_ok
        mov     [open_err], ax       ; real DOS error code for the status line
        stc
        ret
lf_ok:  mov     bx, ax               ; BX = handle
        call    set_blk
        mov     si, [blk0]
lf_r:   push    ds
        mov     ds, si               ; DS = block segment
        xor     dx, dx
        call    lf_rd                ; first half
        jc      lf_err
        cmp     ax, cx
        jb      lf_sh
        mov     dx, cx               ; second half at 8000h
        call    lf_rd
        jc      lf_err
        cmp     ax, cx
        jb      lf_sh
        pop     ds
        add     si, 1000h
        cmp     si, [blk_end]
        jb      lf_r
        ; all blocks full: force-terminate the last block (loses 2 bytes)
        sub     si, 1000h
        push    ds
        mov     ds, si
        mov     word [0FFFEh], 0
        pop     ds
        mov     [buf_end_seg], si    ; record the true end (not just the
        mov     word [buf_end_off], 0FFFEh  ; sentinel byte) build_lines/
        jmp     lf_close                    ; draw_line stop at
lf_sh:  mov     di, ax               ; short read: terminate here
        add     di, dx
        mov     byte [di], 0
        mov     bx, ds               ; DS = block segment; save before pop
        pop     ds
        mov     [buf_end_seg], bx
        mov     [buf_end_off], di
lf_close:
        mov     ah, 3Eh
        int     21h
        clc
        ret
lf_err: pop     ds
        mov     ah, 3Eh
        int     21h
        stc
        ret
lf_rd:  mov     cx, 8000h
        mov     ah, 3Fh
        int     21h
        ret

;---------------- line table build -------------------------------------
build_lines:
        mov     word [nlines], 1
        mov     word [maxlen], 0     ; a fresh table starts its own max fresh
        mov     es, [blk0]           ; -- must not inherit whatever table
                                      ; (file or help) was scanned last
        mov     si, [build_start]
        mov     di, [lin_base]
        mov     [di], es
        mov     [di+2], si
        add     di, 4                ; DI = next table entry
        xor     bx, bx
        xor     dx, dx               ; DL = columns in this line (caps at 255)
bl_l:   mov     cx, es               ; true end of loaded text? (00/1A inside
        cmp     cx, [buf_end_seg]    ; the file are ordinary content, not
        jne     bl_rd                ; EOF -- only this recorded position is)
        cmp     si, [buf_end_off]
        je      bl_done
bl_rd:  mov     al, [es:si]
        inc     si
        jz      bl_wrap
bl_c:   mov     bl, al
        mov     ah, [cls+bx]         ; raw byte class
        test    ah, ah
        jnz     bl_sp
bl_cnt: inc     dl                   ; column
        jnz     bl_l
        dec     dl                   ; line size cap = 255
        jmp     bl_l
bl_wrap:
        mov     ax, es               ; text continues in the next block
        add     ax, 1000h
        mov     es, ax
        jmp     bl_c
bl_sp:  test    ah, C_TERM
        jnz     bl_term
        test    ah, C_TAB            ; tab = 8 columns at once (RDCH expands
        jnz     bl_tab               ; it to 8 draws; count needs to match)
        jmp     bl_l                 ; C_STYLE/C_SWAL/C_COMB: zero-width, same
                                      ; as draw_line (style_toggle/swallowed/
                                      ; combining marks never advance cur_col) --
                                      ; a line of exactly N visible columns
                                      ; must not report maxlen > N just because
                                      ; it also carries style toggle bytes
bl_tab: mov     al, dl
        add     al, 8
        jnc     bl_tabok
        mov     al, 255              ; saturate, same rule as bl_cnt's wrap
bl_tabok:
        mov     dl, al
        jmp     bl_l
bl_term:                             ; 0D/0A/1A carry C_TERM now
        cmp     al, 0Dh
        je      bl_cr
        cmp     al, 0Ah
        je      bl_lf
        jmp     bl_done              ; 1A (^Z): stop scanning here, like EOF
bl_cr:  cmp     byte [es:si], 0Ah    ; CR LF = one break
        jne     bl_lf
        call    adv
bl_lf:  call    bl_close
        cmp     di, [lin_lim]        ; table full: keep scanning, no entry
        jae     bl_l
        inc     word [nlines]
        mov     [di], es
        mov     [di+2], si
        add     di, 4
        jmp     bl_l
bl_done:
        ; fall through
bl_close:
        cmp     dl, [maxlen]
        jbe     bc1
        mov     [maxlen], dl
bc1:    xor     dl, dl
        ret

;---------------- command tail -----------------------------------------
parse_tail:
        mov     si, 81h
pt_scan:
        lodsb
        cmp     al, 0Dh
        je      pt_done
        test    al, al
        jz      pt_done
        cmp     al, ' '
        je      pt_scan
        cmp     al, '/'
        je      pt_sw
        mov     di, fname            ; file name token
pt_f:   mov     [di], al
        inc     di
        lodsb
        cmp     al, 0Dh
        je      pt_fend
        test    al, al
        jz      pt_fend
        cmp     al, ' '
        jne     pt_f
pt_fend:
        mov     byte [di], 0
        mov     byte [have_file], 1
        dec     si
        jmp     pt_scan
pt_sw:  lodsb                        ; /v /c /e /h /t
        or      al, 20h
        push    ds
        pop     es
        mov     di, sw_chars
        mov     cx, 5
        repne   scasb
        jne     pt_scan
        sub     di, sw_chars+1
        cmp     di, 4
        jne     pt_adp
        mov     byte [test_mode], 1
        jmp     pt_scan
pt_adp: mov     al, [sw_adap+di]
        mov     [adapter], al
        mov     byte [forced], 1
        jmp     pt_scan
pt_done:
        ret

;---------------- selftest (/t) -----------------------------------------
selftest:
        mov     bx, 22*2             ; scanline 22 solid (proves VRAM writes)
        call    st_line
        xor     al, al
        call    set_row
        mov     si, s_selft
        call    puts
        mov     bx, CELLH*2          ; rule under the status row
        call    st_line
        mov     al, 2
        call    set_row
        mov     byte [cur_col], 0
        mov     si, s_ok
        call    puts
        xor     ah, ah               ; "press a key": wait, no 15s timer
        int     16h
        ret
st_line:
        mov     cx, 1
        mov     al, 0FFh
        xor     bp, bp
        mov     dx, [row_bytes]
        jmp     fill_rows

;---------------- video HAL ---------------------------------------------
; [adapter]: 0 CGA / 1 EGA / 2 VGA / 3 HGC
detect_video:
        push    ds                   ; BIOS mode byte 40:49h: 7 = mono
        xor     ax, ax
        mov     ds, ax
        mov     bl, [449h]
        pop     ds
        mov     al, 3
        cmp     bl, 7
        je      dv_set               ; mono text -> Hercules path
        mov     ax, 1A00h
        int     10h
        cmp     al, 1Ah
        mov     al, 2
        je      dv_set               ; VGA
        push    ds                   ; EGA BIOS flags 40:87h: non-zero
        xor     ax, ax               ; when an EGA (or better) posts
        mov     ds, ax
        mov     bh, [487h]
        pop     ds
        mov     al, 1
        test    bh, bh
        jnz     dv_set               ; EGA
        ; Hercules toggle test: port 3BA bit 7 (vsync) pulses on HGC
        mov     dx, 3BAh
        in      al, dx
        and     al, 80h
        mov     ah, al
        mov     cx, 7FFFh
dhg1:   in      al, dx
        and     al, 80h
        cmp     al, ah
        loopz   dhg1
        mov     al, 0                ; CGA
        jz      dv_set
        mov     al, 3                ; bit changed -> HGC present
dv_set: mov     [adapter], al
        ret

gfx_on: mov     al, [adapter]
        mov     ah, VPARM_SZ
        mul     ah
        add     ax, vparm
        mov     si, ax
        mov     di, mode_num         ; copy the mode parameters
        mov     cx, VPARM_SZ
        push    ds
        pop     es
        rep     movsb
        cmp     byte [adapter], 3
        jne     go_bios
        mov     dx, 3BFh             ; HGC: enable graphics + both pages
        mov     al, 3
        out     dx, al
        mov     dx, 3B8h
        mov     al, 2                ; graphics mode, video off
        out     dx, al
        mov     dx, 3B4h             ; program 6845 CRTC R0..R11
        mov     si, hgc_crtc
        mov     cx, 12
        xor     ah, ah
gh1:    mov     al, ah
        out     dx, al
        inc     dx
        lodsb
        out     dx, al
        dec     dx
        inc     ah
        loop    gh1
        call    go_tab               ; (needs vrow_tab? no - just clears)
        jmp     clear_screen         ; HGC: clear, then video on
go_bios:
        mov     ah, 0
        mov     al, [mode_num]
        int     10h
        cmp     byte [planar], 0
        je      go_tab
        mov     dx, 3CEh             ; GDC: SR=0, ESR=0, rotate 0, write
        mov     si, gdc_tab          ;      mode 0, bitmask FF - from here
        mov     cx, 5                ;      on all drawing is plain writes
gd1:    lodsw
        out     dx, ax
        loop    gd1
go_tab: ; vrow_tab[y] = VRAM offset of scanline y (banks for CGA/HGC)
        mov     word [vrt_val+2], 2000h
        mov     word [vrt_val+4], 4000h
        mov     word [vrt_val+6], 6000h
        xor     dx, dx               ; y
        mov     di, vrow_tab
        mov     cx, 512
vrt_l:  mov     bx, dx
        and     bx, [bank_mask]
        shl     bx, 1
        mov     ax, [vrt_val+bx]
        stosw
        add     ax, [row_bytes]
        mov     [vrt_val+bx], ax
        inc     dx
        loop    vrt_l
        ret

gfx_off:
        cmp     byte [adapter], 3
        jne     gf1
        mov     dx, 3B8h             ; HGC: back to text mode first
        mov     al, 28h
        out     dx, al
        mov     dx, 3BFh
        mov     al, 0
        out     dx, al
gf1:    mov     ah, 0
        mov     al, [old_mode]
        int     10h
        ret

clear_screen:
        mov     es, [vseg]
        xor     di, di
        mov     cx, [vram_size]
        shr     cx, 1
        xor     ax, ax
        rep     stosw
        cmp     byte [adapter], 3
        jne     cs_ret
        mov     dx, 3B8h             ; HGC: video on after the clear
        mov     al, 0Ah
        out     dx, al
cs_ret: ret

;---------------- data --------------------------------------------------
; mode parameters: mode, vseg, bank_mask, row_bytes, text_cols, body,
;                  vram_size, planar   (copied over mode_num..planar)
vparm:  db 06h
        dw 0B800h, 1, 80
        db 80, 9
        dw 4000h
        db 0                          ; CGA 640x200
        db 10h
        dw 0A000h, 0, 80
        db 80, 17
        dw 6D60h
        db 1                          ; EGA 640x350
        db 12h
        dw 0A000h, 0, 80
        db 80, 24
        dw 9600h
        db 1                          ; VGA 640x480
        db 0
        dw 0B000h, 3, 90
        db 90, 17
        dw 8000h
        db 0                          ; HGC 720x348
gdc_tab: dw 0000h, 0001h, 0003h, 0005h, 0FF08h
hgc_crtc:                             ; 6845 R0..R11 for 720x348 gfx
        db 35h, 2Dh, 2Eh, 07h, 5Bh, 02h, 57h, 57h, 02h, 03h, 00h, 00h
sw_chars: db "vceht"
sw_adap:  db 2, 0, 1, 3

; byte classes for 00h-1Fh
; 00 is a content byte some real files embed mid-line (e.g. a table row
; built from filler/box glyphs) -- swallow it like any other control
; instead of treating it as end-of-file; only 0D/0A end a line, 1A (^Z)
; keeps its conventional "rest of file is not real content" meaning, and
; buf_end_seg/off (see RDCH) ends the text. 09 (tab) expands to 8 spaces
; (RDCH does the expansion; build_lines counts it as 8 columns directly).
cls_lo: db C_SWAL, C_SWAL, C_STYLE, C_SWAL, C_SWAL, C_STYLE, C_SWAL, C_SWAL
        db 0, C_TAB, C_TERM, 0, 0, C_TERM, C_STYLE, C_STYLE
        db 0, 0, C_STYLE, C_STYLE, C_STYLE, C_STYLE, C_STYLE, C_STYLE
        db 0, 0, C_TERM, C_SWAL, C_SWAL, C_SWAL, C_SWAL, C_SWAL
; byte classes for D1h-EEh (Thai combining marks)
cls_hi: db C_COMB, 0, 0, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB
        db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB
; style_reg xor masks per style code 00h-17h
stx:    db 0, 0, 01h, 0, 0, 02h, 0, 0, 0, 0, 0, 0, 0, 0, 10h, 20h
        db 0, 0, 0Ch, 08h, 20h, 40h, 10h, 40h
; nibble -> pixel-doubled byte (expanded style)
nib16:  db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh

; key table: extended keys = scan code | 80h, ASCII keys lower-cased
keytab: db 0C8h, 0D0h, 0C9h, 0D1h, 0C7h, 0CFh, 0CBh, 0CDh, 'q', 1Bh, 'c', ' ', 08h, 'r'
KEYN    equ $-keytab
keyhnd: dw k_up, k_dn, k_pu, k_pd, k_home, k_end, k_left, k_right
        dw v_quit, v_quit, k_ku, k_pd, k_pu, view_loop

; status bar template: 01 = file name, 03 = hshift, 04 = R digits, 06 = KU/TIS
st_tpl: db 02h, 01h, 02h, ' ', 02h, "C:", 02h, 03h, ' ', 02h, "R:", 02h, 04h, ' ', 02h, 06h, 02h, 0

%include "STRS.INC"
%include "KU.INC"
%include "STATUS.INC"

packed: incbin "packed.bin"           ; AXV.FON + HELP.TXT, run-length packed

;---------------- uninitialised data (zeroed at start) -------------------
        section .bss
bss_start:
font8x19    resb FONT_LEN             ; 256 glyphs x 19 rows
help_data   resb HELP_LEN             ; help text (TIS-620 + style codes) + 0
cls         resb 256                  ; byte class per raw byte
trc         resw 256                  ; class<<8 | translated char (KU aware)
vrow_tab    resw 512                  ; VRAM offset of every scanline
gofs        resw 256                  ; font glyph address per char
tbl_hi      resb 256                  ; byte -> high nibble pixel-doubled
tbl_lo      resb 256                  ; byte -> low nibble pixel-doubled
dk_tab      resb 256                  ; detect_ku byte classes
vrt_val     resw 4
cell_buf    resb CELLH                ; composed cell (base | marks)
cell_tmp    resb CELLH                ; styled copy
cell_wide   resb CELLH*2              ; pixel-doubled cell
numbuf      resb 16
fname       resb 66
help_lin_tab resb HELP_LINEMAX*4
; --- mode parameters (filled from vparm, keep the order) ---
mode_num    resb 1
vseg        resw 1
bank_mask   resw 1
row_bytes   resw 1
text_cols   resb 1
body        resb 1                    ; body rows (status is row 0)
vram_size   resw 1
planar      resb 1
; --- viewer state; top..ku_mode is saved/restored around the help ---
top         resw 1
hshift      resw 1
nlines      resw 1
maxlen      resw 1
ku_mode     resw 1
sv_top      resw 5
sv_buf_end_seg resw 1                 ; saved across the help overlay
sv_buf_end_off resw 1
topmax      resw 1
maxh        resw 1
blk0        resw 1                    ; first / one-past-last text block
blk_end     resw 1
build_start resw 1
buf_end_seg resw 1                    ; true end of loaded text (seg:off) --
buf_end_off resw 1                    ; authoritative, not a sentinel byte
tab_run     resb 1                    ; RDCH: spaces still owed from a tab
lin_base    resw 1                    ; active line table (file or help)
lin_lim     resw 1                    ; one past the last table entry
help_nlines resw 1
open_err    resw 1
sb_delta    resw 1
cur_y2      resw 1                    ; cur_row*19*2
cell_src    resw 1                    ; font glyph or cell_buf
dl_seg      resw 1
dl_off      resw 1
dl_vrow     resw 1                    ; VRAM offset of the current row
dl_vdi      resw 1                    ; VRAM address of the current cell
old_mode    resb 1
forced      resb 1
adapter     resb 1
test_mode   resb 1
have_file   resb 1
help_mode   resb 1
help_built  resb 1
cur_col     resb 1
cur_row     resb 1
cell_has    resb 1
exp_prev    resb 1                    ; last base was expanded
back        resb 1
style_reg   resb 1
inv_flag    resb 1                    ; 0 / FFh xor mask
dl_row      resb 1
r_c0        resb 1                    ; status: column / length of R digits
r_len       resb 1
            alignb 2
bss_end:
lin_tab     equ bss_end               ; line table grows upward from here
LIN_LIM     equ 0F000h                ; ... up to here (stack lives above)
