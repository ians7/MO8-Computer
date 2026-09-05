package tests

import "../src/assembler/"
import hw "../src/hardware"
import "core:reflect"
import "core:strings"
import "core:testing"

/*
* Every test declares its own machine and hands out a pointer to it:
*
*     m: hw.Machine
*     reset_cpu(&m)
*
* which is what lets the suite run on as many threads as the runner cares to
* use. It was a package-level global until the tests were parallelised, so each
* test's starting state depended on whatever the one before it had left behind;
* that only held together while the runner was pinned to a single thread.
*
* The machine lives in the test's own frame rather than on the heap. A heap
* Machine works too, but every test frees its 64K block and the next test's
* allocation gets the same block straight back -- in a serialised run all 45 of
* them landed on one address. That is safe, because machine_init zeroes the
* whole struct before the test sees it, but it makes "this test's machine" and
* "the block the last test just released" the same object, so a stale pointer
* held past a test's end would still read as valid. A frame local is scoped by
* the language instead, and needs no matching free.
*/

// Brings a machine to power-on state. Used to initialise one at the top of a
// test, and again between the independent cases inside a test.
reset_cpu :: proc(m: ^hw.Machine) {
	hw.machine_init(m)
}

// Register indices as they appear in the dst (bits 10-8) and src (bits 2-0)
// fields. These are the hardware's own codes rather than a second copy of the
// table: a copy would keep passing after a renumbering while every real
// instruction started naming the wrong register. Codes 3 and 7 are unassigned.
R_A :: hw.R_A
R_B :: hw.R_B
R_FP :: hw.R_FP
R_SP :: hw.R_SP
R_PC :: hw.R_PC
R_FLAGS :: hw.R_FLAGS

// The two codes the register file deliberately does not assign. Naming one is
// an error rather than an alias onto a real register, and several tests below
// check that the error is refused rather than absorbed.
R_UNASSIGNED :: [?]u16{3, 7}

// Instruction builders, one per operand form in docs/cpu-spec.md. Building from
// the Op enum rather than hard-coded hex means an opcode renumbering moves these
// tests with it instead of silently testing the wrong instruction.
rr :: proc(op: hw.Op, dst, src: u16) -> u16 {
	return u16(op) << 11 | (dst & 0x07) << 8 | (src & 0x07)
}

ri :: proc(op: hw.Op, dst: u16, imm: u8) -> u16 {
	return u16(op) << 11 | (dst & 0x07) << 8 | u16(imm)
}

sr :: proc(op: hw.Op, reg: u16) -> u16 {
	return u16(op) << 11 | (reg & 0x07) << 8
}

// Jumps carry a signed offset in bits 10-0 rather than an address. Masking in
// signed space is what encodes a negative one, exactly as the assembler's REL
// does: -8 & 0x07FF is 0x07F8.
rel :: proc(op: hw.Op, off: i16) -> u16 {
	return u16(op) << 11 | u16(off & 0x07FF)
}

bare :: proc(op: hw.Op) -> u16 {
	return u16(op) << 11
}

expect_flag :: proc(t: ^testing.T, m: ^hw.Machine, flag: hw.S, msg: string, loc := #caller_location) {
	testing.expectf(
		t,
		m.regs.flags & u8(flag) != 0,
		"%s (flags = 0b%08b)",
		msg,
		m.regs.flags,
		loc = loc,
	)
}

expect_no_flag :: proc(
	t: ^testing.T,
	m: ^hw.Machine,
	flag: hw.S,
	msg: string,
	loc := #caller_location,
) {
	testing.expectf(
		t,
		m.regs.flags & u8(flag) == 0,
		"%s (flags = 0b%08b)",
		msg,
		m.regs.flags,
		loc = loc,
	)
}

/* ---------------------------------------------------------------- reg-reg */

@(test)
add_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 1
	m.regs.b = 2
	hw.exec_inst(&m, rr(.ADD, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(3))
	testing.expect_value(t, m.regs.b, u8(2)) // src is left alone

	// 8-bit result wraps
	reset_cpu(&m)
	m.regs.a = 0xFF
	m.regs.b = 1
	hw.exec_inst(&m, rr(.ADD, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0))
	expect_flag(t, &m, .carry, "add: 0xFF + 1 should carry out")
}

@(test)
sub_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 5
	m.regs.b = 3
	hw.exec_inst(&m, rr(.SUB, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(2))

	// borrow wraps around
	reset_cpu(&m)
	m.regs.a = 0
	m.regs.b = 1
	hw.exec_inst(&m, rr(.SUB, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0xFF))
}

@(test)
mul_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 6
	m.regs.b = 7
	hw.exec_inst(&m, rr(.MUL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(42))

	// 16 * 16 == 256, which does not fit in 8 bits
	reset_cpu(&m)
	m.regs.a = 16
	m.regs.b = 16
	hw.exec_inst(&m, rr(.MUL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0))
	expect_flag(t, &m, .of, "mul: 16 * 16 overflows 8 bits")
}

@(test)
div_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// NOTE: divide-by-zero is not covered here; DIV has no guard, so it would
	// trap and take the whole test binary with it.
	reset_cpu(&m)
	m.regs.a = 20
	m.regs.b = 5
	hw.exec_inst(&m, rr(.DIV, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(4))

	// integer division truncates
	reset_cpu(&m)
	m.regs.a = 7
	m.regs.b = 2
	hw.exec_inst(&m, rr(.DIV, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(3))
}

@(test)
not_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b0000_1111
	hw.exec_inst(&m, rr(.NOT, R_A, R_A))
	testing.expect_value(t, m.regs.a, u8(0b1111_0000))

	reset_cpu(&m)
	m.regs.a = 0
	hw.exec_inst(&m, rr(.NOT, R_A, R_A))
	testing.expect_value(t, m.regs.a, u8(0xFF))
}

@(test)
or_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1010
	m.regs.b = 0b0101
	hw.exec_inst(&m, rr(.OR, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b1111))
}

@(test)
xor_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1100
	m.regs.b = 0b1010
	hw.exec_inst(&m, rr(.XOR, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b0110))

	// xor with itself is the idiomatic register clear
	reset_cpu(&m)
	m.regs.b = 0x5A
	hw.exec_inst(&m, rr(.XOR, R_B, R_B))
	testing.expect_value(t, m.regs.b, u8(0))
}

@(test)
and_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1100
	m.regs.b = 0b1010
	hw.exec_inst(&m, rr(.AND, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b1000))
}

@(test)
srl_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// logical shift: the vacated high bits come in as zero
	reset_cpu(&m)
	m.regs.a = 0b1000_0000
	m.regs.b = 3
	hw.exec_inst(&m, rr(.SRL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b0001_0000))

	reset_cpu(&m)
	m.regs.a = 0xFF
	m.regs.b = 4
	hw.exec_inst(&m, rr(.SRL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0x0F))
}

@(test)
sll_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// logical shift left: the vacated low bits come in as zero
	reset_cpu(&m)
	m.regs.a = 0b0000_0001
	m.regs.b = 3
	hw.exec_inst(&m, rr(.SLL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b0000_1000))

	// each step is a multiply by two, so bits shifted off the top are lost
	reset_cpu(&m)
	m.regs.a = 0b1100_0000
	m.regs.b = 1
	hw.exec_inst(&m, rr(.SLL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b1000_0000))

	// shifting by the full register width clears it
	reset_cpu(&m)
	m.regs.a = 0xFF
	m.regs.b = 8
	hw.exec_inst(&m, rr(.SLL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0))

	// sll and srl are inverses when nothing falls off either end
	reset_cpu(&m)
	m.regs.a = 0b0000_1111
	m.regs.b = 2
	hw.exec_inst(&m, rr(.SLL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b0011_1100))
	hw.exec_inst(&m, rr(.SRL, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0b0000_1111))
}

@(test)
every_register_is_nameable_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// The point of the width-aware accessors: one operand encoding reaches all
	// six registers, and each keeps its own width rather than the width the
	// accessor happened to pick.
	reset_cpu(&m)
	hw.exec_inst(&m, ri(.MOVI, R_A, 0x11))
	hw.exec_inst(&m, ri(.MOVI, R_B, 0x22))
	hw.exec_inst(&m, ri(.MOVI, R_FP, 0x33))
	hw.exec_inst(&m, ri(.MOVI, R_SP, 0x44))
	hw.exec_inst(&m, ri(.MOVI, R_PC, 0x55))
	hw.exec_inst(&m, ri(.MOVI, R_FLAGS, 0x66))

	testing.expect_value(t, m.regs.a, u8(0x11))
	testing.expect_value(t, m.regs.b, u8(0x22))
	testing.expect_value(t, m.regs.fp, u16(0x33))
	testing.expect_value(t, m.regs.sp, u16(0x44))
	testing.expect_value(t, m.regs.pc, u16(0x55))
	testing.expect_value(t, m.regs.flags, u8(0x66))

	// a 16-bit register keeps its high half through a reg-reg op; an 8-bit one
	// still truncates, exactly as it did when it was reached as a ^u8
	reset_cpu(&m)
	m.regs.fp = 0xFF00
	m.regs.sp = 0x00FF
	hw.exec_inst(&m, rr(.ADD, R_FP, R_SP))
	testing.expect_value(t, m.regs.fp, u16(0xFFFF))

	reset_cpu(&m)
	m.regs.a = 0xFF
	m.regs.b = 0x01
	hw.exec_inst(&m, rr(.ADD, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0x00))
	expect_flag(t, &m, hw.S.carry, "8-bit add still carries at 0xFF")

	// and the 16-bit add above must not have carried at 0xFF
	reset_cpu(&m)
	m.regs.fp = 0x00FF
	m.regs.sp = 0x0001
	hw.exec_inst(&m, rr(.ADD, R_FP, R_SP))
	testing.expect_value(t, m.regs.fp, u16(0x0100))
	expect_no_flag(t, &m, hw.S.carry, "16-bit add must carry at 0xFFFF, not 0xFF")

	// an unassigned code is refused rather than aliasing onto a real register
	reset_cpu(&m)
	m.regs.a = 0x11
	hw.exec_inst(&m, ri(.MOVI, 3, 0x99))
	testing.expect_value(t, m.regs.a, u8(0x11))
}

@(test)
slli_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// same shift as sll, but the count rides in the immediate field instead of
	// costing a register
	reset_cpu(&m)
	m.regs.a = 0b0000_0001
	hw.exec_inst(&m, ri(.SLLI, R_A, 3))
	testing.expect_value(t, m.regs.a, u8(0b0000_1000))

	// b is not consumed holding the count, which is the whole point on a
	// two-register machine
	testing.expect_value(t, m.regs.b, u8(0))

	// shifting an 8-bit register by its full width clears it
	reset_cpu(&m)
	m.regs.a = 0xFF
	hw.exec_inst(&m, ri(.SLLI, R_A, 8))
	testing.expect_value(t, m.regs.a, u8(0))

	// fp is 16 bits, so the same shift keeps its bits instead of dropping them
	reset_cpu(&m)
	m.regs.fp = 0x00FF
	hw.exec_inst(&m, ri(.SLLI, R_FP, 8))
	testing.expect_value(t, m.regs.fp, u16(0xFF00))
}

@(test)
srli_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1000_0000
	hw.exec_inst(&m, ri(.SRLI, R_A, 3))
	testing.expect_value(t, m.regs.a, u8(0b0001_0000))
	testing.expect_value(t, m.regs.b, u8(0))

	// slli and srli are inverses when nothing falls off either end
	reset_cpu(&m)
	m.regs.a = 0b0000_1111
	hw.exec_inst(&m, ri(.SLLI, R_A, 2))
	testing.expect_value(t, m.regs.a, u8(0b0011_1100))
	hw.exec_inst(&m, ri(.SRLI, R_A, 2))
	testing.expect_value(t, m.regs.a, u8(0b0000_1111))

	reset_cpu(&m)
	m.regs.fp = 0xFF00
	hw.exec_inst(&m, ri(.SRLI, R_FP, 8))
	testing.expect_value(t, m.regs.fp, u16(0x00FF))
}

@(test)
ld_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// src holds the address, dst receives the byte
	reset_cpu(&m)
	m.memory[0x42] = 0x99
	m.regs.b = 0x42
	hw.exec_inst(&m, rr(.LD, R_A, R_B))
	testing.expect_value(t, m.regs.a, u8(0x99))
	testing.expect_value(t, m.memory[0x42], u8(0x99)) // load does not disturb memory

	// The address comes out of its register at full width, so a 16-bit address
	// register reaches past the first 256 bytes. Held in b this address would
	// have truncated to 0x34.
	reset_cpu(&m)
	m.memory[0x1234] = 0x77
	m.regs.sp = 0x1234
	hw.exec_inst(&m, rr(.LD, R_A, R_SP))
	testing.expect_value(t, m.regs.a, u8(0x77))

	// a 16-bit destination moves two bytes, low byte first
	reset_cpu(&m)
	m.memory[0x0200] = 0xEF
	m.memory[0x0201] = 0xBE
	m.regs.sp = 0x0200
	hw.exec_inst(&m, rr(.LD, R_FP, R_SP))
	testing.expect_value(t, m.regs.fp, u16(0xBEEF))
}

@(test)
st_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Mirror of LD: src holds the address, dst supplies the byte. cpu-spec.md
	// describes st as storing "the destination register at a memory address",
	// which is this direction.
	reset_cpu(&m)
	m.regs.a = 0x5A
	m.regs.b = 0x42
	hw.exec_inst(&m, rr(.ST, R_A, R_B))
	testing.expect_value(t, m.memory[0x42], u8(0x5A))
	testing.expect_value(t, m.regs.a, u8(0x5A)) // store does not disturb the register

	// same full-width address as ld
	reset_cpu(&m)
	m.regs.a = 0x5A
	m.regs.sp = 0x1234
	hw.exec_inst(&m, rr(.ST, R_A, R_SP))
	testing.expect_value(t, m.memory[0x1234], u8(0x5A))

	// and a 16-bit source writes two bytes, low byte at the lower address
	reset_cpu(&m)
	m.regs.fp = 0xBEEF
	m.regs.sp = 0x0200
	hw.exec_inst(&m, rr(.ST, R_FP, R_SP))
	testing.expect_value(t, m.memory[0x0200], u8(0xEF))
	testing.expect_value(t, m.memory[0x0201], u8(0xBE))

	// st then ld through the same 16-bit address is a round trip
	reset_cpu(&m)
	m.regs.fp = 0xCAFE
	m.regs.sp = 0x0300
	hw.exec_inst(&m, rr(.ST, R_FP, R_SP))
	m.regs.fp = 0
	hw.exec_inst(&m, rr(.LD, R_FP, R_SP))
	testing.expect_value(t, m.regs.fp, u16(0xCAFE))
}

@(test)
cmpr_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// greater than -> carry
	reset_cpu(&m)
	m.regs.a = 5
	m.regs.b = 3
	hw.exec_inst(&m, rr(.CMPR, R_A, R_B))
	expect_flag(t, &m, .carry, "cmpr: 5 > 3 should set carry")

	// equal -> zero
	reset_cpu(&m)
	m.regs.a = 6
	m.regs.b = 6
	hw.exec_inst(&m, rr(.CMPR, R_A, R_B))
	expect_flag(t, &m, .zero, "cmpr: 6 == 6 should set zero")

	// less than -> negative
	reset_cpu(&m)
	m.regs.a = 3
	m.regs.b = 9
	hw.exec_inst(&m, rr(.CMPR, R_A, R_B))
	expect_flag(t, &m, .n, "cmpr: 3 < 9 should set n")

	// operands are read-only
	testing.expect_value(t, m.regs.a, u8(3))
	testing.expect_value(t, m.regs.b, u8(9))
}

/* -------------------------------------------------------------- immediate */

@(test)
mov_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	hw.exec_inst(&m, ri(.MOVI, R_A, 0x42))
	testing.expect_value(t, m.regs.a, u8(0x42))

	// movi overwrites rather than combining
	hw.exec_inst(&m, ri(.MOVI, R_A, 0x11))
	testing.expect_value(t, m.regs.a, u8(0x11))

	// each register is addressable
	reset_cpu(&m)
	hw.exec_inst(&m, ri(.MOVI, R_B, 0x33))
	testing.expect_value(t, m.regs.b, u8(0x33))
	testing.expect_value(t, m.regs.a, u8(0))
}

@(test)
addi_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 1
	hw.exec_inst(&m, ri(.ADDI, R_A, 2))
	testing.expect_value(t, m.regs.a, u8(3))

	reset_cpu(&m)
	m.regs.a = 0xFF
	hw.exec_inst(&m, ri(.ADDI, R_A, 1))
	testing.expect_value(t, m.regs.a, u8(0))
	expect_flag(t, &m, .carry, "addi: 0xFF + 1 should carry out")
}

@(test)
subi_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 5
	hw.exec_inst(&m, ri(.SUBI, R_A, 3))
	testing.expect_value(t, m.regs.a, u8(2))

	reset_cpu(&m)
	m.regs.a = 0
	hw.exec_inst(&m, ri(.SUBI, R_A, 1))
	testing.expect_value(t, m.regs.a, u8(0xFF))
}

@(test)
xori_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1100
	hw.exec_inst(&m, ri(.XORI, R_A, 0b1010))
	testing.expect_value(t, m.regs.a, u8(0b0110))
}

@(test)
andi_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1100
	hw.exec_inst(&m, ri(.ANDI, R_A, 0b1010))
	testing.expect_value(t, m.regs.a, u8(0b1000))
}

@(test)
ori_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.a = 0b1100
	hw.exec_inst(&m, ri(.ORI, R_A, 0b0011))
	testing.expect_value(t, m.regs.a, u8(0b1111))
}

@(test)
cmp_replaces_previous_flags_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// A compare has to describe *this* comparison. If it only ORs bits in, the
	// carry from the first compare survives the second and every branch after
	// it reads a stale condition.
	reset_cpu(&m)
	m.regs.a = 5
	m.regs.b = 3
	hw.exec_inst(&m, rr(.CMPR, R_A, R_B)) // 5 > 3 -> carry
	expect_flag(t, &m, .carry, "cmpr: 5 > 3 should set carry")

	m.regs.b = 9
	hw.exec_inst(&m, rr(.CMPR, R_A, R_B)) // 5 < 9 -> n, and carry no longer holds
	expect_flag(t, &m, .n, "cmpr: 5 < 9 should set n")
	expect_no_flag(t, &m, .carry, "cmpr: 5 < 9 should clear the carry from the previous compare")
	expect_no_flag(t, &m, .zero, "cmpr: 5 < 9 should leave zero clear")
}

/* ---------------------------------------------------------------- address */

// Jumps add their offset to PC when taken, and leave it alone when not, so a
// not-taken branch is observable as PC holding exactly what it held before.
//
// exec_inst never advances PC itself -- the fetch does that, before the
// instruction runs -- so the offset lands on whatever PC holds here. These
// tests seed PC at 0x10 and jump +0x20, giving 0x30. In a real run PC would
// already point at the instruction after the jump, which is what makes the
// offset relative to the following instruction rather than to the jump.

@(test)
jmp_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// jmp is unconditional: it ignores the flags entirely
	reset_cpu(&m)
	m.regs.pc = 0x10
	hw.exec_inst(&m, rel(.JMP, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero) | u8(hw.S.carry) | u8(hw.S.n)
	hw.exec_inst(&m, rel(.JMP, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))
}

@(test)
jne_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// taken when the previous compare was not equal, which covers both sides:
	// greater than (carry) and less than (n). Testing only the carry side hides
	// a condition that checks the wrong bits, since carry is the one flag whose
	// masked value is 1.
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.carry)
	hw.exec_inst(&m, rel(.JNE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.n)
	hw.exec_inst(&m, rel(.JNE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// not taken when equal
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JNE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))
}

@(test)
jeq_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JEQ, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.carry)
	hw.exec_inst(&m, rel(.JEQ, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))
}

@(test)
jgt_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.carry)
	hw.exec_inst(&m, rel(.JGT, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// equal is not greater than
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JGT, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))
}

@(test)
jge_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// greater
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.carry)
	hw.exec_inst(&m, rel(.JGE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// or equal
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JGE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// less than is neither
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.n)
	hw.exec_inst(&m, rel(.JGE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))
}

@(test)
jlt_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.n)
	hw.exec_inst(&m, rel(.JLT, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// equal is not less than
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JLT, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))
}

@(test)
jle_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// less
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.n)
	hw.exec_inst(&m, rel(.JLE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// or equal
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JLE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// greater than is neither
	reset_cpu(&m)
	m.regs.pc = 0x10
	m.regs.flags = u8(hw.S.carry)
	hw.exec_inst(&m, rel(.JLE, 0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))
}

@(test)
jump_backwards_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// The whole point of a signed offset: a loop jumps back to its own top.
	m.regs.pc = 0x30
	hw.exec_inst(&m, rel(.JMP, -8))
	testing.expect_value(t, m.regs.pc, u16(0x28))

	// The conditionals take the same field, so the sign extension cannot be
	// something jmp alone gets right.
	reset_cpu(&m)
	m.regs.pc = 0x30
	m.regs.flags = u8(hw.S.zero)
	hw.exec_inst(&m, rel(.JEQ, -0x20))
	testing.expect_value(t, m.regs.pc, u16(0x10))

	// An offset of zero is a jump to the instruction that follows, which under
	// the real fetch is simply the next one -- not a self-jump.
	reset_cpu(&m)
	m.regs.pc = 0x30
	hw.exec_inst(&m, rel(.JMP, 0))
	testing.expect_value(t, m.regs.pc, u16(0x30))

	// Backwards past zero wraps, because pc is sixteen bits and the offset is
	// added to it. Nothing special happens at the bottom of memory.
	reset_cpu(&m)
	m.regs.pc = 0x0002
	hw.exec_inst(&m, rel(.JMP, -8))
	testing.expect_value(t, m.regs.pc, u16(0xFFFA))
}

@(test)
jump_offset_range_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// The field is eleven bits, bits 10-0, so it reaches -1024..1023 -- much
	// further than the eight bits an immediate gets. These are the ends of it.
	m.regs.pc = 0x8000
	hw.exec_inst(&m, rel(.JMP, 1023))
	testing.expect_value(t, m.regs.pc, u16(0x83FF))

	reset_cpu(&m)
	m.regs.pc = 0x8000
	hw.exec_inst(&m, rel(.JMP, -1024))
	testing.expect_value(t, m.regs.pc, u16(0x7C00))

	// The two values either side of zero, where an off-by-one in the sign
	// extension would show up as a jump 2048 bytes wrong.
	reset_cpu(&m)
	m.regs.pc = 0x8000
	hw.exec_inst(&m, rel(.JMP, -1))
	testing.expect_value(t, m.regs.pc, u16(0x7FFF))

	reset_cpu(&m)
	m.regs.pc = 0x8000
	hw.exec_inst(&m, rel(.JMP, 1))
	testing.expect_value(t, m.regs.pc, u16(0x8001))

	// The offset borrows the bits the other forms use for a register, so an
	// offset that sets them must not be read as naming one. -256 encodes as
	// 0x0700, which fills the register field, and a jump must still touch no
	// register but pc.
	reset_cpu(&m)
	m.regs.pc = 0x8000
	hw.exec_inst(&m, rel(.JMP, -256))
	testing.expect_value(t, m.regs.pc, u16(0x7F00))
	testing.expect_value(t, m.regs.a, u8(0))
	testing.expect_value(t, m.regs.b, u8(0))
}

/* ------------------------------------------------------------ single-reg */

@(test)
push_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	m.regs.sp = 0x0100
	m.regs.b = 0x5A
	hw.exec_inst(&m, sr(.PUSH, R_B))

	// the stack grows down: sp moves first, then the byte lands under it
	testing.expect_value(t, m.regs.sp, u16(0x00FF))
	testing.expect_value(t, m.memory[0x00FF], u8(0x5A))
	testing.expect_value(t, m.regs.b, u8(0x5A)) // push does not disturb the register
}

@(test)
pop_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// pop is the inverse: read at sp, then move sp back up
	reset_cpu(&m)
	m.regs.sp = 0x00FF
	m.memory[0x00FF] = 0x5A
	hw.exec_inst(&m, sr(.POP, R_A))

	testing.expect_value(t, m.regs.a, u8(0x5A))
	testing.expect_value(t, m.regs.sp, u16(0x0100))

	// push then pop is a round trip that leaves the stack where it started
	reset_cpu(&m)
	m.regs.sp = 0x0100
	m.regs.a = 0x5A
	hw.exec_inst(&m, sr(.PUSH, R_A))
	m.regs.a = 0
	hw.exec_inst(&m, sr(.POP, R_A))
	testing.expect_value(t, m.regs.a, u8(0x5A))
	testing.expect_value(t, m.regs.sp, u16(0x0100))
}

@(test)
push_pop_width_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// A register moves its own width, so a 16-bit push takes two bytes off the
	// stack instead of quietly dropping its high half.
	reset_cpu(&m)
	m.regs.sp = 0x0100
	m.regs.fp = 0xBEEF
	hw.exec_inst(&m, sr(.PUSH, R_FP))

	testing.expect_value(t, m.regs.sp, u16(0x00FE))
	testing.expect_value(t, m.memory[0x00FE], u8(0xEF)) // low byte, lower address
	testing.expect_value(t, m.memory[0x00FF], u8(0xBE))

	// pop reads them back in the order push wrote them
	m.regs.fp = 0
	hw.exec_inst(&m, sr(.POP, R_FP))
	testing.expect_value(t, m.regs.fp, u16(0xBEEF))
	testing.expect_value(t, m.regs.sp, u16(0x0100))

	// pushing pc is what a call has to do to leave a return address behind
	reset_cpu(&m)
	m.regs.sp = 0x0100
	m.regs.pc = 0x0240
	hw.exec_inst(&m, sr(.PUSH, R_PC))
	m.regs.pc = 0xFFFF
	hw.exec_inst(&m, sr(.POP, R_PC))
	testing.expect_value(t, m.regs.pc, u16(0x0240))
	testing.expect_value(t, m.regs.sp, u16(0x0100))
}

/* ------------------------------------------------------------ no-operand */

@(test)
jmpf_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// jmpf takes no operand at all: the target comes from fp, which is 16 bits
	// wide, so unlike the address-class jumps it can reach the whole 64K space.
	reset_cpu(&m)
	m.regs.pc = 0x0010
	m.regs.fp = 0xBEEF
	hw.exec_inst(&m, bare(.JMPF))
	testing.expect_value(t, m.regs.pc, u16(0xBEEF))

	// it is unconditional, like jmp
	reset_cpu(&m)
	m.regs.pc = 0x0010
	m.regs.fp = 0x0240
	m.regs.flags = u8(hw.S.zero) | u8(hw.S.carry) | u8(hw.S.n)
	hw.exec_inst(&m, bare(.JMPF))
	testing.expect_value(t, m.regs.pc, u16(0x0240))

	// fp is a source here, not a destination
	testing.expect_value(t, m.regs.fp, u16(0x0240))

	// reaching past the 8-bit address field is the whole point of the
	// instruction: this target is not encodable in jmp's immediate
	reset_cpu(&m)
	m.regs.fp = 0xFF00
	hw.exec_inst(&m, bare(.JMPF))
	testing.expect_value(t, m.regs.pc, u16(0xFF00))
}

@(test)
halt_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// There is no run loop or halted state yet, so the only observable effect
	// is that halt decodes as itself and disturbs nothing.
	reset_cpu(&m)
	m.regs.a = 0x11
	m.regs.b = 0x22
	m.regs.pc = 0x0040
	m.regs.sp = 0x0100

	op := hw.exec_inst(&m, bare(.HALT))

	testing.expect_value(t, op, hw.Op.HALT)
	testing.expect_value(t, m.regs.a, u8(0x11))
	testing.expect_value(t, m.regs.b, u8(0x22))
	testing.expect_value(t, m.regs.pc, u16(0xFFFF))
	testing.expect_value(t, m.regs.sp, u16(0x0100))
}

/* --------------------------------------------------------- register file */

// exec_inst never touches a register field directly; every operand goes through
// RegRead/RegWrite/RegWidth. The registers are not all the same width, so that
// trio is where widening, truncation and the carry boundary are decided, and a
// mistake in it shows up as an instruction that looks correct but writes the
// wrong number of bits.

@(test)
reg_read_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Values come out widened to u16, and each register reports the largest
	// value it can hold so a caller can flag a carry at the right boundary
	// rather than always at 0xFF.
	reset_cpu(&m)
	m.regs.a = 0x11
	m.regs.b = 0x22
	m.regs.fp = 0x3344
	m.regs.sp = 0x5566
	m.regs.pc = 0x7788
	m.regs.flags = 0x99

	Case :: struct {
		reg:      u16,
		name:     string,
		val:      u16,
		reg_max:  int,
	}
	for c in ([]Case {
			{R_A, "a", 0x0011, 0xFF},
			{R_B, "b", 0x0022, 0xFF},
			{R_FP, "fp", 0x3344, 0xFFFF},
			{R_SP, "sp", 0x5566, 0xFFFF},
			{R_PC, "pc", 0x7788, 0xFFFF},
			{R_FLAGS, "flags", 0x0099, 0xFF},
		}) {
		val, reg_max, ok := hw.RegRead(&m, c.reg)
		if !testing.expectf(t, ok, "RegRead(%s) returned ok=false", c.name) {
			continue
		}
		testing.expectf(t, val == c.val, "RegRead(%s): got 0x%04x, want 0x%04x", c.name, val, c.val)
		testing.expectf(
			t,
			reg_max == c.reg_max,
			"RegRead(%s): got reg_max 0x%x, want 0x%x",
			c.name,
			reg_max,
			c.reg_max,
		)
	}
}

@(test)
reg_write_truncates_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Writes go the other way: a value is truncated to the register's own
	// width, which is what keeps a and b behaving as bytes while fp, sp and pc
	// keep all sixteen bits.
	reset_cpu(&m)
	testing.expect(t, hw.RegWrite(&m, R_A, 0x1234), "RegWrite(a) returned ok=false")
	testing.expect(t, hw.RegWrite(&m, R_B, 0x12FF), "RegWrite(b) returned ok=false")
	testing.expect(t, hw.RegWrite(&m, R_FLAGS, 0xBEEF), "RegWrite(flags) returned ok=false")
	testing.expect(t, hw.RegWrite(&m, R_FP, 0xBEEF), "RegWrite(fp) returned ok=false")
	testing.expect(t, hw.RegWrite(&m, R_SP, 0xCAFE), "RegWrite(sp) returned ok=false")
	testing.expect(t, hw.RegWrite(&m, R_PC, 0xF00D), "RegWrite(pc) returned ok=false")

	testing.expect_value(t, m.regs.a, u8(0x34))
	testing.expect_value(t, m.regs.b, u8(0xFF))
	testing.expect_value(t, m.regs.flags, u8(0xEF))
	testing.expect_value(t, m.regs.fp, u16(0xBEEF))
	testing.expect_value(t, m.regs.sp, u16(0xCAFE))
	testing.expect_value(t, m.regs.pc, u16(0xF00D))

	// A read of what was just written round-trips through the widening.
	for reg in ([]u16{R_A, R_B, R_FP, R_SP, R_PC, R_FLAGS}) {
		before, _, _ := hw.RegRead(&m, reg)
		hw.RegWrite(&m, reg, before)
		after, _, _ := hw.RegRead(&m, reg)
		testing.expectf(
			t,
			before == after,
			"register %d: writing back its own value changed it (0x%04x -> 0x%04x)",
			reg,
			before,
			after,
		)
	}
}

@(test)
reg_width_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Width is a property of the register code, not of any machine's state, so
	// RegWidth takes no machine. It is the rule push, pop, ld and st all follow.
	Case :: struct {
		reg:   u16,
		name:  string,
		width: u16,
	}
	for c in ([]Case {
			{R_A, "a", 1},
			{R_B, "b", 1},
			{R_FLAGS, "flags", 1},
			{R_FP, "fp", 2},
			{R_SP, "sp", 2},
			{R_PC, "pc", 2},
		}) {
		width, ok := hw.RegWidth(c.reg)
		if !testing.expectf(t, ok, "RegWidth(%s) returned ok=false", c.name) {
			continue
		}
		testing.expectf(t, width == c.width, "RegWidth(%s): got %d, want %d", c.name, width, c.width)
	}

	// The width the accessor reports and the width the register actually holds
	// have to agree, or a push writes a different number of bytes than a pop
	// reads back.
	for reg in ([]u16{R_A, R_B, R_FLAGS, R_FP, R_SP, R_PC}) {
		width, _ := hw.RegWidth(reg)
		_, reg_max, _ := hw.RegRead(&m, reg)
		want_max := width == 1 ? int(max(u8)) : int(max(u16))
		testing.expectf(
			t,
			reg_max == want_max,
			"register %d is %d bytes wide but reports reg_max 0x%x",
			reg,
			width,
			reg_max,
		)
	}
}

@(test)
unassigned_register_is_refused_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Codes 3 and 7 name nothing. Every accessor has to say so rather than fall
	// through to a real register, because an operand typo would otherwise
	// silently rewrite whichever register the default case happened to reach.
	// The "invalid register code" lines on stderr during this test are the
	// expected output, not a failure.
	reset_cpu(&m)
	m.regs.a = 0x11
	m.regs.b = 0x22
	m.regs.fp = 0x3344

	for reg in R_UNASSIGNED {
		val, reg_max, read_ok := hw.RegRead(&m, reg)
		testing.expectf(t, !read_ok, "RegRead(%d) should have failed", reg)
		testing.expectf(t, val == 0, "RegRead(%d): got 0x%04x, want 0 on failure", reg, val)
		testing.expectf(t, reg_max == 0, "RegRead(%d): got reg_max %d, want 0", reg, reg_max)

		testing.expectf(t, !hw.RegWrite(&m, reg, 0x99), "RegWrite(%d) should have failed", reg)

		width, width_ok := hw.RegWidth(reg)
		testing.expectf(t, !width_ok, "RegWidth(%d) should have failed", reg)
		testing.expectf(t, width == 0, "RegWidth(%d): got %d, want 0 on failure", reg, width)
	}

	// and nothing it might have aliased onto moved
	testing.expect_value(t, m.regs.a, u8(0x11))
	testing.expect_value(t, m.regs.b, u8(0x22))
	testing.expect_value(t, m.regs.fp, u16(0x3344))
}

@(test)
unassigned_operand_aborts_instruction_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// The same refusal seen from the outside: exec_inst reads its operands up
	// front and gives up on the whole instruction if either one is unnameable,
	// so a bad operand changes nothing rather than half-executing.
	for reg in R_UNASSIGNED {
		reset_cpu(&m)
		m.regs.a = 0x11
		m.regs.b = 0x22
		m.regs.sp = 0x0100

		hw.exec_inst(&m, ri(.MOVI, reg, 0x99)) // bad destination
		hw.exec_inst(&m, rr(.ADD, R_A, reg)) // bad source
		hw.exec_inst(&m, sr(.PUSH, reg)) // bad single-register operand

		testing.expect_value(t, m.regs.a, u8(0x11))
		testing.expect_value(t, m.regs.b, u8(0x22))
		testing.expect_value(t, m.regs.sp, u16(0x0100))
		testing.expect_value(t, m.memory[0x00FF], u8(0))
	}
}

/* ----------------------------------------------------------------- memory */

@(test)
memory_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Memory is the whole address space, flat, held by value in the Machine. A
	// 16-bit address register therefore names every byte of it and none of the
	// address arithmetic in ld, st, push or pop needs a bounds check.
	reset_cpu(&m)
	testing.expect_value(t, hw.MEM_SIZE, 65536)
	testing.expect_value(t, len(m.memory), hw.MEM_SIZE)
	testing.expect_value(t, int(max(u16)) + 1, hw.MEM_SIZE)

	// the stack starts at the top of it, so a push has somewhere to go
	testing.expect(t, int(hw.STACK_BASE) < hw.MEM_SIZE, "STACK_BASE must be inside memory")

	// power-on memory is zeroed
	nonzero := 0
	for b in m.memory {
		if b != 0 {
			nonzero += 1
		}
	}
	testing.expectf(t, nonzero == 0, "memory should power on zeroed, found %d non-zero bytes", nonzero)

	// the last byte is reachable through a 16-bit address register, which is
	// what halt relies on when it parks pc there
	m.regs.a = 0x5A
	m.regs.sp = u16(hw.MEM_SIZE - 1)
	hw.exec_inst(&m, rr(.ST, R_A, R_SP))
	testing.expect_value(t, m.memory[hw.MEM_SIZE - 1], u8(0x5A))

	m.regs.a = 0
	hw.exec_inst(&m, rr(.LD, R_A, R_SP))
	testing.expect_value(t, m.regs.a, u8(0x5A))
}

/* ------------------------------------------------------------- decode */

@(test)
decode_returns_opcode_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// exec_inst reports the opcode it decoded from bits 15-11, whatever else
	// the instruction does.
	reset_cpu(&m)
	testing.expect_value(t, hw.exec_inst(&m, rr(.ADD, R_A, R_B)), hw.Op.ADD)
	testing.expect_value(t, hw.exec_inst(&m, ri(.MOVI, R_A, 0x42)), hw.Op.MOVI)
	testing.expect_value(t, hw.exec_inst(&m, rel(.JMP, 0x20)), hw.Op.JMP)
	testing.expect_value(t, hw.exec_inst(&m, bare(.HALT)), hw.Op.HALT)
}

@(test)
machine_init_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// Power-on state. sp is the one register that does not start at zero: the
	// stack grows down, so starting it at 0 would make the very first push
	// underflow off the bottom of memory.
	reset_cpu(&m)
	testing.expect_value(t, m.regs.a, u8(0))
	testing.expect_value(t, m.regs.b, u8(0))
	testing.expect_value(t, m.regs.fp, u16(0))
	testing.expect_value(t, m.regs.pc, u16(0))
	testing.expect_value(t, m.regs.flags, u8(0))
	testing.expect_value(t, m.regs.sp, u16(hw.STACK_BASE))

	// so the first push lands just under the base instead of wrapping
	hw.exec_inst(&m, sr(.PUSH, R_A))
	testing.expect_value(t, m.regs.sp, u16(hw.STACK_BASE - 1))

	// init overwrites rather than merges: whatever a previous program left in
	// registers or memory is gone
	m.regs.a = 0x11
	m.regs.sp = 0x0010
	m.memory[0x1234] = 0x99
	reset_cpu(&m)
	testing.expect_value(t, m.regs.a, u8(0))
	testing.expect_value(t, m.regs.sp, u16(hw.STACK_BASE))
	testing.expect_value(t, m.memory[0x1234], u8(0))
}

@(test)
register_accessors_are_distinct_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// The accessors are four near-identical one-liners, which is exactly the
	// shape that gets copy-pasted wrong. If any two alias, a stack push quietly
	// rewrites the program counter and call/ret/push/pop fail in ways that look
	// like unrelated bugs.
	reset_cpu(&m)
	hw.PC(&m)^ = 0x0020
	hw.SP(&m)^ = 0x0100
	hw.FP(&m)^ = 0x0240
	hw.FLAGS(&m)^ = 0x05

	testing.expect_value(t, m.regs.pc, u16(0x0020))
	testing.expect_value(t, m.regs.sp, u16(0x0100))
	testing.expect_value(t, m.regs.fp, u16(0x0240))
	testing.expect_value(t, m.regs.flags, u8(0x05))
}

@(test)
fp_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	// fp is 16 bits wide so it can name any address in the 64K space, which is
	// the whole reason call reaches further than its 8-bit address field would
	// allow. A byte-wide fp would cap calls at the first 256 bytes.
	reset_cpu(&m)
	hw.FP(&m)^ = 0xBEEF
	testing.expect_value(t, m.regs.fp, u16(0xBEEF))

	// fp survives a reg-reg op on the general purpose registers
	m.regs.a = 1
	m.regs.b = 2
	hw.exec_inst(&m, rr(.ADD, R_A, R_B))
	testing.expect_value(t, m.regs.fp, u16(0xBEEF))

	// the call alias loads a full 16-bit address into fp a byte at a time
	reset_cpu(&m)
	hw.exec_inst(&m, ri(.MOVI, R_FP, 0xBE))
	hw.exec_inst(&m, ri(.SLLI, R_FP, 8))
	hw.exec_inst(&m, ri(.ADDI, R_FP, 0xEF))
	testing.expect_value(t, m.regs.fp, u16(0xBEEF))

	// and a and b are untouched by all of that
	testing.expect_value(t, m.regs.a, u8(0))
	testing.expect_value(t, m.regs.b, u8(0))
}

@(test)
inst_data_matches_op_enum_test :: proc(t: ^testing.T) {
	// INST_DATA and the Op enum are two hand-maintained lists of the same
	// instruction set, and this is the test that catches them drifting apart.
	// Aliases are the one legitimate difference: call and ret carry mnemonics
	// but no opcode, because the assembler expands them before the CPU ever
	// sees them.
	for inst in assembler.INST_DATA {
		if inst.type == .ALIAS {
			continue
		}
		name := strings.to_upper(inst.name, context.temp_allocator)
		_, ok := reflect.enum_from_name(hw.Op, name)
		testing.expectf(t, ok, "INST_DATA has %q with no matching Op member", inst.name)
	}

	// and every opcode the CPU can decode has a mnemonic the assembler accepts
	for op in hw.Op {
		name := strings.to_lower(reflect.enum_string(op), context.temp_allocator)
		_, ok := assembler.GET_INST_DATA(name)
		testing.expectf(t, ok, "Op.%s has no entry in INST_DATA", reflect.enum_string(op))
	}

	free_all(context.temp_allocator)
}

/* ------------------------------------------------------------ end to end */

/*
* Runs assembled code the way the emulator does, and stops on HALT.
*
* This is a copy of main.odin's `step`, which cannot be imported: the fetch
* lives in the emulator rather than in the hardware package, since exec_inst
* takes an instruction rather than reading one. The duplication is the point of
* the test -- it pins down the contract between the two halves, that pc is
* advanced past the instruction before it executes, which is what every jump
* offset in the assembler is measured against.
*
* Returns false if the program was still running when the budget ran out, which
* is how a jump that lands wrong shows up: as a loop that never leaves.
*/
run_code :: proc(m: ^hw.Machine, code: []u8, budget := 1000) -> bool {
	copy(m.memory[:], code)
	m.regs.pc = 0

	for _ in 0 ..< budget {
		at := m.regs.pc
		inst := u16(m.memory[at]) | u16(m.memory[at + 1]) << 8
		m.regs.pc = at + 2
		if hw.exec_inst(m, inst) == .HALT {
			return true
		}
	}
	return false
}

@(test)
relative_jump_loop_test :: proc(t: ^testing.T) {
	m: hw.Machine
	reset_cpu(&m)

	p: Pipeline
	defer pipe_destroy(&p)

	// Counts a up to b, which needs both a forward branch out of the loop and a
	// backward jump to the top of it.
	pipe_text(
		&p,
		"MOVI a 0\n" +
		"MOVI b 4\n" +
		"LOOP:\n" +
		"\tCMPR b a\n" +
		"\tJEQ DONE\n" +
		"\tADDI a 1\n" +
		"\tJMP LOOP\n" +
		"DONE:\n" +
		"\tHALT\n",
	)
	pipe_labels(&p)
	pipe_alias(&p)
	pipe_encode(&p)
	testing.expect(t, p.label_ok, "loop program should assemble")

	// A loop that never terminates is the symptom of an offset measured from
	// the wrong place, so the budget failing is itself the assertion.
	testing.expect(t, run_code(&m, p.code), "program did not halt within its budget")
	testing.expect_value(t, m.regs.a, u8(4))
	testing.expect_value(t, m.regs.b, u8(4))
}

@(test)
relative_jump_is_position_independent_test :: proc(t: ^testing.T) {
	// The property relative jumps buy: the same code runs correctly wherever it
	// is placed. Under absolute jumps this second copy would jump back into the
	// first one.
	m: hw.Machine
	reset_cpu(&m)

	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(
		&p,
		"MOVI a 0\n" +
		"MOVI b 3\n" +
		"LOOP:\n" +
		"\tCMPR b a\n" +
		"\tJEQ DONE\n" +
		"\tADDI a 1\n" +
		"\tJMP LOOP\n" +
		"DONE:\n" +
		"\tHALT\n",
	)
	pipe_labels(&p)
	pipe_alias(&p)
	pipe_encode(&p)

	// Same bytes, loaded at 0x0400 instead of 0x0000.
	OFFSET :: 0x0400
	copy(m.memory[OFFSET:], p.code)
	m.regs.pc = OFFSET

	halted := false
	for _ in 0 ..< 1000 {
		at := m.regs.pc
		inst := u16(m.memory[at]) | u16(m.memory[at + 1]) << 8
		m.regs.pc = at + 2
		if hw.exec_inst(&m, inst) == .HALT {
			halted = true
			break
		}
	}

	testing.expect(t, halted, "relocated program did not halt within its budget")
	testing.expect_value(t, m.regs.a, u8(3))
}
