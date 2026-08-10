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

clk: bool = false

read_inst :: proc(inst: u16) -> Op {
	opcode := Op(inst >> 11)
	reg1: ^u8 = RegFile((inst & 0x70) >> 8)
	reg2: ^u8 = RegFile(inst & 0x07)
	imm:   u8 = u8(inst & 0x0F)
	switch opcode {
	case .ADD:
		reg1^ = reg1^ + reg2^
		fmt.println("ADD %v %v!", reg1^, reg2^)
	case .ADDI:
		reg1^ = reg1^ + imm
		fmt.println("ADDI %v %v!", reg1^, imm)
	case .SUB:
		reg1^ = reg1^ - reg2^
		fmt.println("SUB %v %v!", reg1^, reg2^)
	case .SUBI:
		reg1^ = reg1^ - imm
		fmt.println("SUBI!")
	case .MUL:
		reg1^ = reg1^ * reg2^
		fmt.println("MUL!")
	case .DIV:
		reg1^ = reg1^ / reg2^
		fmt.println("DIV!")
	case .NOT:
		reg1^ ~= (reg1^)
		fmt.println("NOT!")
	case .OR:
		reg1^ = reg1^ | reg2^
		fmt.println("OR!")
	case .ORI:
		reg1^ = reg1^ | imm
		fmt.println("ORI!")
	case .XOR:
		reg1^ = reg1^ ~ reg2^
		fmt.println("XOR!")
	case .XORI:
		reg1^ = reg1^ ~ imm
		fmt.println("XORI!")
	case .AND:
		reg1^ = reg1^ & reg2^
		fmt.println("AND!")
	case .ANDI:
		reg1^ = reg1^ & imm
		fmt.println("ANDI!")
	case .SRL:
		// reg1^ = (reg1^ >> reg2^)
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
