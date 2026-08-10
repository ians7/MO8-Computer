#+feature dynamic-literals
package assembler

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"


opcode_map: map[string]u16
register_map: map[string]u16

REG_SRC :: #force_inline proc(reg_value: string) -> u16 {
	rv, ok := register_map[reg_value]
	if !ok {
		fmt.printf("Error parsing reg_value: %s\n", reg_value)
		os.exit(1)
	}

	return u16(rv)
}

REG_DST :: #force_inline proc(reg_value: string) -> u16 {
	rv, ok := register_map[reg_value]
	if !ok {
		fmt.printf("Error parsing reg_value: %s\n", reg_value)
		os.exit(1)
	}
	return u16(rv) << 8
}

IMM :: #force_inline proc(imm_value: string) -> u16 {
	imm, ok := strconv.parse_uint(imm_value)
	if !ok || imm > uint(max(u8)) {
		fmt.printf("Error parsing immediate value: %s\n", imm_value)
		os.exit(1)
	}
	return u16(imm) << 8
}

assemble_inst :: proc(asm_inst: string) -> u16 {
	inst_tok := strings.split(asm_inst, " ", context.allocator)
	defer delete(inst_tok)

	inst := opcode_map[inst_tok[0]]

	if inst >= 0x0 && inst <= 0x6800 {
		// reg-reg operation
		inst |= REG_DST(inst_tok[1]) | REG_SRC(inst_tok[2])
	} else if inst > 0x6800 && inst <= 0x9800 {
		// imm operation
		inst |= REG_DST(inst_tok[1]) | IMM(inst_tok[2])
	} else if inst > 0x9800 && inst <= 0xF800 {
		// none operation
		return inst
	} else {
		fmt.printfln("Bad instruction: %s", asm_inst)
	}

	return inst
}

typesetter :: proc(
	data: rawptr,
	data_type: typeid,
	unparsed_val: string,
	args_tag: string,
) -> (
	error: string,
	handled: bool,
	alloc_error: runtime.Allocator_Error,
) {

	return
}

main :: proc() {
	Options :: struct {
		file:   ^os.File `args:"pos=0,required,file=r" usage:"Input File."`,
		output: ^os.File `args:"pos=1,file=cw" usage:"Output File."`,
	}

	opt: Options
	style: flags.Parsing_Style = .Odin

	// flags.register_flag_checker(typesetter)
	// flags.register_flag_checker(flag_checker)
	flags.parse_or_exit(&opt, os.args, style)

	init_maps()

	infile, err := os.read_entire_file(os.args[1], context.allocator)
	defer delete(infile, context.allocator)


	it := string(infile)
	inst: u16 = 0
	for line in strings.split_lines_iterator(&it) {
		inst = assemble_inst(strings.to_lower(line))
		fmt.printfln("%s ==> 0x%4x", line, inst)
	}
}

init_maps :: proc() {
	opcode_map = {
		"add"  = 0x0000,
		"sub"  = 0x0800,
		"mul"  = 0x1000,
		"div"  = 0x1800,
		"not"  = 0x2000,
		"or"   = 0x2800,
		"xor"  = 0x3000,
		"and"  = 0x3800,
		"srl"  = 0x4000,
		"sra"  = 0x4800,
		"ld"   = 0x5000,
		"st"   = 0x5800,
		"mov"  = 0x6000,
		"cmpr" = 0x6800,
		"addi" = 0x7000,
		"xori" = 0x7800,
		"subi" = 0x8000,
		"andi" = 0x8800,
		"cmp"  = 0x9000,
		"ori"  = 0x9800,
		"jr"   = 0xA000,
		"jne"  = 0xA800,
		"jeq"  = 0xB000,
		"jgt"  = 0xB800,
		"jge"  = 0xC000,
		"jlt"  = 0xC800,
		"jle"  = 0xD000,
		"push" = 0xD800,
		"pop"  = 0xE000,
		"call" = 0xE800,
		"ret"  = 0xF000,
		"halt" = 0xF800,
	}
	register_map = {
		"a"     = 0x00,
		"r0"    = 0x00,
		"b"     = 0x01,
		"r1"    = 0x01,
		"x"     = 0x02,
		"r2"    = 0x02,
		"y"     = 0x03,
		"r3"    = 0x03,
		"sp"    = 0x04,
		"r4"    = 0x04,
		"pc"    = 0x05,
		"r5"    = 0x05,
		"flags" = 0x06,
		"r6"    = 0x06,
	}
}
