;-----------------------------------------------------------------------
; READ.COM -- Thai text reader, CGA / EGA / VGA / HGC, 8x19 font (8086)
;
;   read file.txt [/v|/e|/c|/h]
;
;   keys:  Up/Dn = 1 line      PgUp/PgDn = page (Space/BS too)
;          Home/End = top/bottom
;          Left/Right = horizontal scroll 8 cols (long lines)
;          c = toggle Kaset-RW <-> TIS-620 decoding (live)
;          q / Esc = quit
;
; File is loaded into up to 8 x 64KB blocks (INT 21 AH=48),
; a line table (seg:off per line) is built at lin_tab.
; Assemble: nasm -f bin read.asm -o read.com
;-----------------------------------------------------------------------
        cpu 8086
        ; NOTE: NASM 3.02 (2026) IGNORES the 'org' directive in -f bin — the
        ; image is emitted from address 0. We pad to 0100h instead and strip
        ; the first 0x100 bytes after build (build_read.py does this), so
        ; every label lands at its real DOS load address (file byte 0 -> CS:0100).
        times 100h db 0

GDC     equ 3CEh
LINEMAX equ 12288                    ; max lines (table lives 0x?000..0xF000)
HELP_LINEMAX equ 256                 ; help table capacity (help doc is tiny)
MAXBLK  equ 8
CELLH   equ 19                       ; cell height = font height (AXV 8x19)

start:
        cld
        ; flush stale keystrokes (e.g. the autoexec's Enter) so the
        ; viewer's wait-for-key doesn't consume them and exit instantly
fk1:
        mov     ah, 1
        int     16h
        jz      fk2
        xor     ah, ah
        int     16h
        jmp     fk1
fk2:
        mov     ax, 0F00h            ; save current video mode
        int     10h
        mov     [old_mode], al
        call    parse_tail
        cmp     byte [forced], 0
        jne     m_set
        call    detect_video
m_set:
        call    gfx_on
        cmp     byte [test_mode], 0
        je      m_st
        call    clear_screen
        call    selftest
        call    gfx_off
        int     20h
m_st:
        mov     al, [text_rows]
        dec     al
        mov     [body], al           ; body rows = text_rows-1
        call    clear_screen

        cmp     byte [have_file], 0
        je      demo_mode

        call    load_file            ; CY=1 on error
        jnc     m_ok
        mov     di, status_buf
        mov     si, s_err_open
        call    scpy
        mov     si, fname
        call    scpy
        mov     byte [di], ' '
        inc     di
        mov     si, s_errwd
        call    scpy
        mov     al, [open_err+1]
        call    hexdi
        mov     al, [open_err]
        call    hexdi
        mov     byte [di], 0
        mov     byte [cur_row], 0
        mov     byte [cur_col], 0
        mov     byte [cell_has], 0
        mov     si, status_buf
        call    puts
        jmp     wait_exit
m_ok:
        call    detect_ku               ; auto-set code page from file content
        call    build_lines
        call    calc_limits
        jmp     view_loop

; detect_ku: auto-set ku_mode by scanning the first 4KB of the loaded file.
; KU files carry byte A3h or A5h over 2% of the scanned bytes; else TIS (raw).
detect_ku:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        mov     es, [blk_seg]
        xor     si, si
        xor     bx, bx                  ; A3h count
        xor     di, di                  ; A5h count
        mov     cx, 4096
dk_l:
        mov     al, [es:si]
        or      al, al
        jz      dk_d
        cmp     al, 1Ah
        je      dk_d
        cmp     al, 0A3h
        je      dk_a3
        cmp     al, 0A5h
        jne     dk_n
        inc     di
        jmp     dk_n
dk_a3:
        inc     bx
dk_n:
        inc     si
        loop    dk_l
dk_d:
        mov     byte [ku_mode], 0       ; TIS
        mov     ax, 4096
        sub     ax, cx                  ; bytes scanned
        mov     cx, 50
        xor     dx, dx
        div     cx                      ; threshold = 2% of scanned
        cmp     bx, ax
        ja      dk_ku
        cmp     di, ax
        ja      dk_ku
        jmp     dk_e
dk_ku:
        mov     byte [ku_mode], 1
dk_e:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

;---------------- help page (F1 / no parameter) -------------------------
demo_mode:
        call    enter_help
        jmp     view_loop

; enter_help: swap the viewer content to the embedded HELP.TXT document.
; The help keeps its OWN line table (help_lin_tab), so the file's table
; survives the visit and exit_help never has to rebuild it. The help table
; is built lazily, once -- the embedded doc never changes.
enter_help:
        cmp     byte [help_mode], 0
        jne     eh_ret
        mov     ax, [top]
        mov     [sv_top], ax
        mov     ax, [ku_mode]
        mov     [sv_ku], ax
        mov     ax, [hshift]
        mov     [sv_hshift], ax
        mov     ax, [nlines]
        mov     [sv_nlines], ax
        mov     ax, [maxlen]
        mov     [sv_maxlen], ax
        push    si
        push    di
        push    cx
        push    es
        mov     ax, cs
        mov     es, ax
        cld
        mov     si, fname
        mov     di, sv_fname
        mov     cx, 66
        rep     movsb
        mov     si, blk_seg
        mov     di, sv_blkseg
        mov     cx, MAXBLK
        rep     movsw
        mov     al, [blk_used]
        mov     [sv_blkused], al
        pop     es
        pop     cx
        pop     di
        pop     si
        ; switch content to the help document
        mov     ax, cs
        mov     [blk_seg], ax        ; help bytes live in CS
        mov     byte [blk_used], 1
        mov     word [hshift], 0
        mov     byte [ku_mode], 0    ; help is TIS
        mov     word [lin_base], help_lin_tab
        mov     word [lin_cap], HELP_LINEMAX
        cmp     byte [help_built], 0
        jne     eh_have
        mov     word [build_start], help_data
        call    build_lines
        mov     word [build_start], 0
        mov     byte [help_built], 1
        mov     ax, [nlines]
        mov     [help_nlines], ax
        jmp     eh_go
eh_have:
        mov     ax, [help_nlines]
        mov     [nlines], ax
eh_go:
        ; help has its own length: recompute the scroll clamp (topmax was
        ; built for the file and must not bound -- or free-run -- the help)
        mov     ax, [nlines]
        mov     bl, [body]
        xor     bh, bh
        sub     ax, bx
        jnc     eh_t1
        xor     ax, ax
eh_t1:
        mov     [topmax], ax
        mov     word [top], 0
        mov     byte [help_mode], 1
eh_ret:
        ret

; exit_help: restore the saved view state. The file's line table was never
; touched (the help uses its own), so no rebuild is needed.
exit_help:
        cmp     byte [help_mode], 0
        je      ex_ret
        mov     byte [help_mode], 0
        mov     word [build_start], 0
        mov     word [hshift], 0
        push    si
        push    di
        push    cx
        mov     ax, cs
        add     ax, 1000h
        mov     [blk_seg], ax
        add     ax, 1000h
        mov     [blk_seg+2], ax
        add     ax, 1000h
        mov     [blk_seg+4], ax
        add     ax, 1000h
        mov     [blk_seg+6], ax
        add     ax, 1000h
        mov     [blk_seg+8], ax
        add     ax, 1000h
        mov     [blk_seg+10], ax
        add     ax, 1000h
        mov     [blk_seg+12], ax
        add     ax, 1000h
        mov     [blk_seg+14], ax
        mov     byte [blk_used], MAXBLK
        mov     ax, [sv_top]
        mov     [top], ax
        mov     al, [sv_ku]
        mov     [ku_mode], al
        mov     ax, [sv_hshift]
        mov     [hshift], ax
        mov     ax, [sv_nlines]
        mov     [nlines], ax
        mov     ax, [sv_maxlen]
        mov     [maxlen], ax
        ; recompute the file scroll clamp (help ran with its own topmax)
        mov     ax, [nlines]
        mov     bl, [body]
        xor     bh, bh
        sub     ax, bx
        jnc     ex_t1
        xor     ax, ax
ex_t1:
        mov     [topmax], ax
        mov     si, sv_fname
        mov     di, fname
        mov     cx, 66
        rep     movsb
        mov     word [lin_base], lin_tab
        mov     word [lin_cap], LINEMAX
        pop     cx
        pop     di
        pop     si
ex_ret:
        ret

; wait_exit: wait for a key, restore text mode, exit
wait_exit:
        xor     ax, ax
        int     16h
        call    gfx_off
        mov     ax, 4C00h
        int     21h

;---------------- viewer -----------------------------------------------
view_loop:
        call    redraw
v_key:
        xor     ax, ax
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
v_nf1:
        cmp     al, 0
        jne     v_ascii
        cmp     ah, 48h              ; Up
        jne     v_dn
        cmp     word [top], 0
        je      v_key
        mov     dx, [top]
        mov     ax, dx
        dec     ax
        call    do_scroll
        jc      view_loop
        jmp     v_key
v_dn:
        cmp     ah, 50h              ; Down
        jne     v_pgup
        mov     dx, [top]
        mov     ax, dx
        inc     ax
        cmp     ax, [topmax]
        ja      v_key
        call    do_scroll
        jc      view_loop
        jmp     v_key
v_pgup:
        cmp     ah, 49h              ; PgUp
        jne     v_pgdn
        mov     dx, [top]
        mov     ax, dx
        mov     bl, [body]
        xor     bh, bh
        sub     ax, bx
        jnc     vpu1
        xor     ax, ax
vpu1:
        call    do_scroll
        jc      view_loop
        jmp     v_key
v_pgdn:
        cmp     ah, 51h              ; PgDn
        jne     v_home
        mov     dx, [top]
        mov     ax, dx
        mov     bl, [body]
        xor     bh, bh
        add     ax, bx
        cmp     ax, [topmax]
        jbe     vpd1
        mov     ax, [topmax]
vpd1:
        call    do_scroll
        jc      view_loop
        jmp     v_key
v_home:
        cmp     ah, 47h              ; Home
        jne     v_end
        mov     word [top], 0
        jmp     view_loop
v_end:
        cmp     ah, 4Fh              ; End
        jne     v_left
        mov     ax, [topmax]
        mov     [top], ax
        jmp     view_loop
v_left:
        cmp     ah, 4Bh              ; Left
        jne     v_right
        cmp     word [hshift], 0
        je      v_key
        sub     word [hshift], 8     ; scroll 8 columns per press
        jnc     v_left1
        mov     word [hshift], 0
v_left1:
        jmp     view_loop
v_right:
        cmp     ah, 4Dh              ; Right
        jne     v_key
        mov     ax, [maxh]
        cmp     word [hshift], ax
        jae     v_key
        add     word [hshift], 8     ; scroll 8 columns per press
        cmp     word [hshift], ax
        jbe     v_right1
        mov     [hshift], ax
v_right1:
        jmp     view_loop

v_ascii:
        cmp     byte [help_mode], 0
        je      va_file
        cmp     byte [have_file], 0
        je      v_quit               ; demo help: any key quits
        call    exit_help            ; else: back to the file
        jmp     view_loop
va_file:
        cmp     al, 'q'
        je      v_quit
        cmp     al, 'Q'
        je      v_quit
        cmp     al, 1Bh              ; Esc
        je      v_quit
        cmp     al, 'c'              ; toggle KU decoding
        je      v_ku
        cmp     al, 'C'
        je      v_ku
        cmp     al, ' '              ; Space = PgDn
        je      v_sp
        cmp     al, 08h              ; BS = PgUp
        je      v_bs
        cmp     al, 'r'              ; R = full redraw (screen may lag
        je      v_redraw             ; behind at very fast scrolling)
        cmp     al, 'R'
        je      v_redraw
        jmp     v_key
v_redraw:
        jmp     view_loop
v_ku:
        xor     byte [ku_mode], 1
        jmp     view_loop
v_sp:
        mov     dx, [top]
        mov     ax, dx
        mov     bl, [body]
        xor     bh, bh
        add     ax, bx
        cmp     ax, [topmax]
        jbe     vsp1
        mov     ax, [topmax]
vsp1:
        call    do_scroll
        jc      view_loop
        jmp     v_key
v_bs:
        mov     dx, [top]
        mov     ax, dx
        mov     bl, [body]
        xor     bh, bh
        sub     ax, bx
        jnc     vbs1
        xor     ax, ax
vbs1:
        call    do_scroll
        jc      view_loop
        jmp     v_key

;---------------- partial scroll (VRAM blit) ----------------------------
; do_scroll: AX = new top, DX = old top. Moves the overlapping body rows
; within VRAM and redraws only the exposed rows + status bar. Returns
; CF=1 when the change is too large for a blit (caller does a full redraw).
do_scroll:
        push    bx
        push    cx
        push    si
        push    di
        mov     [top], ax           ; commit the new top (both paths)
        mov     di, ax              ; DI = new top (scroll_body preserves DI)
        mov     si, ax
        sub     si, dx              ; SI = delta (signed)
        jz      ds_same
        mov     ax, si
        test    ax, ax
        jns     ds_a
        neg     ax
ds_a:
        mov     cl, [body]
        xor     ch, ch
        cmp     ax, cx
        jae     ds_full
        mov     [sb_delta], si
        call    scroll_body
        test    si, si
        js      ds_up
        ; content moved up: expose + redraw the LAST body row
        mov     al, [body]
        xor     ah, ah
        add     di, ax
        dec     di                  ; line index of the last row
        mov     ax, [body]
        xor     ah, ah
        mov     cx, 19
        mul     cx                  ; AX = first exposed scanline
        mov     cx, 19
        mov     bx, di              ; keep the line index
        call    erase_rows
        mov     al, [body]
        mov     [dl_row], al
        mov     ax, bx
        call    set_line
        call    draw_line
        jmp     ds_st
ds_up:
        ; content moved down: expose + redraw the FIRST body row
        mov     cx, si
        neg     cx
        mov     ax, cx
        mov     bx, 19
        mul     bx                  ; AX = |delta| * 19
        mov     cx, ax
        mov     ax, 19              ; first exposed scanline
        call    erase_rows
        mov     byte [dl_row], 1
        mov     ax, di
        call    set_line
        call    draw_line
ds_st:
        call    st_refresh
        clc
        jmp     ds_out
ds_full:
        stc
        jmp     ds_out
ds_same:
        clc
ds_out:
        pop     di
        pop     si
        pop     cx
        pop     bx
        ret

; line_di: AX = scanline -> DI = VRAM offset of (AX,[pg_x])
;   planar (VGA/EGA): y*row_bytes ; interleaved (CGA/HGC): vrow_tab LUT
line_di:
        push    bx
        cmp     word [planar], 0
        je      ld_i
        mov     di, ax
        shl     di, 1
        shl     di, 1
        shl     di, 1
        shl     di, 1           ; *16
        mov     bx, di
        shl     di, 1
        shl     di, 1           ; *64
        add     di, bx          ; *row_bytes (80)
        jmp     ld_x
ld_i:
        mov     bx, ax
        shl     bx, 1
        mov     di, [vrow_tab+bx]
ld_x:
        mov     ax, [pg_x]
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        add     di, ax
        pop     bx
        ret

; scroll_body: move the body text rows within VRAM by sb_delta lines.
; caller guarantees |sb_delta| < body.
scroll_body:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        push    ds
        mov     es, [vseg]          ; never trust the caller's ES: draw_line
        mov     ax, [sb_delta]      ; can leave it at the file segment
        mov     cl, 19
        imul    cl                  ; AX = delta * 19 scanlines (signed)
        mov     dx, ax
        mov     ax, [sb_delta]
        test    ax, ax
        jns     sc_a
        neg     ax
sc_a:
        mov     cl, [body]
        xor     ch, ch
        sub     cx, ax              ; CX = (body - |delta|) rows to move
        jcxz    sc_x
        mov     al, cl
        mov     cl, 19
        mul     cl                  ; AX = scanline count
        mov     bx, ax              ; BX = loop counter (rep movsb spares BX)
        mov     bp, 19              ; first src scanline
        test    dx, dx
        jns     sc_f
        ; content moves down: copy backward from the last pair
        add     bp, bx
        dec     bp                  ; last src line
        std
        jmp     sc_l
sc_f:
        add     bp, dx              ; first src = 19 + delta*19
        cld
sc_l:
        mov     word [pg_x], 0
        mov     ax, bp              ; src line
        call    line_di
        mov     si, di              ; SI = src offset
        mov     ax, bp
        sub     ax, dx              ; dst line = src - delta*19
        call    line_di             ; DI = dst offset
        mov     cx, [row_bytes]
        cmp     word [sb_delta], 0
        jns     sc_mv
        dec     cx                  ; backward copy: align windows at the
        add     si, cx              ; line END, else rep movsb writes
        add     di, cx              ; the previous scanline's window
        inc     cx
sc_mv:
        push    es
        pop     ds                  ; DS = ES = vseg
        rep     movsb
        push    cs
        pop     ds                  ; restore DS = CS
        cmp     word [sb_delta], 0
        jns     sc_n
        dec     bp
        jmp     sc_l2
sc_n:
        inc     bp
sc_l2:
        dec     bx
        jnz     sc_l
sc_x:
        cld                     ; undo std (backward copy) - rest of the
        pop     ds              ; program assumes forward string ops
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; erase_rows: fill CX scanlines starting at scanline AX with black
erase_rows:
        push    ax
        push    cx
        push    di
        push    es
        jcxz    er_d
        mov     word [pg_x], 0
        mov     es, [vseg]
er1:
        push    cx
        push    ax
        call    line_di
        xor     al, al
        mov     cx, [row_bytes]
        rep     stosb
        pop     ax
        pop     cx
        inc     ax
        loop    er1
er_d:
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret

; set_line: AX = line index (0-based) -> dl_seg / dl_off
set_line:
        push    bx
        push    si
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     si, [lin_base]
        mov     ax, [si+bx]
        mov     [dl_seg], ax
        mov     ax, [si+bx+2]
        mov     [dl_off], ax
        pop     si
        pop     bx
        ret

v_quit:
        mov     si, 0
vq_l:
        cmp     si, [blk_used]
        jae     vq_done
        mov     bx, si
        shl     bx, 1
        mov     es, [blk_seg+bx]
        mov     ah, 49h
        int     21h
        inc     si
        jmp     vq_l
vq_done:
        call    gfx_off
        mov     ax, 4C00h
        int     21h

;---------------- screen redraw ----------------------------------------
redraw:
        call    clear_screen
        mov     byte [dl_row], 1        ; body starts below the status row
rd_lines:
        mov     al, [dl_row]
        cmp     al, [body]              ; body rows drawn (1..body), all fit
        ja      rd_sep
        mov     al, [dl_row]
        dec     al                      ; screen row 1 = file line 0
        xor     ah, ah
        add     ax, [top]
        cmp     ax, [nlines]
        jae     rd_sep
        call    set_line
        call    draw_line
        inc     byte [dl_row]
        jmp     rd_lines
rd_sep:
        call    st_refresh
        ret

; vband: fill rows 0..CELLH-1 solid white (inverse status band)
vband:
        cmp     word [planar], 0
        je      vb_il
        mov     ax, 0A000h
        mov     es, ax
        xor     di, di
        mov     cx, CELLH
        mov     bx, [row_bytes]
        mov     al, 0FFh
        cld
vb_p:
        push    cx
        mov     cx, bx
        rep     stosb
        pop     cx
        loop    vb_p
        ret
vb_il:
        mov     es, [vseg]
        xor     ax, ax
vb_i1:
        push    ax
        mov     [pg_y], ax
        mov     word [pg_x], 0
        call    il_off
        mov     al, 0FFh
        mov     cx, [row_bytes]
        rep     stosb
        pop     ax
        inc     ax
        cmp     ax, CELLH
        jb      vb_i1
        ret

; rd_build: build the status string in status_buf and record the byte span
;           and column span of the R: digits (the only part that changes
;           while scrolling).
rd_build:
        mov     byte [style_reg], 0
        mov     di, status_buf
        mov     byte [di], 02h          ; <b>
        inc     di
        mov     si, fname
        call    scpy
        mov     byte [di], 02h          ; </b>
        inc     di
        mov     byte [di], ' '
        inc     di
        mov     byte [di], 02h
        inc     di
        mov     byte [di], 'C'
        inc     di
        mov     byte [di], ':'
        inc     di
        mov     byte [di], 02h
        inc     di
        mov     ax, [hshift]
        call    dec_word
        mov     byte [di], ' '
        inc     di
        mov     byte [di], 02h
        inc     di
        mov     byte [di], 'R'
        inc     di
        mov     byte [di], ':'
        inc     di
        mov     byte [di], 02h
        inc     di
        mov     ax, di
        sub     ax, status_buf
        mov     [r_b0], ax              ; R digits start here (relative index)
        mov     ax, [top]
        inc     ax
        call    dec_word
        mov     byte [di], '-'
        inc     di
        mov     ax, [top]
        mov     bl, [body]
        xor     bh, bh
        add     ax, bx                 ; 1-based last row on screen (rows 1..body)
        cmp     ax, [nlines]
        jbe     rs_bd
        mov     ax, [nlines]           ; clamp at end of file
rs_bd:
        call    dec_word
        mov     ax, di
        sub     ax, status_buf
        mov     [r_b1], ax              ; R digits end here (relative index)
        mov     byte [di], ' '
        inc     di
        mov     byte [di], 02h
        inc     di
        cmp     byte [ku_mode], 0
        je      rs_tis
        mov     si, sw_ku
        jmp     rs_ku1
rs_tis:
        mov     si, sw_tis
rs_ku1:
        mov     al, [si]
        or      al, al
        jz      rs_kud
        mov     [di], al
        inc     si
        inc     di
        jmp     rs_ku1
rs_kud:
        mov     byte [di], 02h
        inc     di
        mov     byte [di], 0
        ; ---- column of the R span: count visible glyphs before it ----
        mov     si, status_buf
        xor     dx, dx
rs_cc:
        mov     ax, si
        sub     ax, status_buf
        cmp     ax, [r_b0]
        jae     rs_ccd
        mov     al, [si]
        cmp     al, 02h
        je      rs_cc1
        call    is_comb
        jc      rs_cc1
        inc     dx
rs_cc1:
        inc     si
        jmp     rs_cc
rs_ccd:
        mov     [r_c0], dx
        mov     ax, [r_b1]
        sub     ax, [r_b0]
        add     ax, dx
        mov     [r_c1], ax
        ret

; st_refresh: repaint the status bar only as far as needed. Compares the
; fresh string with the shadow: identical -> leave the band pixels alone;
; changed only inside the R: digit span -> repaint band columns and glyphs
; of that span; anything else -> full band + full text.
st_refresh:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        call    rd_build
        mov     si, status_buf
        mov     di, status_shadow
        xor     bl, bl                  ; bit0 = inside diff, bit1 = outside
st_cmp:
        mov     al, [si]
        mov     ah, [di]
        cmp     al, ah
        je      st_c1
        push    si
        sub     si, status_buf
        cmp     si, [r_b0]
        pop     si
        jb      st_cout
        push    si
        sub     si, status_buf
        cmp     si, [r_b1]
        pop     si
        jae     st_cout
        or      bl, 1
        jmp     st_c2
st_cout:
        or      bl, 2
        jmp     st_c3
st_c1:
        or      al, al
        jz      st_c3
st_c2:
        inc     si
        inc     di
        jmp     st_cmp
st_c3:
        test    bl, 2
        jnz     st_full
        test    bl, 1
        jnz     st_part
        jmp     st_done                 ; identical: pixels already correct
st_part:
        ; clear the digit columns, then redraw just the digits
        mov     ax, [r_c1]
        cmp     ax, [sh_rc1]
        jae     st_p0
        mov     ax, [sh_rc1]
st_p0:
        mov     dx, ax
        mov     ax, [r_c0]
        call    vband_cols
        mov     byte [inv_flag], 1
        mov     byte [cur_row], 0
        mov     byte [cell_has], 0
        mov     byte [style_reg], 0
        mov     ax, [r_b1]
        sub     ax, [r_b0]
        mov     cx, ax
        mov     si, status_buf
        add     si, [r_b0]
st_p2:
        mov     ax, [r_c1]
        sub     ax, cx                  ; col of this digit (cx counts down)
        mov     [cur_col], al
        lodsb
        push    cx
        call    draw_char
        pop     cx
        loop    st_p2
        mov     byte [inv_flag], 0
        call    st_shadow
        mov     ax, [r_c1]
        mov     [sh_rc1], ax
        jmp     st_done
st_full:
        call    vband
        mov     byte [inv_flag], 1
        mov     byte [cur_row], 0
        mov     byte [cur_col], 0
        mov     byte [cell_has], 0
        mov     byte [style_reg], 0
        mov     si, status_buf
        call    puts
        ; ---- right-aligned hint block (visible length only) ----
        mov     byte [style_reg], 0
        xor     cx, cx
        mov     si, stl_right
rs_rlen:
        mov     al, [si]
        or      al, al
        jz      rs_rlen_d
        inc     si
        cmp     al, 02h
        je      rs_rlen             ; bold codes are invisible: don't count
        inc     cx
        jmp     rs_rlen
rs_rlen_d:
        mov     ax, [text_cols]
        sub     ax, cx
        mov     [cur_col], al
        mov     byte [cur_row], 0
        mov     si, stl_right
        call    puts
        mov     byte [inv_flag], 0
        call    st_shadow
        mov     ax, [r_c1]
        mov     [sh_rc1], ax
st_done:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; st_shadow: copy status_buf (with terminator) over the shadow
st_shadow:
        push    si
        push    di
        push    cx
        push    es
        push    cs
        pop     es                  ; movsb targets DS memory, not VRAM --
        mov     si, status_buf      ; ES may still be A000 from drawing
        mov     di, status_shadow
        mov     cx, 96
st_s1:
        movsb
        cmp     byte [di-1], 0
        loopne  st_s1
        pop     es
        pop     cx
        pop     di
        pop     si
        ret

; vband_cols: repaint the inverse band (all CELLH rows) but only across
; columns [AX, DX) in pixels.
vband_cols:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    si
        push    bp
        push    es
        mov     bp, ax              ; c0
        mov     si, dx              ; c1
        mov     ax, bp
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        mov     bx, ax              ; first byte column
        mov     ax, si
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        sub     ax, bx              ; byte count
        mov     dx, ax
        cmp     word [planar], 0
        je      vbc_il
        mov     cx, CELLH
        mov     ax, 0A000h
        mov     es, ax
        mov     di, bx
        mov     al, 0FFh
        cld
vbc_p1:
        push    cx
        mov     cx, dx
        jcxz    vbc_p2
        rep     stosb
vbc_p2:
        pop     cx
        add     di, [row_bytes]
        loop    vbc_p1
        jmp     vbc_d
vbc_il:
        mov     ax, bx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        mov     [pg_x], ax          ; il_off wants pixels
        mov     es, [vseg]
        xor     ax, ax              ; scanline 0
        mov     bh, 0FFh
vbc_i1:
        push    ax
        push    cx
        call    il_off
        mov     cx, dx
        jcxz    vbc_i2
        mov     al, bh
        rep     stosb
vbc_i2:
        pop     cx
        pop     ax
        inc     ax
        cmp     ax, CELLH
        jb      vbc_i1
vbc_d:
        pop     es
        pop     bp
        pop     si
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; draw_line: render line [dl_seg]:[dl_off] at row [dl_row] with [hshift]
draw_line:
        mov     byte [style_reg], 0     ; styles are line-local: a line must
        mov     byte [exp_prev], 0      ; render the same on blit or redraw
        mov     al, [dl_row]
        mov     [cur_row], al
        mov     byte [cur_col], 0
        mov     byte [cell_has], 0
        mov     es, [dl_seg]
        mov     si, [dl_off]
        ; --- skip hshift columns (style-aware: style codes toggle the
        ;     running style state and eat 0 columns, marks eat 0 columns,
        ;     a base eats 1 column normally or 2 when expanded) ---
        mov     cx, [hshift]
        jcxz    dlsk_near
        xor     dx, dx                 ; columns consumed
        jmp     dlsk_l
dlsk_near:
        jmp     dl_skm
dlsk_l:
        mov     al, [es:si]
        call    term_chk
        jz      dl_done
        call    ku_tr
        cmp     al, 1Bh
        je      dlsk_m                 ; WS escape: no columns
        cmp     al, 02h
        je      dlsk_t
        cmp     al, 05h
        je      dlsk_t
        cmp     al, 0Eh
        je      dlsk_t
        cmp     al, 0Fh
        je      dlsk_t
        cmp     al, 12h
        je      dlsk_t
        cmp     al, 13h
        je      dlsk_t
        cmp     al, 14h
        je      dlsk_t
        cmp     al, 16h
        je      dlsk_t
        cmp     al, 17h
        je      dlsk_t
        cmp     al, 15h
        je      dlsk_t                 ; 15h = italic too (RW files)
        ; swallowed controls (match TREAD): invisible, eat nothing
        cmp     al, 01h
        je      dlsk_m
        cmp     al, 03h
        je      dlsk_m
        cmp     al, 04h
        je      dlsk_m
        cmp     al, 06h
        je      dlsk_m
        cmp     al, 07h
        je      dlsk_m
        cmp     al, 1Ch
        je      dlsk_m
        cmp     al, 1Dh
        je      dlsk_m
        cmp     al, 1Eh
        je      dlsk_m
        cmp     al, 1Fh
        je      dlsk_m
        call    is_comb
        jc      dlsk_m                 ; combining mark: no columns
        inc     dx                     ; base char
        inc     si                     ; advance past the base byte
        test    byte [style_reg], 02h
        jz      dlsk_chk
        inc     dx                     ; expanded base = 2 columns
dlsk_chk:
        cmp     dx, [hshift]
        jb      dlsk_l
        jmp     dlsk_tm
dlsk_t:
        call    style_toggle
        inc     si
        jmp     dlsk_l
dlsk_m:
        inc     si
        jmp     dlsk_l
dlsk_tm:                        ; skip trailing marks of the last skipped base
        mov     al, [es:si]
        call    term_chk
        jz      dl_done
        call    ku_tr
        call    is_comb
        jnc     dl_go
        inc     si
        jmp     dlsk_tm
dl_skm:                          ; hshift=0: skip leading combining marks
        mov     al, [es:si]
        cmp     al, 0Dh
        je      dl_done
        cmp     al, 0Ah
        je      dl_done
        cmp     al, 1Ah
        je      dl_done
        or      al, al
        jz      dl_done
        call    ku_tr
        call    is_comb
        jnc     dl_go
        inc     si
        jmp     dl_skm
dl_go:
        mov     cx, 255                 ; guard: max bytes per line (the
        xor     ch, ch                  ; cur_col clamp handles columns --
dl_l:                                   ; marks eat bytes, not columns
        mov     al, [cur_col]
        cmp     al, [text_cols]
        jb      dl_c1
        jmp     dl_ovf                  ; past right edge: draw marks only
dl_c1:
        mov     al, [es:si]
        cmp     al, 0Dh
        je      dl_done
        cmp     al, 0Ah
        je      dl_done
        cmp     al, 1Ah
        je      dl_done
        or      al, al
        jz      dl_done
        call    ku_tr
        ; --- fast path: plain base glyph with no style active. Bytes
        ;     < 20h are controls/toggles/escapes, D1h-DBh and E7h-EEh are
        ;     combining marks -- everything else renders identically to
        ;     the full pipeline when style_reg=0, minus the cell_tmp
        ;     copy, apply_style and dispatch overhead. ---
        cmp     byte [style_reg], 0
        jne     fg_slow
        cmp     al, 20h
        jb      fg_slow
        cmp     al, 0D1h
        jb      fg_go
        cmp     al, 0DBh
        jbe     fg_slow
        cmp     al, 0E7h
        jb      fg_go
        cmp     al, 0EEh
        jbe     fg_slow
fg_go:
        push    cx
        push    di
        push    es
        mov     [chr], al
        call    set_tall
        push    si
        xor     ah, ah
        mov     bx, CELLH
        mul     bx
        add     ax, font8x19
        mov     si, ax
        mov     di, cell_buf
        mov     cx, CELLH
        push    es
        push    cs
        pop     es
        rep     movsb                   ; cell_buf = font glyph
        pop     es
        pop     si
        mov     byte [cell_upper], 0
        mov     byte [back], 0
        mov     al, [cur_col]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        mov     [pg_x], ax
        mov     al, [cur_row]
        xor     ah, ah
        mov     bx, ax
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        add     ax, bx
        add     ax, bx
        add     ax, bx                  ; *19
        mov     [pg_y], ax
        mov     ax, [scr_px]
        sub     ax, 8
        cmp     [pg_x], ax
        jae     fg_d1
        mov     word [pg_src], cell_buf
        call    put_glyph
fg_d1:
        mov     byte [cell_has], 1
        inc     byte [cur_col]
        pop     es
        pop     di
        pop     cx
        inc     si
        dec     cx
        jnz     dl_l
        jmp     dl_done
fg_slow:
        push    cx
        call    draw_char
        pop     cx
        inc     si
        dec     cx
        jnz     dl_l
        jmp     dl_done
dl_ovf:                                 ; mark-only mode past col 80
        mov     al, [es:si]
        call    term_chk
        jz      dl_done
        call    ku_tr
        call    is_comb
        jc      dl_ovm
        inc     byte [cur_col]          ; off-screen base: count only
        inc     si
        jmp     dl_ovf
dl_ovm:                                 ; mark: still drawn at col 79
        call    draw_char
        inc     si
        jmp     dl_ovf
dl_done:
        ret

; ku_tr: translate AL if KU mode and AL >= 80h
ku_tr:
        cmp     byte [ku_mode], 0
        je      kt_ret
        cmp     al, 80h
        jb      kt_ret
        push    bx
        mov     bx, ku_tab-80h
        xlat
        pop     bx
kt_ret:
        ret

; term_chk: ZF=1 if AL is a line terminator (0Dh 0Ah 1Ah 00h)
term_chk:
        cmp     al, 0Dh
        je      tc_z
        cmp     al, 0Ah
        je      tc_z
        cmp     al, 1Ah
        je      tc_z
        or      al, al
tc_z:
        ret

; is_comb: CY=1 if AL is a combining mark (font code)
is_comb:
        cmp     al, 0D1h
        je      ic_yes
        cmp     al, 0D4h
        jb      ic_no
        cmp     al, 0DBh
        jbe     ic_yes
        cmp     al, 0E7h
        jb      ic_no
        cmp     al, 0EEh
        jbe     ic_yes
ic_no:
        clc
        ret
ic_yes:
        stc
        ret

; scpy: copy ASCIZ [SI] to [DI]
scpy:
        mov     al, [si]
        or      al, al
        jz      scpy_d
        mov     [di], al
        inc     si
        inc     di
        jmp     scpy
scpy_d:
        ret

; hexdi: write AL as 2 hex chars at [DI]
hexdi:
        push    ax
        push    cx
        mov     cl, al
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        call    hexn
        mov     al, cl
        and     al, 0Fh
        call    hexn
        pop     cx
        pop     ax
        ret
hexn:
        cmp     al, 9
        jbe     hn9
        add     al, 'A'-10
        jmp     hnst
hn9:
        add     al, '0'
hnst:
        mov     [di], al
        inc     di
        ret

; dec_word: write AX as decimal at [DI], advance DI
dec_word:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
dw1:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     dw1
dw2:
        pop     dx
        add     dl, '0'
        mov     [di], dl
        inc     di
        loop    dw2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

;---------------- file load --------------------------------------------
load_file:
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jnc     lf_ok
        mov     [open_err], ax        ; real DOS error code for the status line
        stc
        ret
lf_ok:
        mov     [handle], ax
        ; buffers at segments CS+1000h..CS+8000h (free RAM above our COM,
        ; well clear of lin_tab at CS:29xx and the stack) - no DOS memory calls
        mov     ax, cs
        add     ax, 1000h
        mov     word [blk_seg+0], ax
        add     ax, 1000h
        mov     word [blk_seg+2], ax
        add     ax, 1000h
        mov     word [blk_seg+4], ax
        add     ax, 1000h
        mov     word [blk_seg+6], ax
        add     ax, 1000h
        mov     word [blk_seg+8], ax
        add     ax, 1000h
        mov     word [blk_seg+10], ax
        add     ax, 1000h
        mov     word [blk_seg+12], ax
        add     ax, 1000h
        mov     word [blk_seg+14], ax
        mov     word [blk_used], MAXBLK
        mov     di, [handle]          ; DI = file handle, kept safe in loop
        xor     si, si                ; block 0
lf_r:
        mov     bx, si
        shl     bx, 1
        mov     ax, [blk_seg+bx]      ; DS = data seg here (no pushes outstanding)
        push    ds
        mov     ds, ax                ; DS = block segment
        mov     dx, 0
        mov     cx, 8000h
        push    di
        mov     bx, di               ; BX = file handle for DOS
        mov     ah, 3Fh
        int     21h
        pop     di
        jc      lf_errp
        cmp     ax, cx
        jb      lf_sh0
        mov     dx, 8000h
        mov     cx, 8000h
        push    di
        mov     bx, di               ; BX = file handle for DOS
        mov     ah, 3Fh
        int     21h
        pop     di
        jc      lf_errp
        cmp     ax, cx
        jb      lf_sh8
        pop     ds                    ; block full, DS = data seg
        inc     si
        cmp     si, [blk_used]
        jb      lf_r
        ; all blocks full: force-terminate the last block (loses 2 bytes)
        mov     bx, [blk_seg+14]
        push    ds
        mov     ds, bx
        mov     word [0FFFEh], 0
        pop     ds
        jmp     lf_de
lf_sh0:                               ; short first half: DS = block seg, AX = count
        mov     bx, ax
        mov     byte [bx], 0          ; terminator
        pop     ds                    ; DS = data seg
        jmp     lf_de
lf_sh8:                               ; short second half: DS = block seg, AX = count
        mov     bx, ax
        add     bx, 8000h
        mov     byte [bx], 0          ; terminator
        pop     ds                    ; DS = data seg, fall into de-escape
lf_de:                                ; ---- strip ESC (1B) bytes, per block ----
        xor     si, si
        mov     cx, MAXBLK
de_blk:
        mov     es, [blk_seg+si]
        xor     di, di
        xor     bx, bx
de_l:
        mov     al, [es:bx]
        or      al, al
        jz      de_done
        cmp     al, 1Ah
        je      de_done
        cmp     al, 1Bh
        je      de_sk                   ; drop every ESC byte (RW 2.0 intro byte)
        mov     al, [es:bx]
        mov     [es:di], al
        inc     bx
        inc     di
        jmp     de_l
de_sk:
        inc     bx
        jmp     de_l
de_done:
        mov     byte [es:di], 0
        add     si, 2
        dec     cx
        jnz     de_blk
lf_close:
        mov     bx, [handle]
        mov     ah, 3Eh
        int     21h
        clc
        ret
lf_errp:                              ; read error: DS = block seg, one push out
        pop     ds
        mov     bx, [handle]
        mov     ah, 3Eh
        int     21h
        stc
        ret

;---------------- line table build -------------------------------------
build_lines:
        mov     word [nlines], 1
        mov     word [curlen], 0
        mov     word [bidx], 0
        mov     ax, [build_start]
        mov     [boff], ax
        mov     es, [blk_seg]
        mov     ax, es
        mov     bx, [lin_base]
        mov     [bx], ax
        mov     ax, [build_start]
        mov     [bx+2], ax
bl_l:
        mov     bx, [boff]
        mov     al, [es:bx]
        cmp     al, 0
        je      bl_done
        cmp     al, 1Ah
        je      bl_done
        cmp     al, 0Dh
        je      bl_cr
        cmp     al, 0Ah
        je      bl_lf
        ; swallowed controls: invisible at render time, eat no columns
        cmp     al, 01h
        je      bl_sw
        cmp     al, 03h
        je      bl_sw
        cmp     al, 04h
        je      bl_sw
        cmp     al, 06h
        je      bl_sw
        cmp     al, 07h
        je      bl_sw
        cmp     al, 1Ch
        je      bl_sw
        cmp     al, 1Dh
        je      bl_sw
        cmp     al, 1Eh
        je      bl_sw
        cmp     al, 1Fh
        je      bl_sw
        cmp     word [curlen], 255      ; line size cap = 255
        jae     bl_cap
        push    bx
        mov     bl, al
        cmp     bl, 0D1h                ; marks don't count as columns
        je      bl_m
        cmp     bl, 0D4h
        jb      bl_cnt
        cmp     bl, 0DBh
        jbe     bl_m
        cmp     bl, 0E7h
        jb      bl_cnt
        cmp     bl, 0EEh
        ja      bl_cnt
bl_m:
        pop     bx
        call    badv
        jnc     bl_l
        jmp     bl_done
bl_sw:                                  ; swallowed control: advance only
        call    badv
        jnc     bl_l
        jmp     bl_done
bl_cnt:
        pop     bx
        inc     word [curlen]
        call    badv
        jnc     bl_l
        jmp     bl_done
bl_cap:                                 ; over 255 bytes: skip rest of line
        call    badv
        mov     bx, [boff]
        mov     al, [es:bx]
        cmp     al, 0
        je      bl_done
        cmp     al, 1Ah
        je      bl_done
        cmp     al, 0Dh
        je      bl_cr
        cmp     al, 0Ah
        je      bl_lf
        jmp     bl_cap
bl_cr:
        call    bl_close
        call    badv
        jc      bl_done
        mov     bx, [boff]
        cmp     byte [es:bx], 0Ah
        jne     bl_add
        call    badv
        jc      bl_done
bl_add:
        call    bl_addent
        jmp     bl_l
bl_lf:
        call    bl_close
        call    badv
        jc      bl_done
        call    bl_addent
        jmp     bl_l
bl_done:
        call    bl_close
        ret

bl_close:
        mov     ax, [curlen]
        cmp     ax, [maxlen]
        jbe     bc1
        mov     [maxlen], ax
bc1:
        mov     word [curlen], 0
        ret

bl_addent:
        mov     ax, [lin_cap]
        cmp     [nlines], ax
        jae     bae_ret
        push    di
        mov     ax, [nlines]
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     ax, [bidx]
        shl     ax, 1
        mov     si, ax
        mov     ax, [blk_seg+si]        ; block segment for entry 0
        mov     di, [lin_base]
        mov     [di+bx], ax
        mov     ax, [boff]
        mov     [di+bx+2], ax
        pop     di
        inc     word [nlines]
bae_ret:
        ret

; badv: advance (bidx,boff), update ES; CY=1 past end
badv:
        inc     word [boff]
        jnz     ba_ok
        mov     word [boff], 0
        inc     word [bidx]
        mov     ax, [bidx]
        cmp     ax, [blk_used]
        jae     ba_end
        shl     ax, 1
        mov     bx, ax
        mov     ax, [blk_seg+bx]
        mov     es, ax
ba_ok:
        clc
        ret
ba_end:
        stc
        ret

; calc_limits: topmax, maxh, maxlen>=80
calc_limits:
        mov     ax, [nlines]
        mov     bl, [body]
        xor     bh, bh
        sub     ax, bx
        jnc     cl1
        xor     ax, ax
cl1:
        mov     [topmax], ax
        mov     word [top], 0
        mov     word [hshift], 0
        mov     ax, [maxlen]
        sub     ax, 80
        jnc     cl2
        xor     ax, ax
cl2:
        mov     [maxh], ax
        ret

;---------------- command tail -----------------------------------------
parse_tail:
        mov     si, 81h
pt_scan:
        mov     al, [si]
        cmp     al, 0Dh
        je      pt_done
        or      al, al
        jz      pt_done
        cmp     al, ' '
        jne     pt_tok
        inc     si
        jmp     pt_scan
pt_tok:
        cmp     byte [si], '/'
        je      pt_sw
        mov     di, fname
pt_f:
        mov     al, [si]
        cmp     al, 0Dh
        je      pt_fend
        or      al, al
        jz      pt_fend
        cmp     al, ' '
        je      pt_fend
        mov     [di], al
        inc     di
        inc     si
        jmp     pt_f
pt_fend:
        mov     byte [di], 0
        mov     byte [have_file], 1
        jmp     pt_scan
pt_sw:
        mov     al, [si+1]
        or      al, 20h
        cmp     al, 'v'
        jne     pt_s2
        mov     byte [adapter], 2
        mov     byte [forced], 1
        jmp     pt_skip
pt_s2:
        cmp     al, 'c'
        jne     pt_s3
        mov     byte [adapter], 0
        mov     byte [forced], 1
        jmp     pt_skip
pt_s3:
        cmp     al, 'e'
        jne     pt_s4
        mov     byte [adapter], 1
        mov     byte [forced], 1
        jmp     pt_skip
pt_s4:
        cmp     al, 'h'
        jne     pt_t
        mov     byte [adapter], 3
        mov     byte [forced], 1
        jmp     pt_skip
pt_t:
        cmp     al, 't'
        jne     pt_skip
        mov     byte [test_mode], 1
pt_skip:
        inc     si
        inc     si
        jmp     pt_scan
pt_done:
        ret

;---------------- selftest (/t) -----------------------------------------
selftest:
        ; row 0 = raw FF bytes straight to A000 (proves direct writes)
        mov     ax, 0A000h
        mov     es, ax
        mov     di, 22 * 80
        mov     cx, 80
        mov     al, 0FFh
stf1:
        mov     [es:di], al
        inc     di
        loop    stf1
        mov     byte [cur_col], 0
        mov     byte [cur_row], 0
        mov     byte [cell_has], 0
        mov     si, s_selft
        call    puts
        mov     word [hl_y], 19
        call    hline
        mov     byte [cur_row], 2
        mov     byte [cur_col], 0
        mov     byte [cell_has], 0
        mov     si, s_ok
        call    puts
        mov     cx, 273                ; wait 15s via BIOS tick counter (18.2/s)
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     bx, [46Ch]
        add     bx, cx
st_d1:
        mov     ax, [46Ch]
        cmp     ax, bx
        jb      st_d1
        pop     ds
        ret

;---------------- video HAL ---------------------------------------------
; [adapter]: 0 CGA / 1 EGA / 2 VGA / 3 HGC
detect_video:
        push    ds                     ; BIOS mode byte 40:49h (= linear
        xor     ax, ax                 ; 449h) tells the display type the
        mov     ds, ax                 ; box booted with: 7 = mono (HGC/MDA)
        mov     bl, [449h]
        pop     ds
        cmp     bl, 7
        jne     dv_color
        mov     byte [adapter], 3      ; mono text -> Hercules path
        ret
dv_color:
        mov     ax, 1A00h
        int     10h
        cmp     al, 1Ah
        jne     dv_ega
        mov     byte [adapter], 2
        ret
dv_ega:
        ; EGA check: the video BIOS posts its flags in BDA 40:87h (= linear
        ; 487h) -- zero on CGA/HGC boxes, non-zero when an EGA (or better)
        ; posts. VGA was already taken by 1A00h above, so non-zero here
        ; means EGA. Verified on DOSBox-X: svga_s3/ega = 60h, cga/herc = 00h.
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     bl, [487h]
        pop     ds
        or      bl, bl
        jz      dv_hgct
        mov     byte [adapter], 1
        ret
dv_hgct:
        ; Hercules toggle test: port 3BA bit 7 (vsync) pulses on HGC,
        ; stays 0 on VGA/CGA. Classic Podanoffsky detection.
        mov     dx, 3BAh
        in      al, dx
        and     al, 80h
        mov     ah, al
        mov     cx, 7FFFh
dhg1:
        in      al, dx
        and     al, 80h
        cmp     al, ah
        loopz   dhg1
        jnz     dv_hgc                 ; bit changed -> HGC present
dv_cga:
        mov     byte [adapter], 0
        ret
dv_hgc:
        mov     byte [adapter], 3
        ret

gfx_on:
        mov     al, [adapter]
        or      al, al
        jz      go_cga
        cmp     al, 1
        je      go_ega
        cmp     al, 3
        je      go_hgc
        mov     byte [mode_num], 12h
        mov     word [planar], 1
        mov     word [vseg], 0A000h    ; planar modes: erase_rows/vband target
        mov     byte [text_rows], 25
        mov     word [vram_size], 9600h
        mov     word [scr_px], 640
        jmp     go_set
go_ega:
        mov     byte [mode_num], 10h
        mov     word [planar], 1
        mov     word [vseg], 0A000h
        mov     byte [text_rows], 18    ; 1 status + 17 body lines (342 <= 350)
        mov     word [vram_size], 6D60h
        mov     word [scr_px], 640
        jmp     go_set
go_hgc:
        mov     word [planar], 0
        mov     word [vseg], 0B000h
        mov     word [bank_mask], 3
        mov     byte [yshift], 2
        mov     word [row_bytes], 90
        mov     byte [text_cols], 90
        mov     byte [text_rows], 18    ; 1 status + 17 body lines (real HGC: 342 <= 348)
        mov     word [vram_size], 8000h
        mov     word [scr_px], 720
        mov     dx, 3BFh               ; enable graphics + both pages
        mov     al, 3
        out     dx, al
        mov     dx, 3B8h
        mov     al, 2                  ; graphics mode, video off
        out     dx, al
        mov     dx, 3B4h               ; program 6845 CRTC R0..R11
        mov     si, hgc_crtc
        mov     cx, 12
        xor     ah, ah
gh1:
        mov     al, ah
        out     dx, al
        inc     dx
        mov     al, [si]
        out     dx, al
        dec     dx
        inc     si
        inc     ah
        loop    gh1
        jmp     go_done               ; video comes on after clear_screen
go_cga:
        mov     byte [mode_num], 6
        mov     word [planar], 0
        mov     word [vseg], 0B800h
        mov     word [bank_mask], 1
        mov     byte [yshift], 1
        mov     word [row_bytes], 80
        mov     byte [text_rows], 10
        mov     word [vram_size], 4000h
        mov     word [scr_px], 640
go_set:
        mov     al, [text_rows]
        mov     [body], al              ; body rows = total rows (status on row 0)
        cmp     byte [adapter], 2       ; VGA: drop the partially visible last row
        jne     gs_b1
        dec     byte [body]
gs_b1:
        mov     ah, 0
        mov     al, [mode_num]
        int     10h
        cmp     word [planar], 0
        je      go_done
        mov     dx, GDC               ; ONE-TIME setup: from here on all
        mov     al, 0                 ; drawing is plain memory writes:
        out     dx, al                ; SR = 0
        inc     dx
        mov     al, 0
        out     dx, al
        dec     dx
        mov     al, 1                 ; ESR = 0 -> CPU byte to ALL planes
        out     dx, al
        inc     dx
        mov     al, 0
        out     dx, al
        dec     dx
        mov     al, 3                 ; data rotate = 0
        out     dx, al
        inc     dx
        mov     al, 0
        out     dx, al
        dec     dx
        mov     al, 5                 ; write mode 0
        out     dx, al
        inc     dx
        mov     al, 0
        out     dx, al
        dec     dx
        mov     al, 8                 ; bitmask = FF
        out     dx, al
        inc     dx
        mov     al, 0FFh
        out     dx, al
go_done:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    es
        mov     ax, cs
        mov     es, ax
        mov     word [vrt_val+0], 0
        mov     word [vrt_val+2], 2000h
        mov     word [vrt_val+4], 4000h
        mov     word [vrt_val+6], 6000h
        xor     dx, dx                  ; y
        mov     di, vrow_tab
        mov     cx, 512
vrt_l:
        mov     bx, dx
        and     bx, [bank_mask]
        shl     bx, 1
        mov     ax, [vrt_val+bx]        ; running (y>>yshift)*row_bytes per bank
        mov     es:[di], ax
        add     ax, [row_bytes]
        mov     [vrt_val+bx], ax
        inc     di
        inc     di
        inc     dx
        loop    vrt_l
        pop     es
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

gfx_off:
        cmp     byte [adapter], 3
        jne     gf1
        mov     dx, 3B8h               ; back to text mode first
        mov     al, 28h
        out     dx, al
        mov     dx, 3BFh
        mov     al, 0
        out     dx, al
gf1:
        mov     ah, 0
        mov     al, [old_mode]
        int     10h
        ret

clear_screen:
        push    ax
        push    cx
        push    dx
        push    di
        push    es
        mov     byte [status_shadow], 0 ; empty shadow: forces a full status
        cmp     word [planar], 0
        je      cs_int
        mov     ax, 0A000h
        mov     es, ax
        xor     di, di
        mov     cx, [vram_size]
        shr     cx, 1
        xor     ax, ax
        cld
        rep stosw
        jmp     cs_ret
cs_int:
        mov     es, [vseg]             ; CGA / HGC interleave
        xor     di, di
        mov     cx, [vram_size]
        shr     cx, 1
        xor     ax, ax
        cld
        rep stosw
        cmp     byte [adapter], 3
        jne     cs_ret
        mov     dx, 3B8h               ; HGC: video on after clear
        mov     al, 0Ah
        out     dx, al
cs_ret:
        pop     es
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; il_off: AX = y -> DI = interleave offset of (y,[pg_x])
;   via vrow_tab LUT (built once in go_done): no mul on the hot path
il_off:
        push    bx
        mov     bx, ax
        shl     bx, 1
        mov     di, [vrow_tab+bx]       ; bank*2000h + (y>>yshift)*row_bytes
        mov     ax, [pg_x]
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        add     di, ax
        pop     bx
        ret

hline:
        push    ax
        push    cx
        push    dx
        push    di
        push    es
        mov     al, 0FFh
        cmp     byte [inv_flag], 0      ; inverse mode: draw the rule black
        je      hl0
        mov     al, 0
hl0:
        mov     dl, al                 ; keep color: MUL below clobbers AL
        cmp     word [planar], 0
        je      hl_int
        mov     ax, 0A000h
        mov     es, ax
        mov     ax, [hl_y]
        mov     bx, 80
        mul     bx
        mov     di, ax
        mov     al, dl                 ; rule color (AL was clobbered by MUL)
        mov     cx, 80
hl_p:
        mov     [es:di], al
        inc     di
        loop    hl_p
        jmp     hl_ret
hl_int:
        mov     es, [vseg]             ; CGA / HGC
        mov     word [pg_x], 0
        mov     ax, [hl_y]
        call    il_off
        mov     cx, [row_bytes]
        mov     al, 0FFh
        cmp     byte [inv_flag], 0     ; inverse mode: draw the rule black
        je      hl_c2
        mov     al, 0
hl_c2:
        mov     [es:di], al
        inc     di
        loop    hl_c2
hl_ret:
        pop     es
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

;---------------- text layer -------------------------------------------
puts:
        mov     byte [cell_has], 0
puts_j:
        lodsb
        or      al, al
        jz      puts_done
        call    draw_char
        jmp     puts_j
puts_done:
        ret

puts_line:
        mov     byte [cur_col], 0
        mov     byte [cell_has], 0
        call    puts
        inc     byte [cur_row]
        ret

;---------------- cell renderer (proven mk4 base + styles) --------------
draw_char:
        cmp     al, 1Bh                 ; WS escape: invisible, eats nothing
        je      dc_skip
        ; swallowed controls (match TREAD): invisible, eat nothing
        cmp     al, 01h
        je      dc_skip
        cmp     al, 03h
        je      dc_skip
        cmp     al, 04h
        je      dc_skip
        cmp     al, 06h
        je      dc_skip
        cmp     al, 07h
        je      dc_skip
        cmp     al, 1Ch
        je      dc_skip
        cmp     al, 1Dh
        je      dc_skip
        cmp     al, 1Eh
        je      dc_skip
        cmp     al, 1Fh
        je      dc_skip
        cmp     al, 02h                 ; ---- style control bytes (toggle) ----
        je      as_tgl0
        cmp     al, 05h
        je      as_tgl1
        cmp     al, 0Eh
        je      as_tgl4
        cmp     al, 0Fh
        je      as_tgl5
        cmp     al, 12h
        je      as_tgl2
        cmp     al, 13h
        je      as_tgl3
        cmp     al, 17h
        je      as_tgl6
        cmp     al, 15h
        je      as_tgl6                 ; 15h = italic too (RW files)
        cmp     al, 14h
        je      as_tgl7
        cmp     al, 16h
        je      as_tgl8
        jmp     dc_go1
dc_skip:
        ret
dc_go1:
        mov     [chr], al
        cmp     al, 0D1h        ; ั upper
        je      dc_upper
        cmp     al, 0D4h        ; D4-D7 upper (ิ ี ึ ื)
        jb      dc_cklow
        cmp     al, 0D7h
        jbe     dc_upper
        cmp     al, 0D8h        ; D8-DA lower (ุ ู ฺ)
        jb      dc_base
        cmp     al, 0DAh
        jbe     dc_lower
        cmp     al, 0DBh        ; DB upper
        je      dc_upper
        cmp     al, 0E7h        ; E7-EE upper (็ ่ ้ ๊ ๋ ์ ํ ๎)
        jb      dc_base
        cmp     al, 0EEh
        jbe     dc_upper
        jmp     dc_base
dc_cklow:
        jmp     dc_base
dc_base:
        mov     byte [cell_upper], 0
        call    set_tall
        call    cell_copy
        mov     byte [back], 0
        mov     dl, 0
        call    dc_draw               ; stretched glyph drawn ONCE (16px wide)
        mov     byte [cell_has], 1
        inc     byte [cur_col]
        test    byte [style_reg], 02h
        jz      dc_b1
        mov     byte [exp_prev], 1    ; marks after this cell shift back by 2
        inc     byte [cur_col]        ; expanded char occupies 2 columns
        ret
dc_b1:
        mov     byte [exp_prev], 0
dc_b2:
        ret
as_tgl0:
        xor     byte [style_reg], 01h   ; bold
        ret
as_tgl1:
        xor     byte [style_reg], 02h   ; expand
        ret
as_tgl2:
        xor     byte [style_reg], 0Ch   ; double underline toggles the pair
        ret
as_tgl3:
        xor     byte [style_reg], 08h   ; single underline
        ret
as_tgl4:
        and     byte [style_reg], 0DFh  ; sub (clears super)
        xor     byte [style_reg], 10h
        ret
as_tgl5:
        and     byte [style_reg], 0EFh  ; super (clears sub)
        xor     byte [style_reg], 20h
        ret
as_tgl6:
        xor     byte [style_reg], 40h   ; italic
        ret
as_tgl7:
        and     byte [style_reg], 0EFh  ; super (clears sub)
        xor     byte [style_reg], 20h
        ret
as_tgl8:
        and     byte [style_reg], 0DFh  ; sub (clears super)
        xor     byte [style_reg], 10h
        ret
as_tgl9:
        and     byte [style_reg], 0CFh  ; cancel sub+super
        ret

; style_toggle: apply style code AL to [style_reg] (shared by draw_char
; and the hshift skip pass so the state stays consistent)
style_toggle:
        cmp     al, 02h
        je      stg0
        cmp     al, 05h
        je      stg1
        cmp     al, 0Eh
        je      stg4
        cmp     al, 0Fh
        je      stg5
        cmp     al, 12h
        je      stg2
        cmp     al, 13h
        je      stg3
        cmp     al, 17h
        je      stg6
        cmp     al, 15h
        je      stg6                    ; 15h = italic too (RW files)
        cmp     al, 14h
        je      stg7
        cmp     al, 16h
        je      stg8
        ret
stg0:
        xor     byte [style_reg], 01h
        ret
stg1:
        xor     byte [style_reg], 02h
        ret
stg2:
        xor     byte [style_reg], 0Ch
        ret
stg3:
        xor     byte [style_reg], 08h
        ret
stg4:
        and     byte [style_reg], 0DFh
        xor     byte [style_reg], 10h
        ret
stg5:
        and     byte [style_reg], 0EFh
        xor     byte [style_reg], 20h
        ret
stg6:
        xor     byte [style_reg], 40h
        ret
stg7:
        and     byte [style_reg], 0EFh
        xor     byte [style_reg], 20h
        ret
stg8:
        and     byte [style_reg], 0DFh
        xor     byte [style_reg], 10h
        ret

dc_upper:
        cmp     byte [cell_has], 0
        je      dc_base
        mov     byte [cell_upper], 1
        mov     al, [exp_prev]
        inc     al
        mov     [back], al            ; 1 normal, 2 after an expanded base
        call    cell_or
        mov     dl, 0
        call    dc_draw
        ret

dc_lower:
        cmp     byte [cell_has], 0
        je      dc_base
        mov     al, [exp_prev]
        inc     al
        mov     [back], al
        call    cell_or
        mov     dl, 0
        call    dc_draw
        ret

dc_tone:
        cmp     byte [cell_has], 0
        je      dc_base
        mov     al, [exp_prev]
        inc     al
        mov     [back], al
        cmp     byte [cell_upper], 0
        jne     dt_high
        cmp     byte [cell_tall], 0
        jne     dt_high
        call    cell_or_sh4
        jmp     dt_d
dt_high:
        call    cell_or
dt_d:
        mov     dl, 0
        call    dc_draw
        ret

; cell_or_sh4: cell_buf[r+4] |= glyph[r][r+4..]  (tone snug shift)
cell_or_sh4:
        push    ax
        push    cx
        push    si
        push    di
        mov     al, [chr]
        xor     ah, ah
        mov     bx, CELLH
        mul     bx
        add     ax, font8x19
        mov     si, ax
        add     si, 4
        mov     di, cell_buf
        add     di, 4
        mov     cx, 16
cs4:
        mov     al, [si]
        or      al, [di]
        mov     [di], al
        inc     si
        inc     di
        loop    cs4
        pop     di
        pop     si
        pop     cx
        pop     ax
        ret

set_tall:
        mov     byte [cell_tall], 0
        cmp     al, 0BBh
        je      st_yes
        cmp     al, 0BDh
        je      st_yes
        cmp     al, 0BFh
        je      st_yes
        cmp     al, 0CAh
        je      st_yes
        cmp     al, 0E2h
        je      st_yes
        cmp     al, 0E3h
        je      st_yes
        ret
st_yes:
        mov     byte [cell_tall], 1
        ret

; cell_copy: cell_buf = glyph[chr]
cell_copy:
        push    ax
        push    cx
        push    si
        push    di
        mov     al, [chr]
        xor     ah, ah
        mov     bx, CELLH
        mul     bx
        add     ax, font8x19
        mov     si, ax
        mov     di, cell_buf
        mov     cx, CELLH
cc1:
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        loop    cc1
        pop     di
        pop     si
        pop     cx
        pop     ax
        ret

; cell_or: cell_buf |= glyph[chr]
cell_or:
        push    ax
        push    cx
        push    si
        push    di
        mov     al, [chr]
        xor     ah, ah
        mov     bx, CELLH
        mul     bx
        add     ax, font8x19
        mov     si, ax
        mov     di, cell_buf
        mov     cx, CELLH
co1:
        mov     al, [si]
        or      al, [di]
        mov     [di], al
        inc     si
        inc     di
        loop    co1
        pop     di
        pop     si
        pop     cx
        pop     ax
        ret

; apply_style: transform cell_tmp per style_reg (cx-safe loops)
apply_style:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     al, [style_reg]
        test    al, 01h                 ; ---- bold
        jz      as_shear
        xor     si, si
as_b1:
        mov     ah, [cell_tmp+si]
        mov     bl, ah
        shr     bl, 1
        or      ah, bl
        mov     [cell_tmp+si], ah
        inc     si
        cmp     si, CELLH
        jb      as_b1
as_shear:
        test    al, 40h                 ; ---- italic shear (in-cell)
        jz      as_sub
        xor     si, si
as_s1:
        mov     bx, 19
        sub     bx, si
        mov     dh, 3
        mov     cl, dh
        shr     bx, cl                  ; (19-r)/8 = 0..2
        jz      as_s2
        mov     ah, [cell_tmp+si]
        mov     cl, bl
        shr     ah, cl
        mov     [cell_tmp+si], ah
as_s2:
        inc     si
        cmp     si, CELLH
        jb      as_s1
as_sub:
        test    al, 10h                 ; ---- subscript: shift down 3
        jz      as_sup
        mov     si, 15
as_u1:
        mov     ah, [cell_tmp+si]
        mov     [cell_tmp+si+3], ah
        dec     si
        jns     as_u1
        mov     byte [cell_tmp+0], 0
        mov     byte [cell_tmp+1], 0
        mov     byte [cell_tmp+2], 0
as_sup:
        test    al, 20h                 ; ---- superscript: shift up 5
        jz      as_ul
        mov     si, 5
as_p1:
        mov     ah, [cell_tmp+si]
        mov     [cell_tmp+si-5], ah
        inc     si
        cmp     si, CELLH
        jb      as_p1
        mov     byte [cell_tmp+14], 0
        mov     byte [cell_tmp+15], 0
        mov     byte [cell_tmp+16], 0
        mov     byte [cell_tmp+17], 0
        mov     byte [cell_tmp+18], 0
as_ul:
        test    al, 08h                 ; ---- underline single
        jz      as_ret
        cmp     byte [cell_buf+17], 0   ; descender/lower-mark ink on the
        jnz     as_ret                  ; rule row: skip it (ุ ู ฺ, ฒ, ณ, ...)
        mov     byte [cell_tmp+17], 0FFh
        test    al, 04h                 ; ---- underline double
        jz      as_ret
        cmp     byte [cell_buf+18], 0
        jnz     as_ret
        mov     byte [cell_tmp+18], 0FFh
as_ret:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; dc_draw: draw composed cell at ((cur_col-[back])*8, cur_row*20+DL)
;   expand (style bit0): each pixel doubled -> 16px wide (TREAD style)
dc_draw:

        mov     al, [cur_col]
        xor     ah, ah
        sub     al, [back]
        jnc     dd1
        xor     al, al
dd1:
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        mov     [pg_x], ax
        mov     al, [cur_row]
        xor     ah, ah
        mov     bx, ax
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1        ; 16r
        add     ax, bx       ; 17r
        add     ax, bx       ; 18r
        add     ax, bx       ; 19r = row*CELLH
        mov     dh, 0
        add     ax, dx
        mov     [pg_y], ax
        ; copy cell_buf -> cell_tmp, apply non-expand styles
        push    si
        xor     si, si
dd_c1:
        mov     al, [cell_buf+si]
        mov     [cell_tmp+si], al
        inc     si
        cmp     si, CELLH
        jb      dd_c1
        call    apply_style
        mov     al, [style_reg]
        test    al, 02h                 ; ---- expand: pixel doubling
        jz      dd_norm
        call    dd_wide
        jmp     dd_ret
dd_norm:
        mov     word [pg_src], cell_tmp
        mov     ax, [scr_px]
        sub     ax, 8
        cmp     [pg_x], ax
        jae     dd_ret
        call    put_glyph
dd_ret:
        pop     si
        ret

; dd_wide: stretch cell_tmp -> cell_wide (40 bytes) and blit 2 cells wide
dd_wide:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        xor     si, si
        xor     di, di
        mov     cx, CELLH
dw_r:
        mov     al, [cell_tmp+si]
        call    dd_stretch              ; -> DH=hi, DL=lo
        mov     [cell_wide+di], dh
        mov     [cell_wide+di+1], dl
        inc     si
        add     di, 2
        loop    dw_r
        ; blit: 20 rows x 2 bytes at pg_x, pg_x+8
        xor     si, si
        cmp     word [planar], 0
        je      dw_i
        mov     ax, 0A000h
        mov     es, ax
        mov     ax, [pg_y]
        mov     bx, 80
        mul     bx
        mov     di, ax
        mov     ax, [pg_x]
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        add     di, ax
        mov     ax, [scr_px]
        sub     ax, 8
        cmp     [pg_x], ax            ; last column: hi byte only (avoid wrap)
        jae     dw_h
        mov     cx, CELLH
dw_b:
        mov     al, [cell_wide+si]
        mov     [es:di], al
        mov     al, [cell_wide+si+1]
        mov     [es:di+1], al
        inc     si
        inc     si
        add     di, 80
        loop    dw_b
        jmp     dw_d
dw_h:                               ; stretched hi half only
        mov     cx, CELLH
dw_h1:
        mov     al, [cell_wide+si]
        mov     [es:di], al
        add     si, 2
        add     di, 80
        loop    dw_h1
        jmp     dw_d
dw_i:
        mov     ax, [scr_px]
        sub     ax, 8
        cmp     [pg_x], ax            ; interleaved: skip at last column
        jae     dw_d
        mov     es, [vseg]
        mov     ax, [pg_y]
        mov     cx, CELLH
dw_i1:
        push    ax
        push    cx
        mov     [pg_y], ax
        call    il_off                ; il_off adds [pg_x]/8 itself
        mov     al, [cell_wide+si]
        mov     [es:di], al
        mov     al, [cell_wide+si+1]
        mov     [es:di+1], al
        add     si, 2
        pop     cx
        pop     ax
        inc     ax
        loop    dw_i1
dw_d:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; dd_stretch: double each pixel of AL (8px -> 16px). DH=hi (px0-3), DL=lo (px4-7)
dd_stretch:
        push    ax
        push    bx
        mov     bl, al
        xor     bh, bh
        mov     dh, [tbl_hi+bx]
        mov     dl, [tbl_lo+bx]
        pop     bx
        pop     ax
        ret

; tbl_hi[n] = high nibble of n with each bit doubled; tbl_lo = low nibble doubled
tbl_hi:
        db 000h,000h,000h,000h,000h,000h,000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
        db 003h,003h,003h,003h,003h,003h,003h,003h,003h,003h,003h,003h,003h,003h,003h,003h
        db 00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
        db 00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh,00Fh
        db 030h,030h,030h,030h,030h,030h,030h,030h,030h,030h,030h,030h,030h,030h,030h,030h
        db 033h,033h,033h,033h,033h,033h,033h,033h,033h,033h,033h,033h,033h,033h,033h,033h
        db 03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch
        db 03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh,03Fh
        db 0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
        db 0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h,0C3h
        db 0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh,0CCh
        db 0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh,0CFh
        db 0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h,0F0h
        db 0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h,0F3h
        db 0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh,0FCh
        db 0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
tbl_lo:
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh
        db 000h,003h,00Ch,00Fh,030h,033h,03Ch,03Fh,0C0h,0C3h,0CCh,0CFh,0F0h,0F3h,0FCh,0FFh


put_glyph:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        mov     si, [pg_src]
        cmp     word [planar], 0
        je      pg_il
        mov     ax, 0A000h
        mov     es, ax
        mov     ax, [pg_y]
        mov     bx, 80
        mul     bx
        mov     di, ax
        mov     ax, [pg_x]
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        add     di, ax
        mov     cx, CELLH
pg_p1:
        mov     al, [si]
        cmp     byte [inv_flag], 0
        je      pg_p1n
        not     al
pg_p1n:
        stosb
        inc     si
        add     di, 79
        loop    pg_p1
        jmp     pg_ret
pg_il:
        mov     es, [vseg]
        mov     ax, [pg_y]
        mov     cx, CELLH
pg_i1:
        push    ax
        push    cx
        call    il_off
        mov     al, [si]
        cmp     byte [inv_flag], 0
        je      pg_i1n
        not     al
pg_i1n:
        mov     [es:di], al
        inc     si
        pop     cx
        pop     ax
        inc     ax
        loop    pg_i1
pg_ret:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

;---------------- data --------------------------------------------------;---------------- data --------------------------------------------------;---------------- data --------------------------------------------------;---------------- data --------------------------------------------------
old_mode     db 0
forced       db 0
adapter      db 0
mode_num     db 12h
planar       dw 0
vseg         dw 0B800h
bank_mask    dw 1
yshift       db 1
row_bytes    dw 80
text_cols    db 80
text_rows    db 25
body         db 24
vram_size    dw 9600h
text_color   db 7
line_color   db 7
cur_col      db 0
cur_row      db 0
cell_upper   db 0
cell_tall    db 0
cell_has     db 0
exp_prev     db 0                    ; last base was expanded (marks shift by 2)
back         db 0
chr          db 0
hl_y         dw 0
pg_x         dw 0
pg_y         dw 0
pg_src       dw 0
pg_ycur      dw 0
pg_rowbyte   db 0
cell_buf     db CELLH dup (0)
cell_tmp    db CELLH dup (0)
style_reg    db 0
test_mode    db 0
scr_px       dw 640
cell_wide    db 40 dup (0)

have_file    db 0
handle       dw 0
ku_mode      db 0                    ; default TIS-620 (c toggles KU for RW files)
top          dw 0
topmax       dw 0
hshift       dw 0
maxh         dw 0
nlines       dw 0
maxlen       dw 80
curlen       dw 0
bidx         dw 0
boff         dw 0
blk_used     dw 0
blk_seg      dw MAXBLK dup (0)
dl_row       db 0
dl_seg       dw 0
dl_off       dw 0
fname        db 66 dup (0)
open_err     dw 0
status_buf   db 96 dup (0)
status_shadow db 96 dup (0)
r_b0         dw 0                    ; R-digit span: byte offsets in buf,
r_b1         dw 0                    ; column span on screen (0-based px),
r_c0         dw 0                    ; sh_rc1 = previous right edge for
r_c1         dw 0                    ; partial repaints
sh_rc1       dw 0
inv_flag     db 0
sb_delta     dw 0
vrow_tab     times 512 dw 0
vrt_val      times 4 dw 0
help_mode    db 0
build_start  dw 0
lin_base     dw lin_tab              ; active line table (file or help)
lin_cap      dw LINEMAX              ; active table capacity (entries)
help_nlines  dw 0                    ; help doc line count (built once)
help_built   db 0
sv_top       dw 0
sv_hshift    dw 0
sv_ku        db 0
sv_blkused   db 0
sv_nlines    dw 0
sv_maxlen    dw 0
sv_blkseg    dw MAXBLK dup (0)
sv_fname     db 66 dup (0)
help_lin_tab db HELP_LINEMAX*4 dup (0)

%include "STRS.INC"
%include "KU.INC"
%include "STATUS.INC"

hgc_crtc:                             ; 6845 R0..R11 for 720x348 gfx
        db 35h, 2Dh, 2Eh, 07h, 5Bh, 02h, 57h, 57h, 02h, 03h, 00h, 00h

font8x19:
        incbin "AXV.FON"

help_data:
        incbin "HELP.TXT"             ; WordStar-style help source (TIS-620 +
                                      ; ^B/^E/^L/^S/^N/^V/^W style codes), edit
                                      ; in any DOS editor and just rebuild
        db 0                          ; blob terminator
lin_tab      equ $                    ; line table grows upward from here, < 0xF000
