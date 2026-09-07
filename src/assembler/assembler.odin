package assembler

import "../debug"
import hw "../hardware"
import "core:encoding/endian"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"


INST_TYPES :: enum {
	ALIAS,
	IMM,
	ADDR,
	REGREG,
	REG,
	JMP_LABEL,
	NONE,
}

Inst :: struct {
	name:       string,
	type:       INST_TYPES,
	n_operands: int,
	width:      u16,
}

INST_DATA :: [?]Inst {
	{"add", .REGREG, 2, 1},
	{"sub", .REGREG, 2, 1},
	{"mul", .REGREG, 2, 1},
	{"div", .REGREG, 2, 1},
	{"not", .REGREG, 2, 1},
	{"or", .REGREG, 2, 1},
	{"xor", .REGREG, 2, 1},
	{"and", .REGREG, 2, 1},
	{"srl", .REGREG, 2, 1},
	{"sll", .REGREG, 2, 1},
	{"ld", .REGREG, 2, 1},
	{"st", .REGREG, 2, 1},
	{"cmpr", .REGREG, 2, 1},
	{"movi", .IMM, 2, 1},
	{"addi", .IMM, 2, 1},
	{"xori", .IMM, 2, 1},
	{"subi", .IMM, 2, 1},
	{"andi", .IMM, 2, 1},
	{"ori", .IMM, 2, 1},
	{"slli", .IMM, 2, 1},
	{"srli", .IMM, 2, 1},
	{"jmp", .JMP_LABEL, 1, 1},
	{"jne", .JMP_LABEL, 1, 1},
	{"jeq", .JMP_LABEL, 1, 1},
	{"jgt", .JMP_LABEL, 1, 1},
	{"jge", .JMP_LABEL, 1, 1},
	{"jlt", .JMP_LABEL, 1, 1},
	{"jle", .JMP_LABEL, 1, 1},
	{"push", .REG, 1, 1},
	{"pop", .REG, 1, 1},
	{"call", .ALIAS, 1, CALL_WIDTH},
	{"ret", .ALIAS, 0, RET_WIDTH},
	{"halt", .NONE, 0, 1},
	{"jmpf", .NONE, 0, 1},
}

Reg :: struct {
	name: string,
	code: u16,
}

REGISTERS :: [?]Reg {
	{"a", 0},
	{"b", 1},
	{"fp", 2},
	{"x", 3},
	{"sp", 4},
	{"pc", 5},
	{"flags", 6},
}

Line :: struct {
	toks:   []string,
	ntoks:  int,
	lineno: int,
}

INST_SZ :: 0x2 // bytes
NEG_INT_MASK: int = 0xFF00

REL_BITS :: 11
REL_MASK :: (1 << REL_BITS) - 1 // 0x07FF
REL_MIN :: -(1 << (REL_BITS - 1)) // -1024
REL_MAX :: (1 << (REL_BITS - 1)) - 1 // 1023

CALL_WIDTH :: 8
RET_WIDTH :: 2
CALL_SKIP :: (CALL_WIDTH - 2) * INST_SZ

GET_INST_DATA :: proc(inst_name: string) -> (Inst, bool) {

	for i_d in INST_DATA {
		if i_d.name == inst_name {
			return i_d, true
		}
	}
	return {}, false
}

lower_ascii_in_place :: proc(s: string) {
	bytes := transmute([]byte)s
	quote := false
	for &b in bytes {
		if b == '"' {
			quote = !quote
		}
		if !quote && 'A' <= b && b <= 'Z' {
			b += 32
		}
	}
}

gen_line :: proc(src: string, lineno: int, allocator := context.allocator) -> (Line, bool) {
	toks := strings.fields(src, allocator)
	if len(toks) == 0 {
		return {}, false
	}

	data, ok := GET_INST_DATA(toks[0])
	if !ok || len(toks) - 1 != data.n_operands {
		delete(toks, allocator)
		return {}, false
	}

	return Line{toks, len(toks), lineno}, true
}

gen_lines :: proc(
	out: ^[dynamic]Line,
	src: string,
	lineno: int,
	allocator := context.allocator,
) -> bool {
	it := src
	for text in strings.split_lines_iterator(&it) {
		if len(strings.trim_space(text)) == 0 {
			continue
		}

		line, ok := gen_line(text, lineno, allocator)
		if !ok {
			return false
		}
		append(out, line)
	}
	return true
}

REG_SRC :: #force_inline proc(reg_value: string) -> (u16, bool) {
	ok := false
	ret: u16 = 0
	for reg in REGISTERS {
		if (reg.name == reg_value) {
			ok = true
			ret = reg.code
			break
		}
	}

	return ret, ok
}

REG_DST :: #force_inline proc(reg_value: string) -> (u16, bool) {
	ok := false
	ret: u16 = 0
	for reg in REGISTERS {
		if (reg.name == reg_value) {
			ok = true
			ret = reg.code
			break
		}
	}

	return (ret << 8), ok
}

IMM :: #force_inline proc(imm_value: string) -> (u16, bool) {
	imm, ok := strconv.parse_int(imm_value)
	if !ok || imm > int(max(u8)) {
		return 0, false
	}
	if imm < 0 {
		imm &= ~(NEG_INT_MASK)
	}
	return u16(imm), true
}

REL :: #force_inline proc(rel_value: string) -> (u16, bool) {
	off, ok := strconv.parse_int(rel_value)
	if !ok || off < REL_MIN || off > REL_MAX {
		return 0, false
	}
	return u16(off & REL_MASK), true
}

assemble_inst :: proc(asm_inst: string) {

}

instruction_pass :: proc(asm_file: []Line) -> []u8 {
	out_buf: [dynamic]u8

	for line in asm_file {
		data, ok := GET_INST_DATA(line.toks[0])
		if !ok {
			log.warnf("Something has gone seriously wrong...:", line.toks)
		}

		inst_upper := strings.to_upper(line.toks[0], context.temp_allocator)
		val, enum_ok := reflect.enum_from_name(hw.Op, inst_upper)
		delete(inst_upper, context.temp_allocator)
		if !enum_ok {
			log.warnf("Probably an invalid instruction:", line.toks)
		}
		inst := u16(val) << 11

		#partial switch (data.type) {
		case (.IMM):
			dst, dok := REG_DST(line.toks[1])
			imm, iok := IMM(line.toks[2])
			if !dok || !iok {
				log.warnf(
					"%s is an invalid dest register or %s is an invalid immediate",
					line.toks[1],
					line.toks[2],
				)
			}
			inst |= dst | imm
			buf: [2]u8
			endian.put_u16(buf[:], .Little, inst)
			append(&out_buf, ..buf[:])

		case (.ADDR):
			addr, aok := IMM(line.toks[1])
			if !aok {
				log.warnf(
					"%s is an invalid is an invalid address",
					line.toks[1],
					line.toks[2],
				)
			}
			inst |= addr
			buf: [2]u8
			endian.put_u16(buf[:], .Little, inst)
			append(&out_buf, ..buf[:])

		case (.REG):
			reg, rok := REG_DST(line.toks[1])
			if !rok {
				log.warnf(
					"%s is an invalid register ",
					line.toks[1],
				)
			}
			inst |= reg
			buf: [2]u8
			endian.put_u16(buf[:], .Little, inst)
			append(&out_buf, ..buf[:])

		case (.REGREG):
			dst, dok := REG_DST(line.toks[1])
			src, sok := REG_SRC(line.toks[2])
			if !dok || !sok {
				log.warnf(
					"%s is an invalid dest register or %s is an invalid register",
					line.toks[1],
					line.toks[2],
				)
			}
			inst |= dst | src
			buf: [2]u8
			endian.put_u16(buf[:], .Little, inst)
			append(&out_buf, ..buf[:])

		case (.JMP_LABEL):
			rel, rok := REL(line.toks[1])
			if !rok {
				log.warnf(
					"%s is not a valid jump offset",
					line.toks[1],
				)
			}
			inst |= rel
			buf: [2]u8
			endian.put_u16(buf[:], .Little, inst)
			append(&out_buf, ..buf[:])

		case (.NONE):
			buf: [2]u8
			endian.put_u16(buf[:], .Little, inst)
			append(&out_buf, ..buf[:])

		case:
			log.warnf("Something strange has gone wrong here...:", line.toks)

		}
	}

	return out_buf[:]
}

comments_pass :: proc(asm_file: string, allocator := context.allocator) -> [dynamic]Line {
	asm_lines: [dynamic]Line
	n_errs := 0
	it := asm_file
	lineno := 0

	for line in strings.split_lines_iterator(&it) {
		lineno += 1
		l := strings.truncate_to_byte(line, ';')

		line_tok := strings.fields(l, allocator)
		n_toks := len(line_tok)

		if (n_toks == 0) {
			delete(line_tok, allocator)
			continue
		}

		for tok in line_tok {
			lower_ascii_in_place(tok)
		}

		s_line: Line = {line_tok, n_toks, lineno}
		append(&asm_lines, s_line)
	}

	return asm_lines
}

label_map_destroy :: proc(label_map: ^map[string]string, allocator := context.allocator) {
	for _, addr in label_map {
		delete(addr, allocator)
	}
	delete(label_map^)
}

LabelFixup :: struct {
	line: Line,
	addr: u16, // address of the referring instruction
	rel:  bool, // a jump wants an offset; call wants the address itself
}

jump_offset :: proc(
	target, from: u16,
	allocator := context.allocator,
) -> (
	text: string,
	ok: bool,
) {
	off := int(target) - int(from + INST_SZ)
	if off < REL_MIN || off > REL_MAX {
		return "", false
	}
	return fmt.aprintf("%d", off, allocator = allocator), true
}

label_pass :: proc(
	asm_file: [dynamic]Line,
	allocator := context.allocator,
) -> (
	[dynamic]Line,
	map[string]string,
	[dynamic]string,
	bool,
) {
	it := asm_file
	n_errs := 0
	addr: u16 = 0
	label_map: map[string]string = make(map[string]string, 10, allocator)

	label_addr: map[string]u16 = make(map[string]u16, 10, allocator)

	defer delete(label_addr)
	
	offset_text: [dynamic]string
	asm_file_lines := asm_file
	label_def_not_found: [dynamic]LabelFixup
	defer delete(label_def_not_found)

	for line in asm_file {
		line_len := line.ntoks
		if (line.toks[0][len(line.toks[0]) - 1] == ':') {
			l := strings.truncate_to_byte(line.toks[0], ':')
			label_map[l] = fmt.aprintf("0x%04x", addr, allocator = allocator)
			label_addr[l] = addr
			continue
		}

		inst_data, ok := GET_INST_DATA(line.toks[0])
		if !ok {
			log.warnf("unknown instruction %q on line %d", line.toks[0], line.lineno)
			n_errs += 1
		}

		is_jump := inst_data.type == .JMP_LABEL
		if is_jump || inst_data.name == "call" {
			if line_len < 2 {
				log.warnf("%q on line %d is missing a label operand", line.toks[0], line.lineno)
				n_errs += 1
			} else if target, lok := label_addr[line.toks[1]]; lok {
				if is_jump {
					off, rok := jump_offset(target, addr, allocator)
					if !rok {
						log.warnf(
							"label %q on line %d is out of range of a jump",
							line.toks[1],
							line.lineno,
						)
						n_errs += 1
					} else {
						append(&offset_text, off)
						line.toks[1] = off
					}
				} else {
					line.toks[1] = label_map[line.toks[1]]
				}
			} else {
				append(&label_def_not_found, LabelFixup{line, addr, is_jump})
			}
		}

		addr += inst_data.width * INST_SZ
	}

	for fix in label_def_not_found {
		target, ok := label_addr[fix.line.toks[1]]
		if !ok {
			log.warnf("undefined label %q on line %d", fix.line.toks[1], fix.line.lineno)
			n_errs += 1
			continue
		}

		if !fix.rel {
			fix.line.toks[1] = label_map[fix.line.toks[1]]
			continue
		}

		off, rok := jump_offset(target, fix.addr, allocator)
		if !rok {
			log.warnf(
				"label %q on line %d is out of range of a jump",
				fix.line.toks[1],
				fix.line.lineno,
			)
			n_errs += 1
			continue
		}
		append(&offset_text, off)
		fix.line.toks[1] = off
	}

	debug.logf("label pass 1 completed with %d errors", n_errs)
	return asm_file_lines, label_map, offset_text, (n_errs > 0 ? false : true)
}

offset_text_destroy :: proc(offset_text: ^[dynamic]string, allocator := context.allocator) {
	for text in offset_text {
		delete(text, allocator)
	}
	delete(offset_text^)
}

alias_pass :: proc(
	asm_lines: [dynamic]Line,
	allocator := context.allocator,
) -> (
	[dynamic]Line,
	[dynamic]string,
	bool,
) {
	n_errs := 0

	gen_text: [dynamic]string
	ret_lines: [dynamic]Line

	for line in asm_lines {
		inst_data, ok := GET_INST_DATA(line.toks[0])
		if !ok {
			delete(line.toks)
			continue
		}

		if inst_data.type == .ALIAS {
			switch (line.toks[0]) {
			case ("call"):
				// operand must already be a resolved 16-bit address, since the
				// expansion loads it into fp one byte at a time
				target := line.toks[1]
				if len(target) != 6 || target[:2] != "0x" {
					log.warnf(
						"call operand %q on line %d is not a resolved 16-bit address",
						target,
						line.lineno,
					)
					n_errs += 1
					delete(line.toks, allocator)
					continue
				}

				expansion := fmt.aprintf(
					"movi fp 0\n" +
					"add fp pc\n" +
					"addi fp %d\n" +
					"push fp\n" +
					"movi fp 0x%s\n" +
					"slli fp 8\n" +
					"addi fp 0x%s\n" +
					"jmpf\n",
					CALL_SKIP,
					target[2:4],
					target[4:6],
					allocator = allocator,
				)
				append(&gen_text, expansion)

				if !gen_lines(&ret_lines, expansion, line.lineno, allocator) {
					log.warnf("could not expand call on line %d", line.lineno)
					n_errs += 1
				}

				delete(line.toks, allocator)

			case ("ret"):
				expansion := fmt.aprintf(
					"pop fp\n" +
					"jmpf\n",
					allocator = allocator,
				)
				append(&gen_text, expansion)

				if !gen_lines(&ret_lines, expansion, line.lineno, allocator) {
					log.warnf("could not expand ret on line %d", line.lineno)
					n_errs += 1
				}

				delete(line.toks, allocator)

			}
		} else {
			append(&ret_lines, line)
		}

	}

	debug.logf("alias pass completed with %d errors", n_errs)

	return ret_lines, gen_text, (n_errs > 0 ? false : true)
}

alias_text_destroy :: proc(gen_text: ^[dynamic]string, allocator := context.allocator) {
	for text in gen_text {
		delete(text, allocator)
	}
	delete(gen_text^)
}

main :: proc() {
	track: debug.Tracker
	context.allocator = debug.track_start(&track)
	defer debug.track_report(&track)

	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	Options :: struct {
		file:   ^os.File `args:"pos=0,required,file=r" usage:"Input File."`,
		output: string `args:"pos=1" usage:"Output File."`,
	}

	opt: Options
	style: flags.Parsing_Style = .Odin

	flags.parse_or_exit(&opt, os.args, style)

	asm_file, in_err := os.read_entire_file(opt.file, context.allocator)
	defer delete(asm_file, context.allocator)

	when debug.ENABLED {
		debug.log("source file:")
		fmt.eprintln(string(asm_file))
	}

	fmt.println()

	asm_tokenized := comments_pass(string(asm_file), context.allocator)

	asm_labels_resolved, label_map, offset_text, lok := label_pass(asm_tokenized, context.allocator)

	if !lok {
		fmt.println("Failed label pass")
		os.exit(1)
	}
	debug_print_lines(asm_labels_resolved[:])

	asm_expanded, gen_text, alok := alias_pass(asm_tokenized, context.allocator)
	debug_print_lines(asm_expanded[:])

	defer {
		for line in asm_expanded {
			delete(line.toks)
		}
		delete(asm_expanded)
		delete(asm_tokenized)
		alias_text_destroy(&gen_text, context.allocator)
		offset_text_destroy(&offset_text, context.allocator)
		for lab in label_map {
			delete(label_map[lab])
		}
		delete(label_map)
	}

	buf := instruction_pass(asm_expanded[:])
	defer delete(buf)

	if in_err != os.ERROR_NONE {
		fmt.eprintfln("error: open failed: %v", in_err)
		os.exit(1)
	}

	out_fname := opt.output != "" ? opt.output : "o.out"
	if w_err := os.write_entire_file(out_fname, buf[:]); w_err != os.ERROR_NONE {
		fmt.eprintln("write failed:", w_err)
		os.exit(1)
	}
}
