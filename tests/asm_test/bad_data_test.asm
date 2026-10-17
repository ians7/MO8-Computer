; One bad data directive per line, so the data pass must fail with several
; errors rather than stopping at the first.
.section data
	.string unterminated "oops
	.string good "fine"
	.string good "dup name"
	.string badescape "bad \q escape"
	.byte   toobig 300
	.word   ok 0x1234
	.quad   nope 1
	.string missing
.endsection
