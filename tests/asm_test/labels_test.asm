; Forward and backward label references, mixed case, and comments in every
; position the tokenizer has to cope with.
_START_:
	MOVI a 0        ; addr 0x0000
	MOVI b 4        ; addr 0x0002

LOOP:               ; addr 0x0004
	CMPR   b a
	JEQ DONE        ; forward reference, resolved on the second sweep

	ADDI  a 16
	JMP   LOOP      ; backward reference, resolved in place
; a comment on its own line emits nothing
DONE:               ; addr 0x000c
	HALT
