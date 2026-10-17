package assembler

import "../debug"
import hw "../hardware"
import "core:encoding/endian"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
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

SECTION_TYPE :: enum {
	CODE,
	DATA,
	NONE,
}

DATA_TYPE :: enum {
	BYTE,
	WORD,
	ASCII,
	STRING,
	SPRITE,
}

Data :: struct {
	name: string,
	type: DATA_TYPE,
}

DATA_DIRECTIVES :: [?]Data {
	{".byte", .BYTE},
	{".word", .WORD},
	{".ascii", .ASCII},
	{".string", .STRING},
	{".sprite", .SPRITE},
}

GET_DATA_TYPE :: proc(directive: string) -> (DATA_TYPE, bool) {
	for d in DATA_DIRECTIVES {
		if d.name == directive {
			return d.type, true
		}
	}
	return {}, false
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

REGISTERS :: [?]Reg{{"a", 0}, {"b", 1}, {"fp", 2}, {"x", 3}, {"sp", 4}, {"pc", 5}, {"flags", 6}}

Line :: struct {
	toks:    []string,
	ntoks:   int,
	lineno:  int,
	section: SECTION_TYPE,
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

// The data half runs from STACK_BASE to the top of the address space, and the
// data block is packed against the top of it, so DATA_END is one past the last
// byte the block can occupy and hw.STACK_BASE is the floor it must not cross.
DATA_END :: hw.MEM_SIZE
DATA_FLOOR :: hw.STACK_BASE

is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'
}

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

IS_STRING_TOK :: #force_inline proc(tok: string) -> bool {
	return len(tok) >= 2 && tok[0] == '"'
}

// Splits one source line into tokens. This is strings.fields plus two rules it
// does not have: a quoted run is one token however much whitespace is inside
// it, and a ';' stops the line unless it is inside quotes. The tokens are
// substrings of src, so only the returned slice is allocated, and a string
// token keeps its quotes so later passes can still tell it apart from a name.
tokenize :: proc(src: string, allocator := context.allocator) -> ([]string, bool) {
	toks := make([dynamic]string, 0, 4, allocator)

	i := 0
	for i < len(src) {
		if is_space(src[i]) {
			i += 1
			continue
		}
		if src[i] == ';' {
			break // comment, runs to the end of the line
		}

		start := i

		if src[i] == '"' {
			i += 1
			closed := false
			for i < len(src) {
				// a backslash escapes whatever follows it, so an escaped quote
				// does not end the literal
				if src[i] == '\\' && i + 1 < len(src) {
					i += 2
					continue
				}
				if src[i] == '"' {
					i += 1
					closed = true
					break
				}
				i += 1
			}
			if !closed {
				delete(toks)
				return nil, false
			}
			append(&toks, src[start:i])
			continue
		}

		for i < len(src) && !is_space(src[i]) && src[i] != ';' && src[i] != '"' {
			i += 1
		}
		append(&toks, src[start:i])
	}

	return toks[:], true
}

gen_line :: proc(
	src: string,
	lineno: int,
	section: SECTION_TYPE = .NONE,
	allocator := context.allocator,
) -> (
	Line,
	bool,
) {
	toks := strings.fields(src, allocator)
	if len(toks) == 0 {
		return {}, false
	}

	data, ok := GET_INST_DATA(toks[0])
	if !ok || len(toks) - 1 != data.n_operands {
		delete(toks, allocator)
		return {}, false
	}

	return Line{toks, len(toks), lineno, section}, true
}

gen_lines :: proc(
	out: ^[dynamic]Line,
	src: string,
	lineno: int,
	section: SECTION_TYPE = .NONE,
	allocator := context.allocator,
) -> bool {
	it := src
	for text in strings.split_lines_iterator(&it) {
		if len(strings.trim_space(text)) == 0 {
			continue
		}

		line, ok := gen_line(text, lineno, section, allocator)
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

section_pass :: proc(
	asm_file: [dynamic]Line,
	allocator := context.allocator,
) -> (
	[dynamic]Line,
	[dynamic]Line,
	bool,
) {
	n_errs := 0
	section := SECTION_TYPE.NONE
	open_lineno := 0

	code_section: [dynamic]Line = make([dynamic]Line, 0, len(asm_file), allocator)
	data_section: [dynamic]Line = make([dynamic]Line, 0, len(asm_file), allocator)

	for &line in asm_file {
		if line.toks[0] == ".section" {
			if line.ntoks < 2 {
				log.warnf(".section on line %d is missing a section name", line.lineno)
				n_errs += 1
				continue
			}
			if section != .NONE {
				log.warnf(
					".section %q on line %d opens inside the %v section opened on line %d",
					line.toks[1],
					line.lineno,
					section,
					open_lineno,
				)
				n_errs += 1
			}
			switch (line.toks[1]) {
			case "data":
				section = SECTION_TYPE.DATA
			case "code":
				section = SECTION_TYPE.CODE
			case:
				log.warnf(
					"unknown section %q on line %d, expected \"code\" or \"data\"",
					line.toks[1],
					line.lineno,
				)
				n_errs += 1
			}
			open_lineno = line.lineno
			continue
		} else if line.toks[0] == ".endsection" {
			if section == .NONE {
				log.warnf(".endsection on line %d closes nothing", line.lineno)
				n_errs += 1
			}
			section = SECTION_TYPE.NONE
			continue
		}

		// stamp the section onto the line itself, so every later pass and every
		// debug dump can say which section a line came from
		line.section = section

		switch (section) {
		case .CODE:
			append(&code_section, line)
		case .DATA:
			append(&data_section, line)
		case .NONE:
			log.warnf("%q on line %d is outside of any section", line.toks[0], line.lineno)
			n_errs += 1
		}
	}

	if section != .NONE {
		log.warnf("%v section opened on line %d is never closed", section, open_lineno)
		n_errs += 1
	}

	debug.logf(
		"section pass completed with %d errors: %d code lines, %d data lines",
		n_errs,
		len(code_section),
		len(data_section),
	)
	debug_print_sections(data_section[:], code_section[:])

	return data_section, code_section, (n_errs > 0 ? false : true)
}

// Returns the nth argument that is not a flag. Under the .Odin parsing style
// every flag starts with a '-', so the bare arguments are the positionals in
// order, which is how the flags package binds pos=0. It opens the input file
// and drops the path, so this is the only way back to it.
positional_arg :: proc(args: []string, n: int) -> string {
	i := 0
	for arg in args {
		if len(arg) > 0 && arg[0] == '-' {
			continue
		}
		if i == n {
			return arg
		}
		i += 1
	}
	return ""
}

// Resolves a path written in the source against the directory that source file
// lives in, so an assembly file refers to its assets the way they sit on disk
// rather than relative to wherever the assembler happens to be run from. The
// result is always freshly allocated.
resolve_path :: proc(dir, path: string, allocator := context.allocator) -> string {
	if dir == "" || filepath.is_abs(path) {
		return strings.clone(path, allocator)
	}
	joined, _ := filepath.join({dir, path}, allocator)
	return joined
}

// Expands the escapes in a quoted literal and appends the bytes to out. lit
// still carries its quotes, which are not part of the data.
unescape_string :: proc(lit: string, out: ^[dynamic]u8) -> bool {
	if len(lit) < 2 || lit[0] != '"' || lit[len(lit) - 1] != '"' {
		return false
	}

	body := lit[1:len(lit) - 1]
	i := 0
	for i < len(body) {
		if body[i] != '\\' {
			append(out, body[i])
			i += 1
			continue
		}
		if i + 1 >= len(body) {
			return false
		}
		switch body[i + 1] {
		case 'n':
			append(out, '\n')
		case 't':
			append(out, '\t')
		case 'r':
			append(out, '\r')
		case '0':
			append(out, 0)
		case '\\':
			append(out, '\\')
		case '"':
			append(out, '"')
		case:
			return false
		}
		i += 2
	}

	return true
}

// Lays out the data section and returns its bytes alongside a map of every
// data name to the address that name's bytes begin at.
//
// Every directive is `.<kind> <name> <value>`, so each one contributes a name
// the code section can refer to. The block is packed against the top of the
// address space, which means no address is known until the whole block has
// been sized: names are collected against their offset within the block and
// only turned into addresses once the last directive has been laid out.
data_pass :: proc(
	asm_file: []Line,
	src_dir := "",
	allocator := context.allocator,
) -> (
	[dynamic]u8,
	map[string]u16,
	bool,
) {
	n_errs := 0

	data := make([dynamic]u8, 0, 64, allocator)
	data_map := make(map[string]u16, 10, allocator)
	name_offsets := make(map[string]int, 10, allocator)
	defer delete(name_offsets)

	for line in asm_file {
		// every directive has the same shape, so the operand count and the
		// name are checked once rather than in each case
		if line.ntoks != 3 {
			log.warnf(
				"%q on line %d takes a name and a value, got %d operands",
				line.toks[0],
				line.lineno,
				line.ntoks - 1,
			)
			n_errs += 1
			continue
		}

		name := line.toks[1]
		if _, dup := name_offsets[name]; dup {
			log.warnf("data name %q on line %d is already defined", name, line.lineno)
			n_errs += 1
			continue
		}

		type, tok := GET_DATA_TYPE(line.toks[0])
		if !tok {
			log.warnf("unknown data directive %q on line %d", line.toks[0], line.lineno)
			n_errs += 1
			continue
		}

		offset := len(data)
		value := line.toks[2]
		ok := true

		switch (type) {
		case .BYTE:
			imm, iok := IMM(value)
			if !iok {
				log.warnf("%q on line %d is not a valid byte", value, line.lineno)
				ok = false
			} else {
				append(&data, u8(imm))
			}

		case .WORD:
			imm, iok := strconv.parse_int(value)
			if !iok || imm < int(min(i16)) || imm > int(max(u16)) {
				log.warnf("%q on line %d is not a valid word", value, line.lineno)
				ok = false
			} else {
				buf: [2]u8
				endian.put_u16(buf[:], .Little, u16(imm))
				append(&data, ..buf[:])
			}

		case .ASCII, .STRING:
			if !unescape_string(value, &data) {
				log.warnf("%s on line %d is not a valid string literal", value, line.lineno)
				ok = false
			} else if type == .STRING {
				append(&data, 0) // .string is NUL-terminated, .ascii is raw
			}

		case .SPRITE:
			// the operand is a path, so it goes through the same unescaping as
			// any other literal. An .ase file is decoded to one palette index
			// per pixel; anything else lands in the binary verbatim.
			path_buf := make([dynamic]u8, 0, 64, allocator)
			if !unescape_string(value, &path_buf) {
				log.warnf("%s on line %d is not a valid file path", value, line.lineno)
				ok = false
			} else {
				path := resolve_path(src_dir, string(path_buf[:]), allocator)
				blob, rok := os.read_entire_file(path, allocator)
				if rok != os.ERROR_NONE {
					log.warnf("could not read sprite file %q on line %d", path, line.lineno)
					ok = false
				} else {
					if len(blob) == 0 {
						log.warnf("sprite file %q on line %d is empty", path, line.lineno)
						ok = false
					} else if is_ase(blob) {
						px, w, h, aok := ase_decode(blob, allocator)
						if !aok {
							log.warnf("could not decode sprite %q on line %d", path, line.lineno)
							ok = false
						} else {
							debug.logf("sprite %q: %dx%d, %d bytes", name, w, h, len(px))
							append(&data, ..px)
							delete(px, allocator)
						}
					} else {
						append(&data, ..blob)
					}
					delete(blob, allocator)
				}
				delete(path, allocator)
			}
			delete(path_buf)
		}

		if !ok {
			n_errs += 1
			resize(&data, offset) // drop any half-written value
			continue
		}

		name_offsets[name] = offset
	}

	base := DATA_END - len(data)
	if base < DATA_FLOOR {
		log.warnf(
			"data section is %d bytes, so it would start at 0x%04x, below the stack base 0x%04x",
			len(data),
			base,
			DATA_FLOOR,
		)
		n_errs += 1
	}

	for name, offset in name_offsets {
		data_map[name] = u16(base + offset)
	}

	debug.logf(
		"data pass completed with %d errors: %d bytes at 0x%04x-0x%04x, %d names",
		n_errs,
		len(data),
		base,
		DATA_END - 1,
		len(data_map),
	)
	debug_print_data(data[:], data_map, u16(base))

	return data, data_map, (n_errs > 0 ? false : true)
}

// Substitutes every data name used as an operand in the code section with the
// address data_pass resolved it to.
//
// A bare name becomes the full "0xXXXX" address. Because no instruction takes a
// 16-bit immediate, a name may also be prefixed: ">name" is the high byte of
// the address and "<name" the low byte, which is what lets an address be built
// up in a 16-bit register with movi/slli/addi.
//
// Jump and call operands are skipped: those are code labels by definition, and
// label_pass owns them, so a data name that happens to match a label never
// steals the jump.
//
// The substituted text is allocated, so the returned list has to outlive the
// lines and be freed with data_text_destroy.
data_resolve_pass :: proc(
	asm_lines: [dynamic]Line,
	data_map: map[string]u16,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	bool,
) {
	n_errs := 0
	n_subs := 0
	gen_text: [dynamic]string

	for line in asm_lines {
		inst_data, iok := GET_INST_DATA(line.toks[0])
		if !iok {
			continue // a label definition, or something label_pass will report
		}
		if inst_data.type == .JMP_LABEL || inst_data.name == "call" {
			continue
		}

		for i in 1 ..< min(line.ntoks, len(line.toks)) {
			tok := line.toks[i]
			if len(tok) == 0 {
				continue
			}

			name := tok
			hi := false
			lo := false
			if tok[0] == '>' {
				name = tok[1:]
				hi = true
			} else if tok[0] == '<' {
				name = tok[1:]
				lo = true
			}

			addr, dok := data_map[name]
			if !dok {
				// only a sigil says for certain that a name was meant, so a
				// plain unknown token is left for the operand parsers
				if hi || lo {
					log.warnf("unknown data name %q on line %d", name, line.lineno)
					n_errs += 1
				}
				continue
			}

			text: string
			if hi {
				text = fmt.aprintf("0x%02x", addr >> 8, allocator = allocator)
			} else if lo {
				text = fmt.aprintf("0x%02x", addr & 0xFF, allocator = allocator)
			} else {
				text = fmt.aprintf("0x%04x", addr, allocator = allocator)
			}

			append(&gen_text, text)
			line.toks[i] = text
			n_subs += 1
		}
	}

	debug.logf("data resolve pass completed with %d errors: %d names substituted", n_errs, n_subs)
	return gen_text, (n_errs > 0 ? false : true)
}

data_text_destroy :: proc(gen_text: ^[dynamic]string, allocator := context.allocator) {
	for text in gen_text {
		delete(text, allocator)
	}
	delete(gen_text^)
}

// Lays the assembled code and the data block into one memory image, which is
// what load_prog reads straight into the address space. Code sits at 0 and the
// data block is packed against the top, so the image is the whole address
// space rather than just the bytes in use -- that is what puts a data name's
// resolved address and the byte actually living there in agreement.
build_image :: proc(code: []u8, data: []u8, allocator := context.allocator) -> ([]u8, bool) {
	n_errs := 0

	if len(code) > DATA_FLOOR {
		log.warnf(
			"code is %d bytes, which runs past the stack base 0x%04x",
			len(code),
			DATA_FLOOR,
		)
		n_errs += 1
	}

	base := DATA_END - len(data)
	if len(code) > base {
		log.warnf(
			"code is %d bytes and the data block starts at 0x%04x, so they overlap",
			len(code),
			base,
		)
		n_errs += 1
	}

	if n_errs > 0 {
		return nil, false
	}

	image := make([]u8, DATA_END, allocator)
	copy(image[:len(code)], code)
	copy(image[base:], data)

	debug.logf(
		"image: %d bytes, code 0x0000-0x%04x, data 0x%04x-0x%04x",
		len(image),
		len(code) > 0 ? len(code) - 1 : 0,
		base,
		DATA_END - 1,
	)

	return image, true
}

// Reports why an operand was rejected as an 8-bit immediate. A resolved data
// address is the interesting case: it parses fine and is simply too wide, and
// silently keeping its low byte is what makes a wrong program look like a
// working one.
imm_error :: proc(value: string, lineno: int) {
	if n, ok := strconv.parse_int(value); ok {
		if n > int(max(u8)) {
			// data_resolve_pass writes an address as exactly "0xNNNN", so a
			// value in that shape is almost certainly a data name that needs
			// splitting rather than a number the programmer typed
			if len(value) == 6 && value[:2] == "0x" {
				log.warnf(
					"%s on line %d is a 16-bit address and does not fit in an 8-bit immediate; use >name for the high byte and <name for the low byte",
					value,
					lineno,
				)
			} else {
				log.warnf(
					"%s on line %d does not fit in an 8-bit immediate, the maximum is %d",
					value,
					lineno,
					max(u8),
				)
			}
			return
		}
	}
	log.warnf("%q on line %d is not a valid immediate", value, lineno)
}

instruction_pass :: proc(asm_file: []Line, allocator := context.allocator) -> ([]u8, bool) {
	n_errs := 0
	out_buf := make([dynamic]u8, 0, len(asm_file) * INST_SZ, allocator)

	for line in asm_file {
		data, ok := GET_INST_DATA(line.toks[0])
		if !ok {
			log.warnf("unknown instruction %q on line %d", line.toks[0], line.lineno)
			n_errs += 1
			continue
		}

		inst_upper := strings.to_upper(line.toks[0], context.temp_allocator)
		val, enum_ok := reflect.enum_from_name(hw.Op, inst_upper)
		delete(inst_upper, context.temp_allocator)
		if !enum_ok {
			log.warnf("%q on line %d has no opcode", line.toks[0], line.lineno)
			n_errs += 1
			continue
		}
		inst := u16(val) << 11

		// an operand that does not encode is an error, not a warning: emitting
		// the instruction anyway would assemble a program that runs and is
		// quietly wrong
		bad := false

		#partial switch (data.type) {
		case (.IMM):
			dst, dok := REG_DST(line.toks[1])
			imm, iok := IMM(line.toks[2])
			if !dok {
				log.warnf("%q on line %d is not a register", line.toks[1], line.lineno)
				bad = true
			}
			if !iok {
				imm_error(line.toks[2], line.lineno)
				bad = true
			}
			inst |= dst | imm

		case (.ADDR):
			addr, aok := IMM(line.toks[1])
			if !aok {
				imm_error(line.toks[1], line.lineno)
				bad = true
			}
			inst |= addr

		case (.REG):
			reg, rok := REG_DST(line.toks[1])
			if !rok {
				log.warnf("%q on line %d is not a register", line.toks[1], line.lineno)
				bad = true
			}
			inst |= reg

		case (.REGREG):
			dst, dok := REG_DST(line.toks[1])
			src, sok := REG_SRC(line.toks[2])
			if !dok {
				log.warnf("%q on line %d is not a register", line.toks[1], line.lineno)
				bad = true
			}
			if !sok {
				log.warnf("%q on line %d is not a register", line.toks[2], line.lineno)
				bad = true
			}
			inst |= dst | src

		case (.JMP_LABEL):
			rel, rok := REL(line.toks[1])
			if !rok {
				log.warnf(
					"%q on line %d is not a valid jump offset",
					line.toks[1],
					line.lineno,
				)
				bad = true
			}
			inst |= rel

		case (.NONE):

		case:
			log.warnf(
				"%q on line %d has operand type %v, which has no encoding",
				line.toks[0],
				line.lineno,
				data.type,
			)
			bad = true
		}

		if bad {
			n_errs += 1
			continue
		}

		buf: [2]u8
		endian.put_u16(buf[:], .Little, inst)
		append(&out_buf, ..buf[:])
	}

	debug.logf(
		"instruction pass completed with %d errors: %d bytes",
		n_errs,
		len(out_buf),
	)

	return out_buf[:], (n_errs > 0 ? false : true)
}

comments_pass :: proc(asm_file: string, allocator := context.allocator) -> [dynamic]Line {
	asm_lines: [dynamic]Line
	n_errs := 0
	it := asm_file
	lineno := 0

	for line in strings.split_lines_iterator(&it) {
		lineno += 1

		line_tok, tok_ok := tokenize(line, allocator)
		if !tok_ok {
			log.warnf("unterminated string literal on line %d", lineno)
			n_errs += 1
			continue
		}

		n_toks := len(line_tok)

		if (n_toks == 0) {
			delete(line_tok, allocator)
			continue
		}

		for tok in line_tok {
			// string literals are data, not source text, so their case is left
			// exactly as it was written
			if IS_STRING_TOK(tok) {
				continue
			}
			lower_ascii_in_place(tok)
		}

		s_line: Line = {line_tok, n_toks, lineno, .NONE}
		append(&asm_lines, s_line)
	}

	debug.logf("comments pass completed with %d errors: %d lines", n_errs, len(asm_lines))
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

				if !gen_lines(&ret_lines, expansion, line.lineno, line.section, allocator) {
					log.warnf("could not expand call on line %d", line.lineno)
					n_errs += 1
				}

				delete(line.toks, allocator)

			case ("ret"):
				expansion := fmt.aprintf("pop fp\n" + "jmpf\n", allocator = allocator)
				append(&gen_text, expansion)

				if !gen_lines(&ret_lines, expansion, line.lineno, line.section, allocator) {
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

	// sprite paths in the source resolve against the source file's own
	// directory, not the process working directory. dir returns a substring of
	// the argument, so there is nothing to free here.
	src_dir := filepath.dir(positional_arg(os.args[1:], 0))

	asm_file, in_err := os.read_entire_file(opt.file, context.allocator)
	defer delete(asm_file, context.allocator)

	when debug.ENABLED {
		debug.log("source file:")
		fmt.eprintln(string(asm_file))
	}

	fmt.println()

	asm_tokenized := comments_pass(string(asm_file), context.allocator)

	data_section, code_section, sok := section_pass(asm_tokenized, context.allocator)
	defer {
		delete(data_section)
		delete(code_section)
	}

	if !sok {
		fmt.println("Failed section pass")
		os.exit(1)
	}

	data_buf, data_map, dok := data_pass(data_section[:], src_dir, context.allocator)
	defer {
		delete(data_buf)
		delete(data_map)
	}

	if !dok {
		fmt.println("Failed data pass")
		os.exit(1)
	}

	data_text, drok := data_resolve_pass(code_section, data_map, context.allocator)
	defer data_text_destroy(&data_text, context.allocator)

	if !drok {
		fmt.println("Failed data resolve pass")
		os.exit(1)
	}

	asm_labels_resolved, label_map, offset_text, lok := label_pass(
		code_section,
		context.allocator,
	)

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

	buf, bok := instruction_pass(asm_expanded[:], context.allocator)
	defer delete(buf, context.allocator)

	if !bok {
		fmt.println("Failed instruction pass")
		os.exit(1)
	}

	if in_err != os.ERROR_NONE {
		fmt.eprintfln("error: open failed: %v", in_err)
		os.exit(1)
	}

	image, iok := build_image(buf[:], data_buf[:], context.allocator)
	defer delete(image, context.allocator)

	if !iok {
		fmt.println("Failed to build the memory image")
		os.exit(1)
	}

	out_fname := opt.output != "" ? opt.output : "o.out"
	if w_err := os.write_entire_file(out_fname, image[:]); w_err != os.ERROR_NONE {
		fmt.eprintln("write failed:", w_err)
		os.exit(1)
	}
}
