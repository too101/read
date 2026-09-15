/* READ for Linux -- an X11/Xlib port of the DOS Thai text viewer
 * (read.asm), sibling to the Windows GDI port (read_win.c). The
 * platform-independent core (byte classification, KU/TIS translation,
 * WordStar-style cell composition, line-table building, scrolling limits)
 * is a byte-for-byte copy of read_win.c's logic -- only the windowing/
 * framebuffer-blit layer differs (X11 here, GDI there) and the file/arg
 * handling uses plain POSIX instead of Win32 calls. Everything hardware-
 * specific to DOS/BIOS/CGA-EGA-VGA-Hercules is replaced with a single
 * resizable window (80x24 at startup), same as the Windows port -- no
 * video-mode selection needed.
 *
 * Assumes a TrueColor display with 24 or 32-bit depth (virtually
 * universal today) -- the framebuffer is packed as 0x00RRGGBB and blitted
 * via a 32bpp XImage regardless of the server's exact depth, which works
 * because the only colors used are shades of gray (R=G=B), so byte-order
 * quirks between depths/visuals never show up as wrong colors.
 *
 * The window is resizable: COLS/BODY/WIN_W/WIN_H used to be fixed at
 * 80x24, now they're runtime state (g_cols/g_body/g_win_w/g_win_h) updated
 * from ConfigureNotify -- see main()'s event loop and fb_create(). The
 * bitmap font stays 8x19 always (resizing reveals more/fewer whole cells,
 * never scales the glyphs).
 *
 * Build: gcc -O2 -Wall -Wextra -o read src/read_linux.c -lX11
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "data.h"

/* ---------------- layout constants --------------------------------------- */
#define CELLW   8
#define CELLH   19
#define COLS_INIT 80
#define BODY_INIT 24                /* body rows; row 0 is the status bar */
#define MIN_COLS  20                /* floor enforced both on resize and via
                                        XSizeHints' min_width/min_height */
#define MIN_BODY  3

static int g_cols  = COLS_INIT;
static int g_body  = BODY_INIT;
static int g_win_w = COLS_INIT * CELLW;
static int g_win_h = (BODY_INIT + 1) * CELLH;

/* ---------------- byte classes (mirrors C_TERM/C_SWAL/C_STYLE/... ) ---- */
#define C_TERM  0x01
#define C_SWAL  0x02
#define C_STYLE 0x04
#define C_COMB  0x08
#define C_TAB   0x10

/* cls_lo: classes for raw bytes 00h-1Fh (same table as read.asm) */
static const unsigned char cls_lo[32] = {
    C_SWAL, C_SWAL, C_STYLE, C_SWAL, C_SWAL, C_STYLE, C_SWAL, C_SWAL,
    0, C_TAB, C_TERM, 0, 0, C_TERM, C_STYLE, C_STYLE,
    0, 0, C_STYLE, C_STYLE, C_STYLE, C_STYLE, C_STYLE, C_STYLE,
    0, 0, C_TERM, C_SWAL, C_SWAL, C_SWAL, C_SWAL, C_SWAL
};
/* cls_hi: classes for TIS-620 combining marks D1h-EEh */
static const unsigned char cls_hi[0xEE - 0xD1 + 1] = {
    C_COMB, 0, 0, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB, C_COMB
};
/* style_reg xor masks per WordStar style code 00h-17h (same as read.asm's
 * stx[] table): bit0=bold bit1=expand bit2=underline-double bit3=underline
 * -single bit4=subscript bit5=superscript bit6=italic */
static const unsigned char stx[0x18] = {
    0,0,0x01,0,0,0x02,0,0,0,0,0,0,0,0,0x10,0x20,
    0,0,0x0C,0x08,0x20,0x40,0x10,0x40
};

static unsigned char classify(unsigned char b) {
    if (b <= 0x1F) return cls_lo[b];
    if (b >= 0xD1 && b <= 0xEE) return cls_hi[b - 0xD1];
    return 0;
}

/* ---------------- KU/TIS translation ------------------------------------ */
static int g_ku_mode = 0;
static unsigned char translate(unsigned char b) {
    if (g_ku_mode && b >= 0x80) return g_ku_tab[b - 0x80];
    return b;
}

/* ---------------- line table --------------------------------------------- */
typedef struct { const unsigned char *ptr; int len; } Line;

typedef struct {
    Line *lines;
    int nlines, cap;
    int maxlen;
} LineTab;

static void linetab_free(LineTab *t) { free(t->lines); t->lines = NULL; t->nlines = t->cap = t->maxlen = 0; }

static void linetab_push(LineTab *t, const unsigned char *ptr, int len) {
    if (t->nlines >= t->cap) {
        t->cap = t->cap ? t->cap * 2 : 256;
        t->lines = (Line*)realloc(t->lines, t->cap * sizeof(Line));
    }
    t->lines[t->nlines].ptr = ptr;
    t->lines[t->nlines].len = len;
    t->nlines++;
}

/* build_lines: mirrors read.asm's build_lines -- splits buf[0..len) into
 * logical lines on CR / LF / CRLF, tracks maxlen the same way (base char
 * = +1 col, tab = +8 cols saturating, style/swallowed/combining = +0 --
 * see read.asm's bl_sp for why style bytes must not count: a line of N
 * visible columns must not report width > N just because it also carries
 * style-toggle bytes). Caps a single line's counted width at 255, same as
 * the DOS build (a purely cosmetic cap -- doesn't affect what's stored). */
static void build_lines(LineTab *t, const unsigned char *buf, int len) {
    linetab_free(t);
    int line_start = 0;
    int col = 0;
    int i = 0;
    while (i < len) {
        unsigned char raw = buf[i];
        unsigned char tb = translate(raw);
        unsigned char cls = classify(tb);
        if (cls & C_TERM) {
            linetab_push(t, buf + line_start, i - line_start);
            if (col > t->maxlen) t->maxlen = col;
            if (raw == 0x1A) return; /* ^Z: stop scanning entirely here, like
                                         read.asm's bl_done -- unlike CR/LF
                                         this is not just a line break, it's
                                         DOS's traditional text-file EOF
                                         marker, and many files carry trailing
                                         printer/dot-matrix control bytes
                                         after it that must never be shown */
            col = 0;
            if (raw == 0x0D && i + 1 < len && buf[i+1] == 0x0A) i++; /* CRLF = one break */
            i++;
            line_start = i;
            continue;
        }
        if (cls & C_TAB) {
            col += 8;
            if (col > 255) col = 255;
        } else if (!(cls & (C_SWAL | C_STYLE | C_COMB))) {
            col++;
            if (col > 255) col = 255;
        }
        i++;
    }
    if (i > line_start || t->nlines == 0) {
        linetab_push(t, buf + line_start, i - line_start);
        if (col > t->maxlen) t->maxlen = col;
    }
    if (t->nlines == 0) linetab_push(t, buf, 0);
}

/* ---------------- viewer state ------------------------------------------- */
static unsigned char *g_filebuf = NULL;
static int g_filelen = 0;
static char g_fname[PATH_MAX] = "";
static LineTab g_tab = {0}, g_help_tab = {0};
static int g_help_built = 0;
static int g_top = 0, g_hshift = 0, g_topmax = 0, g_maxh = 0;
static int g_help_mode = 0;
static int g_sv_top, g_sv_hshift, g_sv_ku;
static LineTab *g_cur;

/* recompute_bounds: topmax/maxh only, no top/hshift reset -- used when
 * restoring a saved top/hshift (exit_help) so the bounds match the table
 * we're restoring into without clobbering the restored scroll position. */
static void recompute_bounds(LineTab *t) {
    g_topmax = t->nlines - g_body;
    if (g_topmax < 0) g_topmax = 0;
    g_maxh = t->maxlen - g_cols;
    if (g_maxh < 0) g_maxh = 0;
    if (g_top > g_topmax) g_top = g_topmax;
    if (g_hshift > g_maxh) g_hshift = g_maxh;
}

static void calc_limits(LineTab *t) {
    recompute_bounds(t);
    g_top = 0;
    g_hshift = 0;
}

/* detect_ku: KU files carry byte A3h or A5h over 2% of the first 4KB
 * (checked independently -- either one alone crossing 2% is enough) */
static void detect_ku(const unsigned char *buf, int len) {
    int n = len < 4096 ? len : 4096;
    int a3 = 0, a5 = 0, scanned = 0;
    for (int i = 0; i < n; i++) {
        unsigned char b = buf[i];
        if (b == 0x00 || b == 0x1A) break;
        if (b == 0xA3) a3++;
        else if (b == 0xA5) a5++;
        scanned++;
    }
    g_ku_mode = 0;
    if (scanned > 0) {
        if (a3 * 100 > scanned * 2) g_ku_mode = 1;
        if (a5 * 100 > scanned * 2) g_ku_mode = 1;
    }
}

/* ---------------- framebuffer (plain array, blitted via XImage) --------- */
static unsigned int *g_px = NULL; /* g_win_w x g_win_h, top-down 0x00RRGGBB */

/* Allocates a fresh buffer sized to the CURRENT g_win_w/g_win_h. Called once
 * at startup and again on every resize -- the caller (main()'s event loop)
 * is responsible for destroying the old XImage first (XDestroyImage frees
 * the buffer it wraps, since it took ownership of the pointer it was
 * created with) so recreating doesn't leak. */
static void fb_create(void) {
    g_px = (unsigned int*)malloc((size_t)g_win_w * g_win_h * sizeof(unsigned int));
}

#define COL_BG      0x00101010u
#define COL_FG      0x00C0C0C0u
#define COL_BAR_BG  0x00303030u

static unsigned int g_bg_color = COL_BG; /* "off" pixel color; status bar
                                             swaps this to COL_BAR_BG while
                                             it draws so glyph backgrounds
                                             don't punch black holes
                                             through the status bar */

static void fb_clear(void) {
    for (int i = 0; i < g_win_w * g_win_h; i++) g_px[i] = COL_BG;
}

static void fb_pixel(int x, int y, int on) {
    if (x < 0 || x >= g_win_w || y < 0 || y >= g_win_h) return;
    g_px[y * g_win_w + x] = on ? COL_FG : g_bg_color;
}

/* ---------------- cell composition (mirrors dc_base/apply_style) -------- */
typedef unsigned char Cell[CELLH]; /* one byte per row, bit7=leftmost pixel */

static void apply_style(Cell out, const Cell in, unsigned char style) {
    memcpy(out, in, CELLH);
    if (style & 0x01) {            /* bold: smear right by 1 (OR with >>1) */
        for (int r = 0; r < CELLH; r++) out[r] |= (unsigned char)(in[r] >> 1);
    }
    if (style & 0x40) {            /* italic: shear top rows right */
        Cell tmp; memcpy(tmp, out, CELLH);
        for (int r = 0; r < CELLH; r++) {
            int shift = (r < 4) ? 2 : (r < 12) ? 1 : 0;
            out[r] = (unsigned char)(tmp[r] >> shift);
        }
    }
    if (style & 0x10) {            /* subscript: shift rows down 3 */
        Cell tmp; memcpy(tmp, out, CELLH);
        for (int r = CELLH - 1; r >= 3; r--) out[r] = tmp[r - 3];
        out[0] = out[1] = out[2] = 0;
    }
    if (style & 0x20) {            /* superscript: shift rows up 5 */
        Cell tmp; memcpy(tmp, out, CELLH);
        for (int r = 0; r <= CELLH - 1 - 5; r++) out[r] = tmp[r + 5];
        for (int r = CELLH - 5; r < CELLH; r++) out[r] = 0;
    }
    if (style & 0x08) {            /* underline single (skip if descender ink) */
        if (in[17] == 0) {
            out[17] = 0xFF;
            if (style & 0x04) {    /* underline double */
                if (in[18] == 0) out[18] = 0xFF;
            }
        }
    }
}

/* draw a composed (post-style) 8-wide cell at character column/row; if
 * `wide` is set, pixel-double it to 16px (WordStar "expand" style).
 * fb_pixel's own bounds check clips anything past the window edge, so an
 * expanded glyph sitting in the last column is simply truncated at the
 * edge (read.asm's put_wide does a more deliberate half-glyph clip for
 * that exact case; this is an approximation, not pixel-identical there). */
static void blit_cell(int col, int row_px_y, const Cell cell, int wide) {
    int x0 = col * CELLW;
    for (int r = 0; r < CELLH; r++) {
        unsigned char b = cell[r];
        int y = row_px_y + r;
        if (!wide) {
            for (int bit = 0; bit < 8; bit++) {
                int on = (b >> (7 - bit)) & 1;
                fb_pixel(x0 + bit, y, on);
            }
        } else {
            for (int bit = 0; bit < 8; bit++) {
                int on = (b >> (7 - bit)) & 1;
                fb_pixel(x0 + bit * 2, y, on);
                fb_pixel(x0 + bit * 2 + 1, y, on);
            }
        }
    }
}

/* draw_text: mirrors read.asm's draw_char_c / dc_base / combining-mark
 * handling. A base character is drawn immediately (like the DOS dc_base)
 * and is NEVER re-touched once the next base/tab/end-of-line moves past
 * it -- only a combining mark targets the still-current cell, re-OR-ing
 * into it and redrawing in place, using whatever style is active *at that
 * moment*.
 *
 * `start_col` places the text's own column 0 at that screen column (used
 * to right-align the status bar's hint text); `hshift` is the horizontal
 * scroll to subtract (0 for anything that isn't the scrollable body);
 * `raw_tis` skips KU translation -- used for UI strings (status bar) that
 * are always TIS-620 and must render the same regardless of which mode
 * the *file* happens to be in. */
static void draw_text(int row_px_y, int start_col, int hshift, int raw_tis,
                       const unsigned char *buf, int len) {
    unsigned char style = 0;       /* styles are line-local */
    int cur_col = 0;               /* 0-based column within the logical line */
    int cell_has = 0;
    Cell cell;
    int pending_wide = 0;
    int pending_col = -1;

    for (int i = 0; i < len; i++) {
        unsigned char raw = buf[i];
        unsigned char ch = raw_tis ? raw : translate(raw);
        unsigned char cls = classify(ch);

        if (cls & C_TERM) break;   /* shouldn't occur inside a split line */

        if (cls & C_STYLE) {
            /* faithful port of read.asm's style_toggle: sub/superscript
             * (bits 0x10/0x20) clear each other before the xor, so turning
             * one on forcibly turns the other off rather than just toggling */
            unsigned char al = stx[ch <= 0x17 ? ch : 0];
            if (al & 0x30) {
                unsigned char ah = (unsigned char)~(al ^ 0x30);
                style &= ah;
            }
            style ^= al;
            continue;
        }
        if (cls & C_SWAL) continue;   /* invisible, eats nothing (incl. 00h) */

        if (cls & C_COMB && cell_has) {
            /* OR the mark glyph into the still-current cell and redraw it
             * in place -- does not advance cur_col */
            const unsigned char *mg = g_font + ch * CELLH;
            for (int r = 0; r < CELLH; r++) cell[r] |= mg[r];
            pending_wide = (style & 0x02) ? 1 : 0;
            Cell styled; apply_style(styled, cell, style);
            int scr = start_col + pending_col - hshift;
            if (scr >= 0 && scr < g_cols) blit_cell(scr, row_px_y, styled, pending_wide);
            continue;
        }

        /* base character (including a leading combining mark with no base
         * yet, and each of a tab's 8 synthesized spaces -- both draw as an
         * ordinary base): draw immediately, advance the cursor, done. */
        if (cls & C_TAB) {
            for (int k = 0; k < 8; k++) {
                memcpy(cell, g_font + 0x20 * CELLH, CELLH); /* space */
                cell_has = 1;
                pending_col = cur_col;
                pending_wide = (style & 0x02) ? 1 : 0;
                Cell styled; apply_style(styled, cell, style);
                int scr = start_col + pending_col - hshift;
                if (scr >= 0 && scr < g_cols) blit_cell(scr, row_px_y, styled, pending_wide);
                cur_col += pending_wide ? 2 : 1;
            }
            continue;
        }
        memcpy(cell, g_font + ch * CELLH, CELLH);
        cell_has = 1;
        pending_col = cur_col;
        pending_wide = (style & 0x02) ? 1 : 0;
        {
            Cell styled; apply_style(styled, cell, style);
            int scr = start_col + pending_col - hshift;
            if (scr >= 0 && scr < g_cols) blit_cell(scr, row_px_y, styled, pending_wide);
        }
        cur_col += pending_wide ? 2 : 1;
    }
}

static void draw_line(int row_px_y, const unsigned char *buf, int len) {
    draw_text(row_px_y, 0, g_hshift, 0, buf, len);
}

/* text_width: visible column width of a UI string, same counting rule as
 * build_lines (base/tab count, style/swallowed/combining don't) -- used
 * to right-align the status bar's hint text correctly even though it
 * contains combining marks (e.g. TIS-620 "รหัส" has one). */
static int text_width(const unsigned char *buf, int len) {
    int col = 0;
    for (int i = 0; i < len; i++) {
        unsigned char cls = classify(buf[i]);
        if (cls & C_TAB) col += 8;
        else if (!(cls & (C_SWAL | C_STYLE | C_COMB))) col++;
    }
    return col;
}

static int puts_ascii(int col, int row_px_y, const char *s) {
    int len = (int)strlen(s);
    draw_text(row_px_y, col, 0, 1, (const unsigned char*)s, len);
    return col + text_width((const unsigned char*)s, len);
}

static void draw_status(void) {
    for (int x = 0; x < g_win_w; x++) for (int y = 0; y < CELLH; y++) g_px[y*g_win_w+x] = COL_BAR_BG;
    g_bg_color = COL_BAR_BG; /* so glyph backgrounds match the bar, not black */

    char left[256];
    int lo = g_top + 1, hi = g_top + g_body;
    if (hi > g_cur->nlines) hi = g_cur->nlines;
    if (g_cur->nlines == 0) { lo = 0; hi = 0; }
    const char *fname = g_help_mode ? "READ Help" : (g_fname[0] ? g_fname : "(no file)");
    snprintf(left, sizeof(left), "%s  C:%d  R:%d-%d  %s", fname, g_hshift, lo, hi,
             g_ku_mode ? "KU" : "TIS");
    puts_ascii(0, 0, left);

    int rlen = STL_RIGHT_LEN;
    int rcols = text_width(g_stl_right, rlen);
    draw_text(0, g_cols - rcols, 0, 1, g_stl_right, rlen);

    g_bg_color = COL_BG; /* restore for the body rows */
}

static void render_all(void) {
    fb_clear();
    draw_status();
    for (int r = 0; r < g_body; r++) {
        int li = g_top + r;
        if (li >= g_cur->nlines) break;
        draw_line((r + 1) * CELLH, g_cur->lines[li].ptr, g_cur->lines[li].len);
    }
}

/* ---------------- file / help loading ------------------------------------ */
static void load_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Cannot open file: %s\n", path);
        return;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    free(g_filebuf);
    g_filebuf = (unsigned char*)malloc(sz > 0 ? (size_t)sz : 1);
    g_filelen = (int)fread(g_filebuf, 1, (size_t)sz, f);
    fclose(f);
    detect_ku(g_filebuf, g_filelen);
    build_lines(&g_tab, g_filebuf, g_filelen);
    g_cur = &g_tab;
    calc_limits(g_cur);
    strncpy(g_fname, path, sizeof(g_fname) - 1);
}

static void enter_help(void) {
    if (g_help_mode) return;
    g_sv_top = g_top; g_sv_hshift = g_hshift; g_sv_ku = g_ku_mode;
    g_ku_mode = 0; /* help text is TIS-620 -- must be set before build_lines
                       runs (lazily, once) so it doesn't KU-translate it */
    if (!g_help_built) {
        build_lines(&g_help_tab, g_help_data, HELP_LEN);
        g_help_built = 1;
    }
    g_cur = &g_help_tab;
    calc_limits(g_cur);
    g_help_mode = 1;
}

static void exit_help(void) {
    if (!g_help_mode) return;
    g_top = g_sv_top; g_hshift = g_sv_hshift; g_ku_mode = g_sv_ku;
    g_cur = g_filebuf ? &g_tab : &g_help_tab;
    recompute_bounds(g_cur); /* refresh topmax/maxh for the file table
                                 without resetting the restored top/hshift */
    g_help_mode = 0;
}

/* ---------------- X11 plumbing ------------------------------------------ */
static void clamp_top(int wanted) {
    if (wanted < 0) wanted = 0;
    if (wanted > g_topmax) wanted = g_topmax;
    g_top = wanted;
}
static void clamp_hshift(int wanted) {
    if (wanted < 0) wanted = 0;
    if (wanted > g_maxh) wanted = g_maxh;
    g_hshift = wanted;
}

/* Applies one keypress's effect on state (scroll position, help mode, KU
 * mode, quit). Split out from main()'s event loop so a run of queued
 * KeyPress events (key-repeat from holding an arrow key, or just fast
 * typing) can all be applied before the one expensive render_all() +
 * XPutImage() at the end, instead of doing a full redraw per keystroke --
 * see the ConfigureNotify coalescing comment in main() for why that matters
 * over a forwarded display pipe such as WSLg. Returns 1 if this key
 * changed something that needs a redraw, 0 otherwise. Sets *running to 0
 * on quit. */
static int apply_key(KeySym ks, int *running) {
    int redraw = 1;
    switch (ks) {
    case XK_Up:        clamp_top(g_top - 1); break;
    case XK_Down:      clamp_top(g_top + 1); break;
    case XK_Prior:     clamp_top(g_top - g_body); break;
    case XK_Next:      clamp_top(g_top + g_body); break;
    case XK_space:     clamp_top(g_top + g_body); break;
    case XK_BackSpace: clamp_top(g_top - g_body); break;
    case XK_Home:      clamp_top(0); break;
    case XK_End:       clamp_top(g_topmax); break;
    case XK_Left:      clamp_hshift(g_hshift - 8); break;
    case XK_Right:     clamp_hshift(g_hshift + 8); break;
    case XK_F1:        if (g_help_mode) exit_help(); else enter_help(); break;
    case XK_c: case XK_C: g_ku_mode ^= 1; break;
    case XK_Escape:    *running = 0; redraw = 0; break;
    case XK_q: case XK_Q: *running = 0; redraw = 0; break;
    default:
        /* like read.asm's help view: any other key dismisses help --
           back to the file if one is loaded, or quits in demo mode */
        if (g_help_mode) {
            if (g_filebuf) exit_help();
            else { *running = 0; redraw = 0; }
        } else {
            redraw = 0;
        }
        break;
    }
    return redraw;
}

int main(int argc, char **argv) {
    fb_create();
    if (!g_px) { fprintf(stderr, "out of memory\n"); return 1; }

    if (argc >= 2) load_file(argv[1]);
    if (!g_filebuf) enter_help(); /* no file given -> show help, like the DOS demo mode */
    else { g_cur = &g_tab; }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "Cannot open X display\n"); return 1; }
    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    unsigned long black = BlackPixel(dpy, screen);

    Window win = XCreateSimpleWindow(dpy, root, 0, 0, g_win_w, g_win_h, 0, black, black);
    XStoreName(dpy, win, "READ for Linux");

    XSizeHints hints;
    memset(&hints, 0, sizeof(hints));
    hints.flags = PMinSize;      /* resizable -- only a floor, no ceiling, so
                                     the window manager itself won't let the
                                     user drag the window below a usable size */
    hints.min_width = MIN_COLS * CELLW;
    hints.min_height = (MIN_BODY + 1) * CELLH;
    XSetWMNormalHints(dpy, win, &hints);

    Atom wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wm_delete, 1);

    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);

    GC gc = XCreateGC(dpy, win, 0, NULL);
    Visual *visual = DefaultVisual(dpy, screen);
    int depth = DefaultDepth(dpy, screen);
    XImage *ximg = XCreateImage(dpy, visual, (unsigned)depth, ZPixmap, 0,
                                 (char*)g_px, g_win_w, g_win_h, 32, 0);

    render_all();

    int running = 1;
    XEvent ev;
    while (running) {
        XNextEvent(dpy, &ev);
        switch (ev.type) {
        case Expose:
            XPutImage(dpy, win, gc, ximg, 0, 0, 0, 0, g_win_w, g_win_h);
            break;
        case ConfigureNotify: {
            int new_w = ev.xconfigure.width, new_h = ev.xconfigure.height;
            /* A live resize drag floods the queue with ConfigureNotify --
             * one per intermediate size the window manager reports, often
             * many per second. Recreating the framebuffer and doing a full
             * render_all() + full-window XPutImage() for every one of them
             * is wasted work, and over a forwarded display pipe like WSLg
             * (Xwayland -> Weston -> RDP to the Windows host) each of those
             * full-window blits carries real transport overhead, so it
             * shows up as visible lag/stutter while dragging. Drain the
             * queue first and keep only the *last* pending size -- the
             * expensive rebuild below then runs once per drag "settle",
             * not once per intermediate pixel. */
            XEvent next;
            while (XCheckTypedWindowEvent(dpy, win, ConfigureNotify, &next)) {
                new_w = next.xconfigure.width;
                new_h = next.xconfigure.height;
            }
            /* ConfigureNotify fires for moves/stacking too, not just resize
             * -- skip the (common) no-op case, and guard against a bogus
             * 0-sized event rather than malloc(0) */
            if (new_w <= 0 || new_h <= 0) break;
            if (new_w == g_win_w && new_h == g_win_h) break;
            int new_cols = new_w / CELLW;
            if (new_cols < MIN_COLS) new_cols = MIN_COLS;
            int new_body = new_h / CELLH - 1;   /* -1: row 0 is the status bar */
            if (new_body < MIN_BODY) new_body = MIN_BODY;
            g_win_w = new_w; g_win_h = new_h;
            g_cols = new_cols; g_body = new_body;
            XDestroyImage(ximg);   /* frees the old g_px it owns */
            fb_create();
            if (!g_px) { fprintf(stderr, "out of memory\n"); running = 0; break; }
            ximg = XCreateImage(dpy, visual, (unsigned)depth, ZPixmap, 0,
                                 (char*)g_px, g_win_w, g_win_h, 32, 0);
            recompute_bounds(g_cur);  /* NOT calc_limits -- keep scroll pos */
            render_all();
            XPutImage(dpy, win, gc, ximg, 0, 0, 0, 0, g_win_w, g_win_h);
            break;
        }
        case ClientMessage:
            if ((Atom)ev.xclient.data.l[0] == wm_delete) running = 0;
            break;
        case KeyPress: {
            KeySym ks = XLookupKeysym(&ev.xkey, 0);
            int redraw = apply_key(ks, &running);
            /* Key-repeat from holding an arrow/PgDn/etc down (or just fast
             * key-mashing) can queue up several KeyPress events before we
             * get back around to XNextEvent. Apply all of them to the
             * state now and redraw once at the end, rather than once per
             * queued key -- same fix as the ConfigureNotify coalescing
             * above, for the same reason (each full-window XPutImage has
             * real cost over a forwarded display pipe like WSLg). */
            while (running) {
                XEvent next;
                if (!XCheckTypedWindowEvent(dpy, win, KeyPress, &next)) break;
                KeySym ks2 = XLookupKeysym(&next.xkey, 0);
                if (apply_key(ks2, &running)) redraw = 1;
            }
            if (redraw && running) {
                render_all();
                XPutImage(dpy, win, gc, ximg, 0, 0, 0, 0, g_win_w, g_win_h);
            }
            break;
        }
        }
    }

    XDestroyImage(ximg); /* also frees g_px -- it owns the buffer now */
    XFreeGC(dpy, gc);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
