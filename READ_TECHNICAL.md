# READ.COM — เอกสารเทคนิคฉบับสมบูรณ์ (ฉบับ optimized)

โปรแกรมอ่านข้อความภาษาไทยสำหรับ DOS | 8086 assembly (NASM, .COM) | รองรับ CGA / EGA / VGA / HGC
ฟอนต์ไทย AXV 8×19 พร้อมสไตล์ (หนา/ขยาย/เอียง/เส้นใต้เดี่ยว-คู่/ตัวยก/ตัวห้อย) | สลับรหัส KU/TIS | หน้า help ในตัว

เอกสารนี้สรุปสถาปัตยกรรม เทคนิคที่ใช้ บั๊กสำคัญที่พบวิธีแก้ ระบบทดสอบ และไฟล์ทั้งหมดของโปรเจกต์
(อัปเดตล่าสุด: **binary 7,637 ไบต์ (เดิม ~15.3K, เล็กลง 50.2%), source ~1,650 บรรทัด** — หลังรอบ optimize)

> **สรุปรอบ optimize:** เล็กลง **50.2%** (15,349 → 7,637 ไบต์), เร็วขึ้น **~2.4–2.7× ตอนเปิด** และ
> **~2.3–4.7× ต่อการกดปุ่ม** (บน 8088 ก็เร็วขึ้นใกล้เคียงกัน — ดู §11), พิกเซลตรงกับ reference ที่แก้บั๊กแล้ว
> 100% บนไฟล์จริง และ **แก้บั๊ก status bar เพี้ยนตอนเลื่อน** (ชื่อไฟล์ซ้อน) กับบั๊กแฝงอีก 4 จุด

---

## สารบัญ

1. [ภาพรวม](#1-ภาพรวม)
2. [ไฟล์หลักและระบบ build](#2-ไฟล์หลักและระบบ-build)
3. [สถาปัตยกรรมและ memory map](#3-สถาปัตยกรรมและ-memory-map)
4. [ระบบวิดีโอ: detection และการเขียนจอ](#4-ระบบวิดีโอ-detection-และการเขียนจอ)
5. [ฟอนต์และ rendering pipeline](#5-ฟอนต์และ-rendering-pipeline)
6. [Status bar: st_refresh](#6-status-bar-st_refresh)
7. [การเลื่อนหน้าจอ: partial blit](#7-การเลื่อนหน้าจอ-partial-blit)
8. [ตารางบรรทัดและ incremental help](#8-ตารางบรรทัดและ-incremental-help)
9. [การโหลดไฟล์ KU/TIS และ escape codes](#9-การโหลดไฟล์-kutis-และ-escape-codes)
10. [คีย์และ control flow](#10-คีย์และ-control-flow)
11. [เทคนิคเพิ่มความเร็วและผลวัด](#11-เทคนิคเพิ่มความเร็วและผลวัด)
12. [บั๊กสำคัญที่พบและบทเรียน](#12-บั๊กสำคัญที่พบและบทเรียน)
13. [ระบบทดสอบ: emulator harness และ pixel-diff](#13-ระบบทดสอบ-emulator-harness-และ-pixel-diff)
14. [ไฟล์ทั้งหมดของโปรเจกต์](#14-ไฟล์ทั้งหมดของโปรเจกต์)
15. [ใช้งานด่วน](#15-ใช้งานด่วน)

---

## 1. ภาพรวม

READ เป็น full-screen text viewer เขียนด้วย 8086 assembly ล้วน (target: เครื่องจริงยุค DOS) จุดเด่น:

- **เขียน VRAM ตรง** ทุกโหมดภาพ ไม่ผ่าน BIOS int 10h ตอนวาด (ใช้ BIOS เฉพาะตอนตั้งโหมด)
- **ฟอนต์ไทย 8×19 สแกนไลน์** แบบ AXV — ต้นฉบับมาจากโปรแกรม **AxThai** ผู้ใช้แก้ไขเพิ่มเติมก่อน extract เป็นไฟล์ `AXV.FON`
- **Thai glyph composition**: พยัญชนะฐาน + สระบน/ล่าง + วรรณยุกต์ ประกอบรวมใน cell เดียว (ไม่กินคอลัมน์)
- **สไตล์แบบ WordStar**: byte 0x02/0x05/0x0E/0x0F/0x12/0x13/0x14/0x15/0x16/0x17 = toggle หนา/ขยาย/เอียง/เส้นใต้/ตัวยก/ตัวห้อย (15h = เอียงอีกตัวสำหรับไฟล์ RW), 0x1B = อักขระมองไม่เห็น, 01/03/04/06/07/1C-1F = กลืนเงียบ
- **scroll แบบ blit**: เลื่อนทีละบรรทัด/หน้า โดยย้ายพิกเซลใน VRAM แล้ววาดใหม่เฉพาะแถวที่โผล่
- **status bar อัจฉริยะ**: วาดเฉพาะเลข `R:a-b` ที่เปลี่ยน (ตรรกะใหม่หลัง optimize — §6)
- **help ในตัว**: แยก line table ของตัวเอง เข้า-ออก F1 ไม่ต้อง rebuild ตารางของไฟล์
- **ข้อมูลบีบอัด**: ฟอนต์ + help เก็บแบบ RLE ในไบนารี แล้วคลายเข้า BSS ตอนเปิด (§2, §3)

| โหมด | การ์ด | จอ | ขนาดจอตรรกะ | body rows | การจัดเรียง VRAM |
|---|---|---|---|---|---|
| 12h | VGA | 640×480×16 | 80×25 (1 status + 24 body) | 24 | planar, 80 ไบต์/สแกนไลน์ @A000 |
| 10h | EGA | 640×350×16 | 80×18 | 17 | planar, 80 ไบต์/สแกนไลน์ @A000 |
| 06h | CGA | 640×200×2 | 80×10 | 9 | interleaved @B800, bank=y&1, row=y>>1 |
| 07h | HGC | 720×348×1 | 90×18 | 17 | interleaved @B000, bank=y&3, row=y>>2, 90 ไบต์/แถว |

คีย์: ↑↓ = 1 บรรทัด, PgUp/PgDn (หรือ Space/BS) = หน้า, Home/End = บนสุด/ล่างสุด, ←→ = เลื่อนแนวนอน 8 คอลัมน์, `c` = สลับ KU/TIS, **`r`/`R` = วาดใหม่ทั้งหน้าจอ** (กันจอค้างเมื่อเลื่อนเร็วมาก), `q`/Esc = ออก, F1 = help
command line: `read file [/v /e /c /h]` (บังคับการ์ด), `/t` = selftest

---

## 2. ไฟล์หลักและระบบ build

### 2.1 ไฟล์ต้นทาง

| ไฟล์ | หน้าที่ |
|---|---|
| `read.asm` | โปรแกรมหลักทั้งหมด (~1,570 บรรทัด) — ประกอบด้วย `%include` 4 ไฟล์ (รวม `packed.inc`) |
| `STRS.INC` | string หลัก (ชื่อ error, `ku_tab` label) |
| `KU.INC` | `ku_tab` — ตารางแปลง Kaset-RW (KU) 128 ไบต์ (80h-FFh → TIS-620) |
| `STATUS.INC` | `stl_right` (คำใบ้ขวาของ status bar), `sw_ku`/`sw_tis` |
| `AXV.FON` | ฟอนต์ไทย 8×19, 256 ตัวอักษร × 19 ไบต์ = 4,864 ไบต์ — จาก AxThai + ผู้ใช้แก้ไข |
| `HELP.TXT` | เนื้อความ help (TIS-620 + escape codes แบบ WordStar) — ตัดที่ terminator แรกตอน pack |
| `packed.bin` / `packed.inc` | **สร้างอัตโนมัติตอน build**: ฟอนต์ + help บีบ RLE (6,164 → 3,658 ไบต์) + ค่า `FONT_LEN`/`HELP_LEN` |

> **เปลี่ยนจากเดิม:** `AXV.FON`/`HELP.TXT` ไม่ได้ `incbin` ตรง ๆ อีกต่อไป แต่ถูก **pack แบบ RLE** ลง `packed.bin`
> ตอน build แล้วคลายเข้า BSS ตอนโปรแกรมเริ่ม (ลดขนาดไฟล์)

### 2.2 การ build — `build_read.py`

```
python build_read.py
```

ขั้นตอน (ทำในไฟล์เดียวจบ):
1. **pack ข้อมูล**: อ่าน `AXV.FON` + `HELP.TXT` (ตัดที่ 00h/1Ah แรก) → บีบ RLE (`00 <len> <byte>` = run, อื่น = literal) → เขียน `packed.bin` + `packed.inc`
2. เรียก NASM: `nasm -f bin read.asm -o read_raw.com`
3. **เคล็ดลับ org**: NASM 3.x ไม่สนใจ `org` ใน -f bin จึงใช้เทคนิค pad `times 100h db 0` ที่หัวไฟล์ แล้วตัด 0x100 ไบต์แรกทิ้ง → ทุก label ตรงกับ load address จริงของ DOS (ไฟล์ไบต์ที่ 0 = CS:0100)
4. ตรวจว่า 0x100 ไบต์แรกเป็นศูนย์และไบต์ที่ 0x100 = `FC` (cld) กัน build เพี้ยน → เขียน `read.com`

อ้างอิง assembly เอง: `nasm -f bin read.asm -o read_raw.com -l read.lst` → `.lst` ใช้หา address ของ label/variable สำหรับ watchpoint

---

## 3. สถาปัตยกรรมและ memory map

### 3.1 โครงสร้าง .COM และ segment

- CS = DS = ES = SS = PSP segment, image เริ่ม CS:0100
- **invariant สำคัญของทั้งโปรแกรม: DS = CS เสมอ** (data อยู่ใน code segment) และ **DF = 0 เสมอ** (string ops ทุกอันเดินหน้า)
- ES = scratch — **ห้ามสมมติค่าตอนเข้าฟังก์ชัน** (บทเรียนจากบั๊ก, ดู §12) — ฟังก์ชันที่เขียน VRAM ตั้ง ES เองเสมอ (`mov es,[vseg]`)

### 3.2 Memory map (CS-relative)

```
0100h  code start
...    code + class tables (cls_lo/cls_hi/stx), key dispatch (keytab/keyhnd),
       vparm (mode-parameter table), gdc_tab, hgc_crtc, sw_chars/sw_adap,
       st_tpl (status template), STRS/KU/STATUS tables
~0F8Eh packed: ข้อมูลบีบ RLE (font + help) — ~3,658 ไบต์
~1DD8h .bss เริ่ม (bss_start) — ★ ไม่มีในไฟล์ ถูก zero ครั้งเดียวตอนเปิด:
       font8x19(4,864, คลายจาก packed), help_data(คลายจาก packed),
       cls[256], trc[512] (class<<8|char), vrow_tab[512], gofs[256],
       tbl_hi/tbl_lo[256] (pixel-double), dk_tab[256],
       cell_buf/cell_tmp/cell_wide, numbuf, fname(66), help_lin_tab,
       mode/adapter state, viewer state (top/hshift/nlines/…), sv_* (help save)
~4363h bss_end → lin_tab อยู่ตรงนี้ — ตารางบรรทัด "งอกขึ้น" จนถึง F000h
       (พื้นที่ ~44KB, cap แบบ dynamic ≈ 11,000 entries × 4 bytes)
F000h+ กันไว้ให้ stack (SP เริ่ม FFFEh วิ่งลง)
```

> **เปลี่ยนจากเดิม:** ตัวแปร/บัฟเฟอร์/ตารางทั้งหมดย้ายไปอยู่ใน `section .bss` (`resb`/`resw`) — ไม่ใช่ไบต์ในไฟล์
> อีกต่อไป จึงถูก **zero ทั้งชุดครั้งเดียวตอนเปิด** (`rep stosw` จาก `bss_start` ถึง `bss_end`) ตัดไบต์ศูนย์ออกจาก image
> หลายพันไบต์; และ `lin_tab` cap ถูกคำนวณจากพื้นที่ว่างจริง (ไม่ fix 12,288) จึงไม่เล็กกว่าเดิมในทางปฏิบัติ

- **ไฟล์บล็อกข้อมูล**: `blk0`/`blk_end` ชี้ช่วง CS+1000h … CS+8FFFh (64KB ต่อบล็อก, MAXBLK=8) — อยู่นอก image; อ่านด้วย int 21h AH=3Fh ตรง ๆ
- **ตารางคลาสไบต์ `trc[256]` (word/ตัว)**: หัวใจของ optimize — แต่ละ entry = `class<<8 | translated_char` รวมทั้งการแปลง KU→TIS ไว้แล้ว อ่าน 1 ครั้งได้ทั้งคลาส (`C_TERM`/`C_SWAL`/`C_STYLE`/`C_COMB`/`C_TAB`) และรหัส glyph — rebuild เมื่อสลับ code page เท่านั้น (`set_ku`)
- ตัวแปรสถานะวิดีโอ (คัดจาก `vparm` ตอน `gfx_on`): `mode_num`, `vseg`, `bank_mask`, `row_bytes`, `text_cols`, `body`, `vram_size`, `planar`

### 3.3 สถานะหน้าจอ

- `cur_row`/`cur_col` = ตำแหน่ง cell, `cur_y2` = `cur_row*19*2` (index ของ vrow_tab, cache ไว้), `cell_src` = ตัวชี้ glyph/บัฟเฟอร์ที่จะ blit
- `dl_row`/`dl_seg`/`dl_off` = แถว + ตำแหน่งบรรทัดในไฟล์, `dl_vrow`/`dl_vdi` = VRAM offset ของแถว/ของ cell ปัจจุบัน (fast path)
- `top` = บรรทัดแรกที่แสดง, `topmax` = nlines−body, `hshift`, `maxh`
- cell composition: `cell_buf` (glyph ที่ผสมแล้ว), `cell_tmp` (หลัง apply style), `cell_wide` (หลังยืด 2 เท่า), `cell_has`, `exp_prev`/`back` (สไตล์ขยายข้าม mark)

---

## 4. ระบบวิดีโอ: detection และการเขียนจอ

### 4.1 `detect_video` — ลำดับการรู้จำการ์ด (ทดสอบจริงบน DOSBox-X ทุก machine)

1. อ่าน BIOS mode byte 40:49h (= linear 449h, DS=0) — ถ้า 7 → HGC/MDA path
2. int 10h AX=1A00 (VGA identify) — คืน AL=1Ah = VGA
3. **EGA: อ่าน BDA 40:87h (= linear 487h)** — ไม่เป็นศูนย์ = EGA — วัดจริงบน DOSBox-X: svga_s3/ega = 60h, cga/hercules = 00h
4. HGC sync test: อ่าน port 3BAh bit 7 (vsync) รอค่าสลับ (loopz ~32K รอบ, Podanoffsky) → เปลี่ยน = HGC
5. ไม่เข้าเคสไหน = CGA
6. command line `/v /e /c /h` บังคับได้ (`forced`), `/t` = selftest

ข้อควรระวัง (ยังคงเดิม): `int 10h AH=12h BL=10h` ของ DOSBox-X ตอบทุก machine จึง**ใช้แยก EGA ไม่ได้**; สัญญาณที่ใช้ได้จริงคือ 1A00 (VGA), 40:87h (EGA), 3BAh sync (HGC)
(**หมายเหตุ:** BDA ต้องออฟเซ็ตเป็น linear เมื่อ DS=0 — 40:49h = `[449h]`, 40:87h = `[487h]`; เขียนผิดเป็น `[49h]`/`[87h]` จะอ่านตาราง interrupt แล้ว detection พัง)

### 4.2 `gfx_on` — ตั้งโหมดแบบ table-driven

> **เปลี่ยนจากเดิม:** ค่าประจำโหมดทั้งหมดเก็บใน **ตาราง `vparm`** (12 ไบต์/โหมด: mode, vseg, bank_mask, row_bytes,
> text_cols, body, vram_size, planar) แล้ว `gfx_on` แค่ `rep movsb` คัดชุดของ adapter ที่เลือกลงตัวแปร — สั้นกว่าโค้ด
> `mov` แยกรายโหมดเดิมมาก

- VGA: mode 12h, planar=1, vseg=A000, body=24, vram=9600h
- EGA: mode 10h, planar=1, vseg=A000, body=17, vram=6D60h
- HGC: planar=0, vseg=B000, bank_mask=3, row_bytes=90, text_cols=90, body=17 + เขียน 6845 CRTC R0-R11 จาก `hgc_crtc` + port 3BF/3B8
- CGA: mode 6, planar=0, vseg=B800, bank_mask=1
- planar: ปิด/ตั้ง GDC จาก `gdc_tab` (SR=0, ESR=0, rotate=0, write mode 0, bitmask=FF) ให้เขียน 1 ไบต์ = 8 พิกเซลทุก plane
- `go_tab`: **build `vrow_tab`** — LUT 512 words: `vrow_tab[y] = (y & bank_mask)*2000h + (y >> yshift)*row_bytes` (ค่าคูณจาก `vrt_val`)

### 4.3 การกำหนดตำแหน่งสแกนไลน์ — LUT อันเดียวทุกโหมด

> **เปลี่ยนจากเดิม:** ฟังก์ชัน `line_di`/`il_off` (แยก planar ใช้คูณ, interleaved ใช้ LUT) **ถูกถอดทิ้ง** — ตอนนี้
> ทุกโหมดใช้ `vrow_tab[y]` เหมือนกันหมด (planar ก็เก็บ `y*row_bytes` ลง LUT เดียวกัน) จึงไม่มีการคูณบน hot path
> และเหลือโค้ดวาดชุดเดียวที่ทำงานทุกโหมด

### 4.4 ผู้เขียนจอพื้นฐาน

| ฟังก์ชัน | หน้าที่ |
|---|---|
| `clear_screen` | ล้าง vram_size ด้วย `rep stosw` + HGC เปิดวิดีโอท้าย + set `r_len=0` เพื่อบังคับ st_refresh วาด status เต็ม |
| `vband` | แถบขาว inverse 19 สแกนไลน์ — **รับช่วงคอลัมน์ [BP, BP+DX)** (แทน `vband_cols` เดิมที่แยกฟังก์ชัน) |
| `fill_rows(BX=2·y, CX=count, AL=byte, BP=col, DX=nbytes)` | ตัวเติมกลาง: วน `vrow_tab[bx]` + `rep stosw` (word-wide) — ใช้โดย vband/clear/erase-tail |
| `put_glyph` | blit 19 แถวจาก [SI] → VRAM: planar+ไม่ invert = unrolled `movsb`/`add di,79`; อื่น = วน `vrow_tab` (รองรับ inverse ด้วย `xor dl`) |
| `put_wide` | ยืดพิกเซล 2 เท่า (`tbl_hi`/`tbl_lo`) แล้ว blit 2 cell |

> **ถอดออก:** `hline`/เส้นคั่น, `erase_rows` แยก (ยุบเข้า `fill_rows`), `vband_cols` (ยุบเข้า `vband`)

---

## 5. ฟอนต์และ rendering pipeline

### 5.1 โครงสร้างฟอนต์

`font8x19`: 1 glyph = 19 ไบต์ (แถวบนลงล่าง, bit 80h = ซ้ายสุด) คลายจาก `packed` เข้า BSS ตอนเปิด
address ของ glyph = อ่านจาก **`gofs[chr]`** (ตาราง word 256 ตัว = `font8x19 + chr*19` คำนวณล่วงหน้าตอนเปิด) — ตัดการคูณ `chr*19` ออกจากทุกจุดที่ต้องหา glyph

### 5.2 ทางเดินวาด (slow path)

```
draw_line(dl_seg:dl_off, dl_row, hshift)
  ├─ reset: style_reg=0, exp_prev=0, cur_col=0, cell_has=0, cache dl_vrow
  ├─ dl_sk: ข้าม hshift คอลัมน์แบบ style-aware (อ่านคลาสจาก trc: toggle/mark/กลืน กิน 0 คอลัมน์,
  │          ฐานกิน 1 (ขยาย=2))
  ├─ dl_skm: ข้าม leading combining marks
  └─ dl_l: ต่อ byte → RDCH (แปลง+คลาสจาก trc พร้อมข้ามขอบบล็อก) →
           C_TERM? จบ : คลาส 0 (ฐานเรียบ)? fast path : draw_char_c (slow)
           (cur_col ถึง text_cols → dl_ovf วาดเฉพาะ mark)
  └─ dl_done: เติมพื้นที่ที่เหลือของแถวให้ว่าง (fill_rows) — ไม่ต้อง clear ทั้งจอก่อน

draw_char_c(AL=char, AH=class):
  C_STYLE → style_toggle (xor mask จาก stx[])   C_SWAL|C_TERM → ไม่วาด
  C_COMB (สระบน/ล่าง + วรรณยุกต์):
      cell_has=0 → dc_base (วาดเป็นฐาน); ไม่งั้น OR glyph เข้า cell_buf ของฐานก่อน
      (materialise ครั้งแรกด้วย movsb, OR แบบ word) แล้ว dc_draw ซ้ำ — ไม่เพิ่มคอลัมน์
  อื่น (ฐาน) → dc_base: cell_src=glyph, back=0, dc_draw, cell_has=1, cur_col++ (ขยาย=+2)

dc_draw: pg col=(cur_col-back), row=cur_row
  style_reg=0 → put_glyph ตรง ๆ จาก cell_src
  ไม่งั้น → copy → cell_tmp → apply_style → (expand? put_wide : put_glyph)

apply_style (ต่อ style_reg bits):
  01 bold = OR with self>>1   40 italic = shear (rows 0-3 >>2, 4-11 >>1)
  10 sub = เลื่อนลง 3          20 super = เลื่อนขึ้น 5
  08 underline = แถว 17 = FF   04 double = แถว 17,18 = FF
     ★ ข้ามถ้า cell_buf[17]/[18] มีหมึกอยู่แล้ว (อักษรหาง/สระล่าง) — เช็คหลังผสม mark
  02 expand = put_wide
```

> **ถอดออก (dead code):** `dc_tone`/`cell_or_sh4` (ทางวรรณยุกต์ที่ไม่เคยถูกเรียกจริง), ตัวแปร `cell_tall`
> และ `set_tall` (ไม่ถูกใช้แล้ว), การ copy cell ซ้ำซ้อน — ทั้งหมดตัดทิ้ง

**สรุปรหัสที่ "กลืน":** 00, 0D/0A, 1A, 1B, 01/03/04/06/07/1C-1F + รหัสสไตล์ (toggle แล้วหาย) — จำแนกทั้งหมดจาก `cls`/`trc` ในลุกเดียว

### 5.3 Fast path (อักษรเรียบ) — จุด optimize หลักของการวาด

ใน `dl_l` ถ้า **class=0 (ฐานเรียบ) + planar + ไม่ invert + style_reg=0** (เช็คใน `dl_fix`):

- **blit glyph จาก font → VRAM ตรง ๆ** ด้วย unrolled `movsb`/`add di,79` โดยใช้ `gofs[chr]` หาต้น glyph และตัวชี้ VRAM ที่เดินสะสม (`dl_vdi`) — **ไม่ผ่าน cell_buf copy, ไม่ apply_style, ไม่ dispatch**
- ตั้ง `cell_src` = glyph นั้น (เผื่อ mark ตามหลังมาผสม), `cell_has=1`, `exp_prev=0`, `cur_col++`
- mark/สไตล์ตกไป slow path (`draw_char_c`) ตามเดิม
- ผล: full redraw เร็วขึ้นมาก โดยเฉพาะเนื้อหาอักษรเรียบอย่างหน้า help (เร็วต่อปุ่ม ~4.7×)

---

## 6. Status bar: st_refresh

โครงสร้างแถวบน: **แถบขาว inverse 19 สแกนไลน์** + ข้อความ inverse:
`<b>fname</b> C:<hshift> R:<top+1>-<last> <KU|TIS>` + คำใบ้ชิดขวา (`stl_right`) — ประกอบจาก template `st_tpl` (01=fname, 03=hshift, 04=เลข R, 06=ป้าย KU/TIS)

**`st_refresh` — ตรรกะใหม่ (แก้บั๊กชื่อไฟล์เพี้ยน):**

1. `fmt_digits`: ประกอบ `"<top+1>-<last>"` ลง `numbuf`, คืน **ความยาว (AL)**
2. **เทียบเฉพาะความยาวของช่องเลข** กับ `r_len` (ความยาวรอบก่อน):
   - **เท่าเดิม** (เช่น `12-35` → `13-36`) → **partial**: `vband(r_c0, len)` ล้างเฉพาะคอลัมน์ตัวเลข แล้ว `puts(numbuf)` ที่ `cur_col = r_c0` (inverse) — **ไม่แตะชื่อไฟล์เลย**
   - **ต่างกัน** (เช่น `1-24` → `11-34`, เพิ่มหลัก) → **full**: `vband` เต็มแถว + วาด `st_tpl` + คำใบ้ขวา, จำ `r_len`/`r_c0` ใหม่
3. `clear_screen` set `r_len=0` → หลัง clear บังคับ full เสมอ (กัน "status หาย")

> **★ เปลี่ยนจากเดิม — นี่คือจุดแก้บั๊กที่ผู้ใช้เจอ:** ของเดิมเทียบ `status_buf` กับ `status_shadow`
> **ทีละไบต์** แล้วจำแนก diff เป็น inside/outside ช่วง R: เมื่อ **จำนวนหลักของเลขเปลี่ยน** (เช่นเลื่อนถึงบรรทัด 11:
> `R:1-24` → `R:11-34`) ทุกไบต์หลังจุดนั้น "เลื่อน" ไป 1 → การเทียบ lockstep เหลื่อม → เข้าใจผิดว่าไบต์ของ
> **ชื่อไฟล์**เปลี่ยน แล้วไปวาดทับชื่อไฟล์ผิดคอลัมน์ (เห็นเป็น `\cw\CWi6.DOC` ซ้อนกัน + เส้นใต้แหว่ง)
> ฉบับใหม่วัดแค่ "ความยาวช่องเลข" ถ้าเท่าเดิมก็แตะเฉพาะคอลัมน์เลข ถ้าเปลี่ยนก็วาดทั้งแถบใหม่สะอาด —
> **ชื่อไฟล์ไม่ถูก partial update แตะเด็ดขาด** (ยืนยัน: การเลื่อนแบบ partial ให้ผลตรงกับ full redraw ทุกตำแหน่ง ทุกโหมด)

> **ถอดออก:** `rd_build`, `status_shadow`, `st_shadow`, `vband_cols`, span cache `r_b0/r_b1/r_c1/sh_rc1` — แทนด้วย `r_len`/`r_c0` สองตัว

ข้อจำกัดที่ถูกต้องตามดีไซน์: การเลื่อนแนวนอน/สลับรหัส = full redraw อยู่แล้ว (C: เปลี่ยนได้เฉพาะตอนนั้น) จึงไม่กระทบ partial

---

## 7. การเลื่อนหน้าจอ: partial blit

**`do_scroll(AX = top ที่ต้องการ, signed/unclamped)`** — clamp [0,topmax], คำนวณ δ = new−old, commit `[top]`:

- δ = 0 → ไม่วาด
- |δ| ≥ body → `redraw` (วาดเต็ม)
- ไม่งั้น → **partial**:

```
scroll_body: ย้าย (body-|δ|) แถวใน VRAM ทีละสแกนไลน์ผ่าน vrow_tab (ทำงานทุกโหมด)
  ★ ย้ายด้วย rep movsw (word-wide), index จาก LUT ทั้ง src/dst,
    forward (δ>0) เดินขึ้น, backward (δ<0) เดินลง จากสแกนไลน์สุดท้าย
  DS=ES=vseg (ตั้งเอง — ห้ามพึ่ง caller)
δ>0: เนื้อหาวิ่งขึ้น → เปิด+วาด |δ| แถวล่างสุด    δ<0: → เปิด+วาด |δ| แถวบนสุด
  draw_rows_e: fill_rows ล้างแถวที่โผล่ + draw_row วาดใหม่ (★ วาด "ทุก" แถวที่โผล่)
ปิดท้าย: call st_refresh
```

> **แก้จากเดิม:** ของเดิมวาดใหม่เฉพาะ **แถวเดียว** ที่โผล่ → การเลื่อนหลายบรรทัดทีเดียวทิ้งแถวเก่าค้าง; ฉบับใหม่วาด **ทุก** แถวที่โผล่

Home/End ใช้ full redraw (`jmp view_loop`) — ถูกต้องเพราะกระโดดไกล

---

## 8. ตารางบรรทัดและ incremental help

### 8.1 `build_lines` — เดิน stream สร้าง lin_tab

- เดินไฟล์ (ข้ามขอบบล็อกอัตโนมัติ: SI ครบ 0FFFFh → ES += 1000h) หยุดที่ 00h/1Ah
- **จำแนกไบต์จาก `cls[]`** (ตารางเดียวกับ render) — mark/กลืน ไม่เพิ่มคอลัมน์, style นับเป็นคอลัมน์ (ตรงกับ TREAD), CR/LF/CRLF = ตัวแบ่ง, จำกัด 255 คอลัมน์/บรรทัด (`dl`)
- entry = 4 ไบต์ (seg:off) — cap ด้วย `lin_lim` (dynamic, จนถึง 0F000h)
- **de-escape**: ไม่ต้องมี pass แยกตัด 1Bh อีกต่อไป — 1Bh ถูกจัดเป็น `C_SWAL` (กลืนตอน build/render) โดยตรง

### 8.2 สองตาราง — ไม่ทำลายของไฟล์ตอนเข้า help

```
lin_base dw  →  ชี้ตาราง active: lin_tab (ไฟล์) หรือ help_lin_tab (help)
lin_lim  dw  →  ขอบบนของตาราง (0F000h สำหรับไฟล์ / ท้าย help_lin_tab สำหรับ help)
```

- **enter_help**: save top/hshift/nlines/maxlen/ku (5 words) + set `blk0=CS` → `lin_base=help_lin_tab` → **build help แบบ lazy ครั้งเดียว** (`help_built`, จำ `help_nlines`) → recompute `topmax` → top=0 — ตารางของไฟล์**ไม่ถูกแตะ**
- **exit_help**: restore state + `set_blk` (คืน blk0/blk_end ของไฟล์) + recompute `topmax` + `lin_base=lin_tab` — **ไม่มี build_lines** (เร็วมาก)

---

## 9. การโหลดไฟล์ KU/TIS และ escape codes

- `parse_tail`: อ่าน command tail ที่ 81h — `/v /e /c /h /t` (จับด้วย `scasb` กับ `sw_chars`), อื่น ๆ = ชื่อไฟล์ → `fname`
- `load_file`: int 21h AH=3D00h → อ่านทีละ 32KB ลง block (DS=บล็อก) → close (ไม่มี de-escape pass แยก)
- `detect_ku`: สแกน 4KB แรก (ผ่าน `dk_tab` ตัวช่วย) นับ 0A3h/0A5h — **ถ้าตัวใด > 2% = KU** ไม่งั้น TIS → เรียก `set_ku`
- **`set_ku(CL=mode)`**: **rebuild `trc[256]`** — สำหรับทุกไบต์ ถ้า KU และ ≥80h แปลงผ่าน `ku_tab` ก่อน แล้วเก็บ `class<<8|char`; การแปลง KU จึงเกิด "ครั้งเดียวต่อการสลับโหมด" ไม่ใช่ทุกไบต์ตอนวาด
- `c` เรียก `set_ku` สลับโหมด live แล้ววาดใหม่

---

## 10. คีย์และ control flow

```
m_st → (มีไฟล์? load/detect_ku/build_lines/calc_limits : enter_help) → view_loop:
  view_loop: call redraw → v_key: xor ah,ah / int 16h
  F1 → help_mode? exit_help : enter_help → view_loop
  จัดคีย์ด้วย dispatch table: normalize (ext key = scan|80h, ASCII = lower) →
    scasb ใน keytab → jmp [keyhnd+bx]:
      ↑/↓ = do_scroll(top±1)      PgUp/PgDn/Space/BS = do_scroll(top±body)
      Home/End = top 0/topmax → view_loop   ←/→ = hshift ±8 → view_loop
      c = set_ku(สลับ) → view_loop           q/Esc = v_quit
  ใน help: อักษรทั่วไป = ออกจาก help (มีไฟล์) หรือออกโปรแกรม (demo)
```

> **เปลี่ยนจากเดิม:** แทน ladder `cmp al,<key>/je` ยาว ๆ ด้วย **ตาราง dispatch** (`keytab` + `keyhnd`) — เล็กและเร็วคงที่

`redraw` = clear_screen → draw_rows (1..body) → `st_refresh`

---

## 11. เทคนิคเพิ่มความเร็วและผลวัด

วัดด้วย emulator 8086 แบบ instruction-accurate (Unicorn) + โมเดล cycle ตามตาราง Intel 8086 (EA cost, branch taken/not-taken, string ops ต่อรอบ) เทียบ `read_orig.com` (15,349 ไบต์) กับฉบับ optimize (7,637 ไบต์):

| Metric | เดิม | ใหม่ | ดีขึ้น |
|---|---:|---:|---:|
| ขนาดไฟล์ | 15,349 B | **7,637 B** | **50.2% (2.01×)** |
| ตอนเปิด + วาดจอแรก | ~6.0–7.9 M cyc | ~2.2–3.3 M cyc | **~2.4–2.7×** |
| วาดใหม่ต่อการกดปุ่ม (เฉลี่ย) | ~1.3–2.1 M cyc | ~0.36–0.89 M cyc | **~2.3–4.7×** |

รายฉาก (cycle, VGA/Hercules):

| ฉาก | ตอนเปิด (เดิม→ใหม่) | ต่อปุ่ม (เดิม→ใหม่) |
|---|---|---|
| หน้า help (VGA) | 6.03M → 2.21M (**2.7×**) | 1.69M → 0.36M (**4.7×**) |
| ผสมไทย/สไตล์ (VGA) | 7.21M → 2.89M (**2.5×**) | 1.95M → 0.83M (**2.3×**) |
| ผสม + สลับ KU (VGA) | 5.38M → 2.15M (**2.5×**) | 1.32M → 0.56M (**2.4×**) |
| ผสม (Hercules) | 7.86M → 3.29M (**2.4×**) | 2.15M → 0.89M (**2.4×**) |
| ไฟล์ KU (VGA) | 7.43M → 2.90M (**2.6×**) | 2.02M → 0.84M (**2.4×**) |

**บน 8088** (บัสข้อมูล 8-bit, +4 clock ต่อการเข้าถึง word): เร็วขึ้นใกล้เคียงกัน — **~2.5–2.7× ตอนเปิด, ~2.2–4.6× ต่อปุ่ม** และในความเป็นจริงน่าจะมากกว่านี้อีกนิด เพราะ 8088 fetch-bound (คิว prefetch 4 ไบต์) ไบนารีที่เล็กลงครึ่งหนึ่ง + chain `cmp` ที่หายไป = ไบต์คำสั่งให้ fetch น้อยลงมาก (โมเดลนี้ยังไม่ credit ส่วนนั้นเต็ม)

เทคนิคที่ใช้ (เรียงตามผล):

1. **ตารางคลาส/แปลง `trc[256]`** — lookup เดียวแทน chain `cmp`/`je` จำแนกไบต์ + แปลง KU (rebuild เมื่อสลับโหมดเท่านั้น)
2. **fast glyph path** — blit ตรงจาก font → VRAM (unrolled movsb) ข้าม cell pipeline สำหรับอักษรเรียบ
3. **vrow_tab LUT ทุกโหมด** — ตัด `mul` หาสแกนไลน์ + เหลือโค้ดวาดชุดเดียว
4. **word-wide ops** (`stosw`/`movsw`) — clear/band/compose/scroll ย้าย 2 ไบต์/รอบ
5. **key dispatch table** แทน ladder
6. **partial status** (§6) + **incremental help** (§8) — ไม่ rebuild ตอนออก help
7. **pack font+help (RLE)** + **ย้าย data ไป BSS** (zero ครั้งเดียว) — ลดขนาดไฟล์ครึ่งหนึ่ง
8. **ตัด dead code** (dc_tone/cell_or_sh4/set_tall/hline ฯลฯ)

หมายเหตุ 8088: word ops (ข้อ 4) ได้ประโยชน์ **น้อยลง**เล็กน้อยเพราะ penalty เข้าถึง word แต่ข้อ 1/3/7 (โค้ดเล็กลง) ได้ประโยชน์ **มากขึ้น** — สุทธิยังเป็นบวกใกล้ 8086

---

## 12. บั๊กสำคัญที่พบและบทเรียน

จับด้วย emulator harness + pixel-diff (§13) แก้แล้วทั้งหมด — แยกเป็นบั๊กเดิมที่พบตอน RE/optimize และบั๊กที่แก้ในรอบ optimize:

| # | อาการ | ต้นตอ | บทเรียน |
|---|---|---|---|
| ★1 | **status bar เพี้ยน/ชื่อไฟล์ซ้อนตอนเลื่อน** (เห็นตอนถึงบรรทัด 11: `R:11-34`) | เทียบ shadow ทีละไบต์เหลื่อมเมื่อเลข R เพิ่มหลัก → วาดทับคอลัมน์ชื่อไฟล์ผิด | เทียบ "ความยาวช่องเลข" พอ — ถ้าเปลี่ยนก็วาดทั้งแถบใหม่ อย่า partial ข้าม field ที่ยาวเปลี่ยน (แก้ในรอบ optimize) |
| ★2 | สระลอยเลื่อน 1 คอลัมน์หลังตัวขยาย | fast path ไม่ reset `exp_prev` | reset flag ทุกที่ที่ปล่อยฐาน (แก้ในรอบ optimize) |
| ★3 | เลื่อนหลายบรรทัดทีเดียวทิ้งแถวเก่าค้าง | partial scroll วาดใหม่แค่แถวเดียว | วาด "ทุก" แถวที่โผล่ (แก้ในรอบ optimize) |
| ★4 | มาร์คขยะที่คอลัมน์ 0 บนบรรทัด > 255 คอลัมน์ | `cur_col` (ไบต์) ล้นวน 0 | saturate ที่ 255 (แก้ในรอบ optimize) |
| 5 | เลื่อนครั้งที่ 2 จอค้าง | `scroll_body` push/pop cx คลาด ลูปวิ่งทับ VRAM | นับลูปด้วย reg ที่ rep ไม่แตะ |
| 6 | เลื่อนขึ้นแล้วเนื้อหาเหลื่อม | backward `rep movsb` เริ่มผิดปลาย | string ย้อนทางต้องชี้ "ท้าย" หน้าต่าง |
| 7 | erase เงียบบน VGA/EGA | ตั้ง `[vseg]` ไม่ครบทุกโหมด | config ครบทุกโหมด อย่าพึ่ง default |
| 8 | จอเพี้ยนเป็นจังหวะ | fast path คืน ES=เซกเมนต์ไฟล์ | **อย่าเชื่อ ES ของ caller** — เขียน VRAM ตั้ง ES เอง |
| 9 | พิกเซลขยะรูปตัวอักษร | `movsb` ไป buffer ผ่าน ES=A000 | ทุก movsb ไป data ต้องตั้ง ES=CS ก่อน |
| 10 | F1 แล้วหลุดโปรแกรม | push/pop ใน enter_help ไม่ครบ | push/pop ต้อง pair |
| 11 | help ว่าง (nlines=1) | build เริ่ม offset 0 แทน help_data | ใช้ `build_start` เป็นจุดเริ่ม |
| 12 | detect EGA/HGC พังทั้งชุด | อ่าน BDA `[49h]`/`[87h]` แทน linear 449h/487h | BDA = segment 40h; DS=0 ต้องบวก 400h |
| 13 | บั๊กปลอมจาก harness | test inject คีย์ผิด boundary / emu8086 `imul` unsigned | เช็ค harness ก่อนเชื่อ diff |
| ★14 | **ไฟล์ที่มีไบต์ `00` แทรกกลางเนื้อหาแสดงผลไม่จบ** (พบจากไฟล์จริงที่มี `00` เป็น filler ของตารางเส้นกรอบ — หยุดที่ราวบรรทัด 30 ทั้งที่ไฟล์มีเป็นร้อยบรรทัด) | โค้ดเดิม (และรอบ optimize แรกที่ยังไม่รู้ตัว) เช็ค "จบไฟล์" ด้วย **ค่า** ไบต์ (`cmp al,0`/`1Ah`) แทนตำแหน่งจริง ทั้งใน `build_lines` และ path วาด | แยกคำถาม "อ่านมาจริงถึงไหน" ออกจาก "ไบต์นี้แปลว่าอะไร" — บันทึกตำแหน่งจบจริง (`buf_end_seg`/`buf_end_off`) ครั้งเดียวตอนโหลด แล้วเทียบ**ตำแหน่ง**ใน `RDCH`/`peek`/`build_lines`; จัดคลาส `00` เป็น C_SWAL (ควบคุมที่ไม่แสดงผลแต่ไม่จบบรรทัด) ส่วน `1Ah` (`^Z`) ยังคงเป็น C_TERM ตามธรรมเนียม DOS เพราะไฟล์จริงจบด้วย `^Z` แล้วไม่มีเนื้อหาต่อ |
| 15 | **เปิดไฟล์ช้าลง 47–120 เท่า จนจอค้างในโหมด CGA/HGC** (พบระหว่างตรวจสอบการแก้ ★14) | แก้ ★14 เพิ่มการใช้ `mov cx,es` เป็น scratch ใน `build_lines` แล้วปล่อยให้ CH ไม่เท่ากับ 0 ตอน return; `redraw` โหลดจำนวนแถวด้วย `mov cl,[body]` (ไบต์เดียว) ก่อนเรียก `draw_rows` ซึ่งใช้ `loop` (เต็ม CX) — เดิมรอดเพราะ CH บังเอิญเป็น 0 มาก่อนเสมอ | ทุกจุดที่โหลดตัวนับด้วย `mov cl,` ก่อนใช้กับ `loop`/`rep` ต้อง `xor ch,ch` เสมอ อย่าพึ่งค่าที่ "บังเอิญ" เป็น 0 จากโค้ดก่อนหน้า (แก้ตรงตามแพตเทิร์นที่จุดเรียก `draw_rows` อีกจุดใน `do_scroll` ทำไว้ถูกอยู่แล้ว) |

**invariant ที่ระบบพึ่งพา (อย่าทำลาย):** DS=CS ตลอด, DF=0 ตลอด, ES ไม่มีค่ารับประกันตอนเข้าฟังก์ชัน, สไตล์เป็น line-local (draw_line reset เอง), CH ต้องเคลียร์เองก่อนใช้กับ `loop`/`rep` ทุกครั้งที่โหลดแค่ CL

**การเปลี่ยนพฤติกรรมอื่น (ไม่ใช่บั๊ก):** `/t` selftest ไม่รอ 15 วินาทีอีกต่อไป — กดคีย์ใดก็กลับ DOS ทันที; ไบต์ `09` (tab) ขยายเป็น 8 ช่องว่างแล้ว (เดิมวาดเป็น glyph ขยะจากฟอนต์ index 9 และนับแค่ 1 คอลัมน์) — คลาสใหม่ `C_TAB` (`10h`); `RDCH` เก็บจำนวนช่องว่างที่ค้างจ่ายไว้ในตัวแปร `tab_run` (อ่านไบต์จริงครั้งเดียว คืนค่าเป็นช่องว่าง 8 ครั้งติดกันโดยไม่ขยับตำแหน่งอ่านซ้ำ) ส่วน `build_lines` แค่บวกคอลัมน์ทีละ 8 (มี saturate ที่ 255 เหมือนเดิม) เพราะนับคอลัมน์ไม่ต้องขยายจริง ตรวจแล้วว่าให้พิกเซลตรงกับการพิมพ์ช่องว่าง 8 ตัวจริง ๆ ทุกโหมดจอ

---

## 13. ระบบทดสอบ: emulator harness และ pixel-diff

รอบ optimize ใช้ harness แบบ instruction-accurate เพื่อยืนยัน "พิกเซลตรงเป๊ะ" + วัด cycle:

### 13.1 harness (Unicorn-based)

| ไฟล์ | ใช้ทำ |
|---|---|
| `emu.py` | รัน `.COM` จริงบน Unicorn (16-bit real mode) + shim DOS/BIOS (int 21h open/read/close, int 16h ป้อนคีย์, int 10h ตั้งโหมด + BDA + port 3BAh) → ดึง framebuffer จาก VRAM ตามโหมด (planar/de-interleave CGA/HGC) เป็นบิตแมพมาตรฐาน |
| `cyc.py` | โมเดล cycle 8086 (decode ด้วย iced-x86) — EA cost, branch penalty, string ops ต่อรอบ; มีสวิตช์ `CPU8088` เพิ่ม penalty word access |
| `suite.py` | ชุดสถานการณ์: help, ผสมไทย/สไตล์/KU, ไฟล์ใหญ่, ว่าง/บรรทัดเดียว/ไม่มี EOL/หาไม่เจอ, ทุกโหมด — เทียบพิกเซลกับ reference |
| `cmp.py` / `fuzz.py` | เทียบ 2 ไบนารีทุกฉาก / สุ่ม ~600 ไฟล์เทียบพิกเซล |
| `speed2.py` / `prof.py` | วัด cycle ตอนเปิด+ต่อปุ่ม / โปรไฟล์ต่อฟังก์ชันจาก listing |

### 13.2 วิธีมาตรฐาน "pixel-diff verification"

1. สร้าง reference จากไบนารีเดิม (แก้บั๊กที่รู้แล้ว) → เก็บภาพต่อปุ่ม
2. รันไบนารีใหม่ลำดับเดียวกัน → เทียบพิกเซลต้อง = 0 ไบต์ต่าง
3. ทำซ้ำทุกโหมด (VGA/EGA/CGA/HGC) และ ~600 ไฟล์สุ่ม
4. **partial vs full audit**: เทียบผลเลื่อนแบบ partial ของไบนารีใหม่กับ full-redraw ของตัวเอง (พิสูจน์การแก้ status bar §6) — ได้ 0 ต่าง ทุกตำแหน่ง ทุกโหมด
5. เจอ diff → เครื่องมือชี้จุด (scanline/col, watch write) → แก้ → วนจน 0

> เครื่องมือชุดเดิมของโปรเจกต์ (emu8086.py, verify_seq.py, vram_diff.py, DOSBox-X configs ฯลฯ) ยังใช้จับภาพจริง/ตรวจ detection ได้ตามเดิม — ดู §14.3–14.4

---

## 14. ไฟล์ทั้งหมดของโปรเจกต์

### 14.1 ตัวโปรแกรมและ asset (แก้ได้)

| ไฟล์ | คำอธิบาย |
|---|---|
| `read.asm` | ซอร์สหลัก (~1,570 บรรทัด) |
| `STRS.INC` | strings หลัก |
| `KU.INC` | ตารางแปลง KU→TIS |
| `STATUS.INC` | ข้อความ status bar |
| `AXV.FON` | ฟอนต์ไทย 8×19 (4,864 ไบต์) — จาก AxThai + ผู้ใช้แก้เพิ่ม |
| `HELP.TXT` | เนื้อ help (แก้แล้ว rebuild) |

### 14.2 build + deploy

| ไฟล์ | คำอธิบาย |
|---|---|
| `build_read.py` | pack ข้อมูล → build → ตัด pad → `read.com` |
| `packed.bin` / `packed.inc` | ผล pack (สร้างอัตโนมัติทุก build — ไม่ต้องเก็บใน source control) |
| `read.com` | binary สุดท้าย (**7,637 ไบต์**) |
| `read.lst` | listing (offset ทุก label — ใช้ทำ watchpoint) |

### 14.3 optimization harness (รอบ optimize)

| ไฟล์ | คำอธิบาย |
|---|---|
| `emu.py` | Unicorn emulator + shim DOS/BIOS + framebuffer capture |
| `cyc.py` | โมเดล cycle 8086/8088 (iced-x86) |
| `suite.py`, `cmp.py`, `fuzz.py` | ชุดทดสอบพิกเซล + fuzz ~600 ไฟล์ |
| `speed2.py`, `prof.py` | benchmark cycle / โปรไฟล์ต่อฟังก์ชัน |

### 14.4 เครื่องมือ/งานวิเคราะห์เดิมของโปรเจกต์ (ยังใช้ได้ — ค้างไว้เป็นประวัติ)

- `emu8086.py`, `verify_seq.py`, `vram_diff*.py`, `bench_keys.py`, `profile_draw.py`, `get_addr.py`, `findret.py`, `trace_*.py`, `watch_*.py`, `rowid.py`, `threeway.py` ฯลฯ — harness/tracer ชุดเดิม
- `dvprobe.asm`/`build_probe.py`/`dv_*.conf` — probe ตรวจ video detection บน DOSBox-X จริง
- `t_*.conf`, `tread_*.conf`, `ku_*.conf`, `pngread.py` — จับภาพจริง + อ่าน capture
- `ax*`, `fon_*`, `tread_*`, `rw_*`, `make_v*.py`, `HANDOFF.md`, `TREAD_*.md` ฯลฯ — งาน RE/สกัดฟอนต์/ประวัติเวอร์ชันยุคแรก

---

## 15. ใช้งานด่วน

```
# build (pack + assemble + strip pad)
python build_read.py

# ทดสอบพิกเซลตรงเป๊ะ + วัดเร็ว (รอบ optimize)
python cmp.py read_orig.com read.com        # เทียบทุกฉากทุกโหมด
python fuzz.py                               # สุ่ม ~600 ไฟล์
python speed2.py                             # cycle ตอนเปิด/ต่อปุ่ม (CPU8088=1 = โหมด 8088)

# รันจริง
READ.COM file.txt            # auto-detect การ์ด
READ.COM file.txt /h         # บังคับ HGC, /t = selftest
```
