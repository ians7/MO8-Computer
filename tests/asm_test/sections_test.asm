; Both section kinds, with a label, an alias and an operand form per section so
; the debug dump has something to tag in each.
.section data
	.string greeting "Hello, World!"     ; spaces and a ';' inside quotes
	.string prompt   "> \0 quoted \" \\ \ttabbed\n"
	.ascii  raw      "NOTERM"
	.byte   answer   42
	.word   origin   0x8000
.endsection

.section code
main:
	movi a 0x01
	push a
	call helper
	pop b           ; pops main's own push, not the return address call pushed
	halt

helper:
	addi a 1
	ret
.endsection
