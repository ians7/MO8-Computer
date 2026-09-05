_START_:
	MOVI  a 0
LOOP_TAG3:
HELLO2:
	CMPR   b a  ; this is a comment!


	JEQ DONE    ; this also happens to be a comment!

	ADDI  a 16
	ADDI       b 1

	JMP   LOOP_TAG3

DONE:
HALT
