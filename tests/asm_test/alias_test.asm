; call/ret are the only aliases; each is several real instructions wide, so
; the addresses after them depend on the widths in INST_DATA.
MAIN:
	MOVI a 0xEF
	PUSH a
	MOVI a 0xBE
	PUSH a
	MOVI a 0xAD
	PUSH a
	MOVI a 0xDE
	PUSH a
	CALL HELPER     ; 8 instructions wide -> 16 bytes
	HALT            ; addr 0x0020

HELPER:             ; addr 0x0022
	MOVI a 0x80
	MOVI b 0xFE
	ST b a
	ADDI a 1
	MOVI b 0xED
	ST b a
	ADDI a 1
	MOVI b 0xBE
	ST b a
	ADDI a 1
	MOVI b 0xEF
	ST b a
	RET
