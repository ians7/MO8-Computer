package hardware

import "core:fmt"

Registers :: struct {
	/* Main Registers */
	a:     u8, // accumulator
	b:     u8, // general use register

	/* Index Registers */
	x:     u8, // x index
	y:     u8, // y index
	sp:    u16, // stack pointer

	/* Program Counter */
	pc:    u16,

	/* Status Register */
	flags: u8,
}

cpu := Registers{0, 0, 0, 0, 0, 0, 0}

RegFile :: proc(reg_idx: u16) -> ^u8 {
	switch(reg_idx) {
	case 0:
		return &cpu.a
	case 1:
		return &cpu.b
	case 2:
		return &cpu.x
	case 3:
		return &cpu.y
	case 6:
		return &cpu.flags
	case:
		fmt.println("Invalid register code")
	}
	return nil
}
