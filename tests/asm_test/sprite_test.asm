; The sprite path is relative to this file, not to the working directory.
.section data
	.sprite spr1 "assets/white_walker.ase"
	.string word "ABC"
  .byte   SPRITE_x  0x30
  .byte   SPRITE_y  0x30
  .byte   BACK_BUF  0xB0
	
	;  TEXT_BASE_ADDR 0xFFFF
	;  KEY_ADDR 0xE000
	;  DISP_PAGE 0xE001
	;  FB_BASE_1  0x8000
	;  FB_BASE_2  0xB000
	;  LEFT   0x1
	;  RIGHT  0x2
	;  UP     0x3
	;  DOWN   0x4
	;  START  0x5
	;  SELECT 0x6
.endsection

.section code
; @FUNCTION MAIN
; no args
MAIN:
	MOVI x 0xE0
	SLLI x 8
	ADDI x 0x01
	
	MOVI a 0x80
	ST a x

LOOP:
	MOVI x 0xE0
	SLLI x 8
	ADDI x 0x00
	LD a x

LEFT:
	MOVI b 0x1
	CMPR a b
	JNE RIGHT
	
	MOVI x >SPRITE_x
	SLLI x 8
	ADDI x <SPRITE_x
	LD b x

	SUBI b 2 ; dx
	ST b x
	JMP LD_SPRT

RIGHT:
	MOVI b 0x2
	CMPR a b
	JNE UP
	
	MOVI x >SPRITE_x
	SLLI x 8
	ADDI x <SPRITE_x
	LD b x

	ADDI b 2 ; dx
	ST b x
	JMP LD_SPRT

UP:
	MOVI b 0x3
	CMPR a b
	JNE DOWN

	MOVI x >SPRITE_y
	SLLI x 8
	ADDI x <SPRITE_y
	LD a x

	SUBI a 2 ; dy
	ST a x

	JMP LD_SPRT

DOWN:
	MOVI b 0x4
	CMPR a b
	JNE LD_SPRT

	MOVI x >SPRITE_y
	SLLI x 8
	ADDI x <SPRITE_y
	LD a x

	ADDI a 2 ; dy
	ST a x

	JMP LD_SPRT

LD_SPRT:
	MOVI x >spr1
	SLLI x 8
	ADDI x <spr1
	
	PUSH x

	MOVI x >SPRITE_x
	SLLI x 8
	ADDI x <SPRITE_x
	LD a x

	PUSH a

	MOVI fp >SPRITE_y
	SLLI fp 8
	ADDI fp <SPRITE_y
	LD a fp
	PUSH a

	CALL CLEAR_SCREEN
	CALL DRAW_STD_SPRITE
	CALL SWAP_BUFFER
	POP fp 
	POP x
	JMP LOOP


; @FUNCTION DRAW_STD_SPRITE
; args: 
;  	1) sprite pointer
;		2) x loc  u8
;		3) y loc  u8 
DRAW_STD_SPRITE:
  ; load the frame buffer
	MOVI fp >BACK_BUF
	SLLI fp 8
	ADDI fp <BACK_BUF

	LD a fp
	SLLI fp 16  ; set to zero

	ADD fp a
	SLLI fp 8

  ; load x
	MOVI x 0
	ADD x sp
	ADDI x 3
	LD b x

	ADD fp b

	; load y
	MOVI x 0
	ADD x sp
	ADDI x 2
	LD b x
	MOVI x 0
	ADD x b
	SLLI x 7

	ADD fp x


	; load sprite address
	MOVI x 0
	ADD x sp
	ADDI x 4
	LD x x

	MOVI b 0  ; inner loop counter

DSS_OUTER:
	PUSH b      ; save row
	MOVI b 0    ; reset column
DSS_INNER:
	LD a x
	ST a fp
	ADDI fp 1
	ADDI x 1
	ADDI b 1
	MOVI a 16
	CMPR b a
	JLT DSS_INNER

	POP b       ; restore row
	ADDI fp 112
	ADDI b 1
	CMPR b a    ; a is still 16
	JLT DSS_OUTER

	RET

DRAW_ASCII_SPRITE:
	MOVI fp 0
	ADD fp sp
	ADDI fp 2
	LD fp fp

	MOVI x 0
	ADD x sp
	ADDI x 4
	LD x x

	MOVI b 0  ; inner loop counter

DAS_OUTER:
	PUSH b      ; save row
	MOVI b 0    ; reset column
DAS_INNER:
	LD a x
	ST a fp
	ADDI fp 1
	ADDI x 1
	ADDI b 1
	MOVI a 8
	CMPR b a
	JLT DAS_INNER

	POP b       ; restore row
	ADDI fp 112
	ADDI b 1
	CMPR b a    ; a is still 16
	JLT DAS_OUTER
	RET


; @ FUNCTION CLEAR_SCREEN
CLEAR_SCREEN:
  ; load the frame buffer
	MOVI fp >BACK_BUF
	SLLI fp 8
	ADDI fp <BACK_BUF

	LD a fp
	MOVI x 0
	ADD x a
	SLLI x 8

	MOVI fp 0     ; value to store, and zero for compares
	MOVI b 96     ; rows

CS_OUTER:
	MOVI a 64     ; words per row
CS_INNER:
	ST fp x
	ADDI x 2
	SUBI a 1
	CMPR a fp
	JNE CS_INNER
	SUBI b 1
	CMPR b fp
	JNE CS_OUTER

	RET

SWAP_BUFFER:
	MOVI x >BACK_BUF
	SLLI x 8
	ADDI x <BACK_BUF
	LD a x

	MOVI fp 0xE0
	SLLI fp 8
	ADDI fp 0x01
	ST a fp       ; display the buffer just drawn

	XORI a 0x30   ; 0x80 <-> 0xB0
	ST a x
	RET

.endsection
