; Every diagnostic section_pass can emit, one per line group, so the pass must
; fail with several errors rather than one.
	movi a 1        ; outside of any section

.section
.section rodata     ; unknown name
.endsection

.section code
.section data       ; nested open
.endsection

.endsection         ; closes nothing

.section code
	halt            ; never closed
