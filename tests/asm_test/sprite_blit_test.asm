; Blits the 16x16 sprite in the data section into the top-left corner of the
; framebuffer, one byte per pixel, then spins.
;
; Register budget, which is the whole difficulty of this program:
;   x   source pointer, walks the sprite bytes
;   fp  destination pointer, walks the framebuffer
;   b   bytes left in the current row
;   sp  rows left. Free only because nothing here pushes, calls or returns.
;   a   the byte in flight, and the zero the counters are compared against
;       once it has been stored.
;
; Only cmpr sets the zero flag -- subi sets carry and nothing else -- so every
; loop test is a cmpr against a register holding zero, which is why a is
; reloaded with 0 after each store.

.section data
	.sprite white_walker "assets/white_walker.ase"
.endsection

.section code
main:
	; x = the sprite's address. No instruction takes a 16-bit immediate, so it
	; is built a byte at a time: >name is the high byte, <name the low byte.
	movi x >white_walker
	slli x 8
	addi x <white_walker

	; fp = 0x8000, the framebuffer origin
	movi fp 0x80
	slli fp 8

	movi sp 16      ; 16 rows
row:
	movi b 16       ; 16 bytes per row

col:
	ld a x
	st a fp
	addi x 1
	addi fp 1

	subi b 1
	movi a 0
	cmpr b a
	jne col

	addi fp 112     ; next framebuffer row: 128 wide - 16 written
	subi sp 1
	movi a 0
	cmpr sp a
	jne row

done:
	jmp done
.endsection
