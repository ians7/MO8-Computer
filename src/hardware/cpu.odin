package hardware

import "core:fmt"

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

Op :: enum u16 {
	ADD, ADDI, SUB, SUBI,
	MUL, DIV, NOT, OR,
	ORI, XOR, XORI, AND,
	ANDI, SRL, SRA, LD,
	ST, MOV, CMP, CMPR,
	JR, JNE, JEQ, JGT,
	JGE, JLT, JLE, PUSH,
	POP, CALL, RET, HALT,
}

registers :: struct {
	/* Main Registers */
	a:     u8, // accumulator

	/* Index Registers */
	x:     u8, // x index
	y:     u8, // y index
	sp:    u16, // stack pointer

	/* Program Counter */
	pc:    u16,

	/* Status Register */
	flags: u8,
}

read_inst :: proc(inst: u16) -> Op {
	opcode := Op(inst >> 11)
	switch opcode {
	case .ADD:
		fmt.println("ADD!")
	case .ADDI:
		fmt.println("ADDI!")
	case .SUB:
		fmt.println("SUB!")
	case .SUBI:
		fmt.println("SUBI!")
	case .MUL:
		fmt.println("MUL!")
	case .DIV:
		fmt.println("DIV!")
	case .NOT:
		fmt.println("NOT!")
	case .OR:
		fmt.println("OR!")
	case .ORI:
		fmt.println("ORI!")
	case .XOR:
		fmt.println("XOR!")
	case .XORI:
		fmt.println("XORI!")
	case .AND:
		fmt.println("AND!")
	case .ANDI:
		fmt.println("ANDI!")
	case .SRL:
		fmt.println("SRL!")
	case .SRA:
		fmt.println("SRA!")
	case .LD:
		fmt.println("LD!")
	case .ST:
		fmt.println("ST!")
	case .MOV:
		fmt.println("MOV!")
	case .CMP:
		fmt.println("CMP!")
	case .CMPR:
		fmt.println("CMPR!")
	case .JR:
		fmt.println("JR!")
	case .JNE:
		fmt.println("JNE!")
	case .JEQ:
		fmt.println("JEQ!")
	case .JGT:
		fmt.println("JGT!")
	case .JGE:
		fmt.println("JGE!")
	case .JLT:
		fmt.println("JLT!")
	case .JLE:
		fmt.println("JLE!")
	case .PUSH:
		fmt.println("PUSH!")
	case .POP:
		fmt.println("POP!")
	case .CALL:
		fmt.println("CALL!")
	case .RET:
		fmt.println("RET!")
	case .HALT:
		fmt.println("HALT!")
	case:
		fmt.println("Something ain't right...")
	}
	return opcode
}
