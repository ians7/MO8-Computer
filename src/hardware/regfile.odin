package hardware

import "core:log"

/*
* Runtime diagnostics go through context.logger rather than straight to stderr.
* Under `odin test` that logger funnels every message down a channel to the
* single reporting thread, so messages come out ordered and attributed to the
* test that produced them; writing to stderr directly bypasses that and the
* progress renderer paints over whatever collides with a redraw.
*
* They are logged at warning level, never error. core:testing counts anything at
* .Error or above as a test failure, and several tests feed deliberately invalid
* input to check it is refused -- at error level those tests would fail for
* doing their job. Anything a test may legitimately provoke belongs below
* .Error; the callee reports the failure through its ok return either way.
*/

Registers :: struct {
	/* Main Registers */
	a:     u8, // accumulator
	b:     u8, // general use register

	/* Index Register */
	x:     u16, // general use 16-bit pointer, for indexing memory

	/* Stack Pointer Register */
	sp:    u16, // stack pointer

	/* Function Address Reg */
	fp:    u16,

	/* Program Counter */
	pc:    u16,

	/* Status Register */
	flags: u8,
}

PC :: proc(m: ^Machine) -> ^u16 {
	return &m.regs.pc
}

SP :: proc(m: ^Machine) -> ^u16 {
	return &m.regs.sp
}

FP :: proc(m: ^Machine) -> ^u16 {
	return &m.regs.fp
}

X :: proc(m: ^Machine) -> ^u16 {
	return &m.regs.x
}

FLAGS :: proc(m: ^Machine) -> ^u8 {
	return &m.regs.flags
}

// Register codes as they appear in the dst (bits 10-8) and src (bits 2-0)
// fields. Every register is nameable by an operand; 7 is unassigned.
R_A :: 0
R_B :: 1
R_FP :: 2
R_X :: 3
R_SP :: 4
R_PC :: 5
R_FLAGS :: 6

// Registers are not all the same width, so every operand goes through one
// width-aware pair rather than through a pointer whose type would have to pick
// a width in advance. Values are widened to u16 on the way out and truncated on
// the way back in, which is what keeps a and b behaving as bytes while fp, sp
// and pc keep all sixteen bits.
//
// reg_max is the largest value the register can hold, so a caller can flag a
// carry at the right boundary rather than always at 0xFF.
RegRead :: proc(m: ^Machine, reg_idx: u16) -> (val: u16, reg_max: int, ok: bool) {
	switch (reg_idx) {
	case R_A:
		return u16(m.regs.a), int(max(u8)), true
	case R_B:
		return u16(m.regs.b), int(max(u8)), true
	case R_FP:
		return m.regs.fp, int(max(u16)), true
	case R_X:
		return m.regs.x, int(max(u16)), true
	case R_SP:
		return m.regs.sp, int(max(u16)), true
	case R_PC:
		return m.regs.pc, int(max(u16)), true
	case R_FLAGS:
		return u16(m.regs.flags), int(max(u8)), true
	case:
		log.warnf("invalid register code %d", reg_idx)
	}
	return 0, 0, false
}

RegWrite :: proc(m: ^Machine, reg_idx: u16, val: u16) -> bool {
	switch (reg_idx) {
	case R_A:
		m.regs.a = u8(val)
	case R_B:
		m.regs.b = u8(val)
	case R_FP:
		m.regs.fp = val
	case R_X:
		m.regs.x = val
	case R_SP:
		m.regs.sp = val
	case R_PC:
		m.regs.pc = val
	case R_FLAGS:
		m.regs.flags = u8(val)
	case:
		log.warnf("invalid register code %d", reg_idx)
		return false
	}
	return true
}

// How many bytes the register occupies in memory. This is the rule push, pop,
// ld and st all follow: a register moves its own width, so `push a` is one byte
// and `push pc` is two. Without it a 16-bit register would silently lose its
// high half on the way to the stack.
//
// This one needs no machine: width is a property of the code, not of any
// particular machine's state.
RegWidth :: proc(reg_idx: u16) -> (width: u16, ok: bool) {
	switch (reg_idx) {
	case R_A, R_B, R_FLAGS:
		return 1, true
	case R_FP, R_X, R_SP, R_PC:
		return 2, true
	case:
		log.warnf("invalid register code %d", reg_idx)
	}
	return 0, false
}
