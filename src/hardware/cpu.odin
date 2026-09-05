package hardware

import "core:log"

// status register flags
S :: enum {
	carry = 0b00000001,
	zero  = 0b00000010,
	i     = 0b00000100,
	dec   = 0b00001000,
	brk   = 0b00010000,
	of    = 0b01000000,
	n     = 0b10000000,
}

STACK_BASE :: 0x7FFF

Machine :: struct {
	regs:   Registers,
	memory: Memory,
}

machine_init :: proc(m: ^Machine) {
	m^ = Machine{}
	m.regs.sp = STACK_BASE
}

Op :: enum u16 {
	ADD,
	SUB,
	MUL,
	DIV,
	NOT,
	OR,
	XOR,
	AND,
	SRL,
	SLL,
	LD,
	ST,
	CMPR,
	MOVI,
	ADDI,
	XORI,
	SUBI,
	ANDI,
	ORI,
	SLLI,
	SRLI,
	JMP,
	JNE,
	JEQ,
	JGT,
	JGE,
	JLT,
	JLE,
	PUSH,
	POP,
	JMPF,
	HALT,
}

clk: bool = false

exec_inst :: proc(m: ^Machine, inst: u16) -> Op {
	pc := PC(m)
	sp := SP(m)
	fp := FP(m)
	flags := FLAGS(m)
	opcode := Op(inst >> 11)
	dst := (inst >> 8) & 0x07 // dst: bits 10-8
	src := inst & 0x07 // src: bits 2-0
	imm: u8 = u8(inst & 0xFF) // immediate: bits 7-0

	rel := inst & 0x07FF
	if rel & 0x0400 != 0 {
		rel |= 0xF800
	}

	v1, v2: u16 // dst and src, widened
	reg_max: int // largest value dst can hold, for the carry checks
	switch {
	case opcode <= .CMPR:
		ok1, ok2: bool
		v1, reg_max, ok1 = RegRead(m, dst)
		v2, _, ok2 = RegRead(m, src)
		if !ok1 || !ok2 {
			return opcode
		}
	case opcode <= .SRLI, opcode == .PUSH, opcode == .POP:
		ok1: bool
		v1, reg_max, ok1 = RegRead(m, dst)
		if !ok1 {
			return opcode
		}
	}

	switch opcode {
	case .ADD:
		RegWrite(m, dst, v1 + v2)
		if int(v1) + int(v2) > reg_max {
			flags^ |= u8(S.carry)
		}
	case .SUB:
		RegWrite(m, dst, v1 - v2)
		if int(v1) - int(v2) > reg_max {
			flags^ |= u8(S.carry)
		}
	case .MUL:
		RegWrite(m, dst, v1 * v2)
		if int(v1) * int(v2) > reg_max {
			flags^ |= u8(S.of)
		}
	case .DIV:
		RegWrite(m, dst, v1 / v2)
		if int(v1) / int(v2) > reg_max {
			flags^ |= u8(S.carry)
		}
	case .NOT:
		RegWrite(m, dst, ~v1)
	case .OR:
		RegWrite(m, dst, v1 | v2)
	case .XOR:
		RegWrite(m, dst, v1 ~ v2)
	case .AND:
		RegWrite(m, dst, v1 & v2)
	case .SRL:
		RegWrite(m, dst, v1 >> v2)
	case .SLL:
		RegWrite(m, dst, v1 << v2)
	case .LD:
		width, _ := RegWidth(dst)
		val: u16 = 0
		for i in 0 ..< width {
			val |= u16(m.memory[v2 + i]) << (8 * i)
		}
		RegWrite(m, dst, val)
	case .ST:
		width, _ := RegWidth(dst)
		for i in 0 ..< width {
			m.memory[v2 + i] = u8((v1 >> (8 * i)) & 0xFF)
		}
	case .CMPR:
		if v1 > v2 {
			flags^ |= u8(S.carry)
			flags^ &= ~(u8(S.zero))
			flags^ &= ~(u8(S.n))
		} else if v1 == v2 {
			flags^ |= u8(S.zero)
			flags^ &= ~(u8(S.carry))
			flags^ &= ~(u8(S.n))
		} else {
			flags^ |= u8(S.n)
			flags^ &= ~(u8(S.carry))
			flags^ &= ~(u8(S.zero))
		}
	case .MOVI:
		RegWrite(m, dst, u16(imm))
	case .ADDI:
		RegWrite(m, dst, v1 + u16(imm))
		if int(v1) + int(imm) > reg_max {
			flags^ |= u8(S.carry)
		}
	case .XORI:
		RegWrite(m, dst, v1 ~ u16(imm))
	case .SUBI:
		RegWrite(m, dst, v1 - u16(imm))
		if int(v1) - int(imm) > reg_max {
			flags^ |= u8(S.carry)
		}
	case .ANDI:
		RegWrite(m, dst, v1 & u16(imm))
	case .ORI:
		RegWrite(m, dst, v1 | u16(imm))
	case .SLLI:
		RegWrite(m, dst, v1 << u16(imm))
	case .SRLI:
		RegWrite(m, dst, v1 >> u16(imm))
	case .JMP:
		pc^ += rel
	case .JNE:
		if flags^ & u8(S.zero) == 0 {
			pc^ += rel
		}
	case .JEQ:
		if flags^ & u8(S.zero) != 0 {
			pc^ += rel
		}
	case .JGT:
		if flags^ & u8(S.carry) != 0 {
			pc^ += rel
		}
	case .JGE:
		if flags^ & (u8(S.carry) | u8(S.zero)) != 0 {
			pc^ += rel
		}
	case .JLT:
		if flags^ & u8(S.n) != 0 {
			pc^ += rel
		}
	case .JLE:
		if flags^ & (u8(S.n) | u8(S.zero)) != 0 {
			pc^ += rel
		}
	case .PUSH:
		width, _ := RegWidth(dst)
		for i in 0 ..< width {
			sp^ -= 1
			m.memory[sp^] = u8((v1 >> (8 * (width - 1 - i))) & 0xFF)
		}
	case .POP:
		width, _ := RegWidth(dst)
		val: u16 = 0
		for i in 0 ..< width {
			val |= u16(m.memory[sp^]) << (8 * i)
			sp^ += 1
		}
		RegWrite(m, dst, val)
	case .JMPF:
		pc^ = fp^
	case .HALT:
		pc^ = len(m.memory) - 1
	case:
		log.warnf("unknown opcode %v", opcode)
	}
	return opcode
}
