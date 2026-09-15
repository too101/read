; STATUS.INC -- status line labels (TIS-620); 02h = bold toggle
; built by _gen.py -- edit text there and re-run

stl_right:
        db 002h,046h,031h,03Ah,002h,048h,065h,06Ch,070h,020h,002h,043h,03Ah,002h,0C3h,0CBh
        db 0D1h,0CAh,020h,002h,045h,073h,063h,03Ah,002h,0CDh,0CDh,0A1h
        db 0

sw_ku:
        db 04Bh,055h
        db 0

sw_tis:
        db 054h,049h,053h
        db 0
