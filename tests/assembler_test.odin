package tests

import "../src/assembler/"
import hw "../src/hardware"
import "core:reflect"
import "core:strings"
import "core:testing"

/*
* The assembler is a chain of passes over a [dynamic]Line rather than a
* line-at-a-time encoder, so these tests are written against the chain:
*
*     source text -> comments_pass -> label_pass -> alias_pass
*
* Nothing here calls a per-instruction encoder, because there is no longer one
* to call: assemble_inst and instruction_pass are still stubs. What the front
* end produces -- tokens, label addresses, expanded aliases -- is what can be
* pinned down today, and it is where the interesting behaviour lives anyway.
*
* Every pass borrows rather than copies. Tokens point into the source text,
* resolved jump operands point into the label map, and generated lines point
* into the expansion text alias_pass formats. That makes teardown order load
* bearing, so it is done once in pipe_destroy instead of in each test.
*/

/* ------------------------------------------------------------- pipeline */

// One run of the front end, plus everything it allocated.
Pipeline :: struct {
	src:       []u8, // owned; every token points into this
	lines:     [dynamic]assembler.Line, // comments_pass output
	labels:    map[string]string, // label_pass output
	offsets:   [dynamic]string, // backing text for the resolved jump offsets
	expanded:  [dynamic]assembler.Line, // alias_pass output
	gen_text:  [dynamic]string, // backing text for the expanded lines
	code:      []u8, // instruction_pass output
	label_ok:  bool,
	alias_ok:  bool,
	ran_label: bool,
	ran_alias: bool,
	ran_code:  bool,
}

// comments_pass lowercases tokens in place, so the source has to be a writable
// copy. Passing a string literal straight in would write to read-only memory.
pipe_text :: proc(p: ^Pipeline, text: string) {
	p.src = make([]u8, len(text))
	copy(p.src, text)
	p.lines = assembler.comments_pass(string(p.src))
}

// Fixture programs, embedded at compile time. #load resolves relative to this
// source file, so the suite does not care what directory it is launched from,
// and a missing fixture is a build error rather than a runtime one.
LABELS_ASM :: #load("asm_test/labels_test.asm", string)
ALIAS_ASM :: #load("asm_test/alias_test.asm", string)
BAD_LABELS_ASM :: #load("asm_test/bad_labels_test.asm", string)
DECODE_ASM :: #load("asm_test/decode_test.asm", string)

pipe_labels :: proc(p: ^Pipeline) {
	p.lines, p.labels, p.offsets, p.label_ok = assembler.label_pass(p.lines)
	p.ran_label = true
}

pipe_alias :: proc(p: ^Pipeline) {
	p.expanded, p.gen_text, p.alias_ok = assembler.alias_pass(p.lines)
	p.ran_alias = true
}

// Encodes whichever list is current: alias_pass's output once it has run, and
// comments_pass's otherwise. The bytes own no borrowed memory, unlike every
// other stage, so they are just a slice to release.
pipe_encode :: proc(p: ^Pipeline) {
	p.code = assembler.instruction_pass(p.ran_alias ? p.expanded[:] : p.lines[:])
	p.ran_code = true
}

/*
* Tears the run down in the reverse of the order it was built up.
*
* alias_pass frees the tokens of the alias lines it consumed and hands back a
* new list holding everything that survived, so once it has run `expanded` is
* the list that owns tokens and `lines` is just an array to release. The label
* map and the expansion text go last because live tokens still point at them.
*/
pipe_destroy :: proc(p: ^Pipeline) {
	owner := p.ran_alias ? p.expanded : p.lines
	for line in owner {
		delete(line.toks)
	}
	if p.ran_alias {
		delete(p.expanded)
	}
	delete(p.lines)
	if p.ran_code {
		delete(p.code)
	}
	assembler.alias_text_destroy(&p.gen_text)
	assembler.offset_text_destroy(&p.offsets)
	if p.ran_label {
		assembler.label_map_destroy(&p.labels)
	}
	delete(p.src)
}

/* ------------------------------------------------------------- assertions */

expect_toks :: proc(t: ^testing.T, got: assembler.Line, want: []string, loc := #caller_location) {
	if !testing.expectf(
		t,
		got.ntoks == len(want),
		"line %d: got %d tokens %v, want %d %v",
		got.lineno,
		got.ntoks,
		got.toks,
		len(want),
		want,
		loc = loc,
	) {
		return
	}
	for w, i in want {
		testing.expectf(
			t,
			got.toks[i] == w,
			"line %d token %d: got %q, want %q",
			got.lineno,
			i,
			got.toks[i],
			w,
			loc = loc,
		)
	}
}

// Compares a whole pass output, one token list per line.
expect_lines :: proc(
	t: ^testing.T,
	got: []assembler.Line,
	want: [][]string,
	loc := #caller_location,
) {
	if !testing.expectf(
		t,
		len(got) == len(want),
		"line count mismatch: got %d, want %d (got %v)",
		len(got),
		len(want),
		lines_to_text(got),
		loc = loc,
	) {
		return
	}
	for w, i in want {
		expect_toks(t, got[i], w, loc = loc)
	}
}

// Just the mnemonics, for cases where the operands are beside the point.
expect_mnemonics :: proc(
	t: ^testing.T,
	got: []assembler.Line,
	want: []string,
	loc := #caller_location,
) {
	if !testing.expectf(
		t,
		len(got) == len(want),
		"line count mismatch: got %d, want %d (got %v)",
		len(got),
		len(want),
		lines_to_text(got),
		loc = loc,
	) {
		return
	}
	for w, i in want {
		testing.expectf(
			t,
			got[i].toks[0] == w,
			"line %d: got mnemonic %q, want %q",
			i,
			got[i].toks[0],
			w,
			loc = loc,
		)
	}
}

// Failure messages are far easier to read as reassembled source than as a dump
// of nested slices. Temp-allocated: valid until the caller's next free_all.
lines_to_text :: proc(lines: []assembler.Line) -> []string {
	out := make([]string, len(lines), context.temp_allocator)
	for line, i in lines {
		out[i] = strings.join(line.toks[:line.ntoks], " ", context.temp_allocator)
	}
	return out
}

expect_labels :: proc(
	t: ^testing.T,
	got: map[string]string,
	want_names: []string,
	want_addrs: []string,
	loc := #caller_location,
) {
	if !testing.expectf(
		t,
		len(got) == len(want_names),
		"label count mismatch: got %d %v, want %d %v",
		len(got),
		got,
		len(want_names),
		want_names,
		loc = loc,
	) {
		return
	}
	for name, i in want_names {
		addr, ok := got[name]
		if !testing.expectf(t, ok, "label %q is missing from the map", name, loc = loc) {
			continue
		}
		testing.expectf(
			t,
			addr == want_addrs[i],
			"label %q: got address %q, want %q",
			name,
			addr,
			want_addrs[i],
			loc = loc,
		)
	}
}

/* ------------------------------------------------------------ inst table */

@(test)
inst_data_lookup_test :: proc(t: ^testing.T) {
	// GET_INST_DATA is a linear scan of INST_DATA, so every entry has to be
	// reachable by its own name and nothing else may be.
	for want in assembler.INST_DATA {
		got, ok := assembler.GET_INST_DATA(want.name)
		if !testing.expectf(t, ok, "INST_DATA entry %q is not reachable", want.name) {
			continue
		}
		testing.expect_value(t, got, want)
	}

	for name in ([]string{"frobnicate", "", "ADD", "add ", "cmpi", "mov"}) {
		_, ok := assembler.GET_INST_DATA(name)
		testing.expectf(t, !ok, "%q should not be a known mnemonic", name)
	}
}

@(test)
inst_data_is_well_formed_test :: proc(t: ^testing.T) {
	// The table is hand maintained, and three of its invariants are relied on
	// elsewhere: lookups are case sensitive against lowercased tokens, names
	// are unique or the scan silently picks the first, and width is what
	// label_pass advances the address counter by.
	for inst, i in assembler.INST_DATA {
		testing.expectf(
			t,
			inst.name == strings.to_lower(inst.name, context.temp_allocator),
			"INST_DATA[%d] %q is not lowercase; comments_pass lowercases every token",
			i,
			inst.name,
		)
		testing.expectf(
			t,
			inst.width >= 1,
			"INST_DATA[%d] %q has width %d; every instruction occupies at least one slot",
			i,
			inst.name,
			inst.width,
		)

		// Only aliases expand, so only aliases are wider than one instruction.
		if inst.type == .ALIAS {
			testing.expectf(
				t,
				inst.width > 1,
				"alias %q has width %d; an alias expands to several instructions",
				inst.name,
				inst.width,
			)
		} else {
			testing.expectf(
				t,
				inst.width == 1,
				"%q is not an alias but has width %d",
				inst.name,
				inst.width,
			)
		}

		for other, j in assembler.INST_DATA {
			testing.expectf(
				t,
				i == j || inst.name != other.name,
				"INST_DATA has %q twice, at %d and %d",
				inst.name,
				i,
				j,
			)
		}
	}

	// Each operand form fixes its own arity, and gen_line enforces the number
	// the table records. .ALIAS and .ADDR are left out: an alias takes whatever
	// its expansion needs, and nothing carries .ADDR yet.
	for inst in assembler.INST_DATA {
		want := -1
		switch inst.type {
		case .REGREG, .IMM:
			want = 2
		case .REG, .JMP_LABEL:
			want = 1
		case .NONE:
			want = 0
		case .ALIAS, .ADDR:
			continue
		}
		testing.expectf(
			t,
			inst.n_operands == want,
			"%q is %v, which takes %d operands, but the table says %d",
			inst.name,
			inst.type,
			want,
			inst.n_operands,
		)
	}

	free_all(context.temp_allocator)
}

/* -------------------------------------------------------- register table */

@(test)
register_table_test :: proc(t: ^testing.T) {
	// REG_SRC yields the raw code; REG_DST is the same code shifted into the
	// dst field at bits 10-8. They are two near-identical procs, which is the
	// shape that gets copy-pasted wrong.
	for reg in assembler.REGISTERS {
		src, sok := assembler.REG_SRC(reg.name)
		testing.expectf(t, sok, "REG_SRC(%q) returned ok=false", reg.name)
		testing.expect_value(t, src, reg.code)

		dst, dok := assembler.REG_DST(reg.name)
		testing.expectf(t, dok, "REG_DST(%q) returned ok=false", reg.name)
		testing.expect_value(t, dst, reg.code << 8)
	}

	// The dst field is three bits wide, so no code may spill out of it.
	for reg in assembler.REGISTERS {
		testing.expectf(
			t,
			reg.code <= 0x07,
			"register %q has code %d, which does not fit the 3-bit operand field",
			reg.name,
			reg.code,
		)
	}

	// Names the table deliberately does not carry: the rN aliases are gone,
	// x and y are gone, and codes 3 and 7 are unassigned rather than aliased
	// onto a real register.
	for name in ([]string{"r0", "r1", "r2", "x", "y", "z", "", "A", "acc"}) {
		_, ok := assembler.REG_SRC(name)
		testing.expectf(t, !ok, "%q should not be a register name", name)
	}
}

@(test)
register_table_matches_hardware_test :: proc(t: ^testing.T) {
	// The assembler's name-to-code table and the hardware's register codes are
	// two hand-maintained halves of the same encoding. If they drift, every
	// operand assembles to the wrong register and nothing else notices.
	names := []string{"a", "b", "fp", "sp", "pc", "flags"}
	codes := []u16{R_A, R_B, R_FP, R_SP, R_PC, R_FLAGS}

	testing.expect_value(t, len(assembler.REGISTERS), len(names))
	for name, i in names {
		code, ok := assembler.REG_SRC(name)
		if !testing.expectf(t, ok, "assembler does not know register %q", name) {
			continue
		}
		testing.expectf(
			t,
			code == codes[i],
			"register %q: assembler encodes %d, hardware reads code %d",
			name,
			code,
			codes[i],
		)
	}
}

/* ------------------------------------------------------------- immediate */

@(test)
imm_test :: proc(t: ^testing.T) {
	// IMM parses the immediate field: base is detected from the prefix, and
	// the result has to fit the 8 bits the instruction word gives it.
	Case :: struct {
		src:  string,
		want: u16,
	}
	for c in ([]Case {
			{"0", 0},
			{"5", 5},
			{"105", 105}, // decimal, not hex
			{"255", 0xFF}, // the field's upper bound
			{"0x00", 0x00},
			{"0xff", 0xFF},
			{"0b1010", 0b1010},
		}) {
		got, ok := assembler.IMM(c.src)
		if !testing.expectf(t, ok, "IMM(%q) returned ok=false", c.src) {
			continue
		}
		testing.expectf(t, got == c.want, "IMM(%q): got 0x%04x, want 0x%04x", c.src, got, c.want)
	}

	// A negative immediate is stored as its two's complement byte, so -8 is
	// the same eight bits as 0xF8 and subi/addi need no signed form.
	neg, nok := assembler.IMM("-8")
	testing.expect(t, nok, "IMM(-8) returned ok=false")
	testing.expect_value(t, neg, u16(0xF8))

	// Rejected: out of range, and anything that is not a number at all.
	for src in ([]string{"256", "0x100", "banana", "", "a", "0x", "1 2"}) {
		_, ok := assembler.IMM(src)
		testing.expectf(t, !ok, "IMM(%q) should have failed", src)
	}
}

/* ------------------------------------------------------------- gen_line */

@(test)
gen_line_test :: proc(t: ^testing.T) {
	// gen_line is how alias_pass turns an expansion template back into Lines,
	// so it validates the mnemonic and the operand count up front rather than
	// letting a malformed template reach the encoder.
	line, ok := assembler.gen_line("movi fp 0x1a", 7)
	defer if ok {
		delete(line.toks)
	}
	testing.expect(t, ok, "gen_line: %q should parse")
	expect_toks(t, line, []string{"movi", "fp", "0x1a"})

	// Leading and trailing whitespace is not significant.
	spaced, sok := assembler.gen_line("   jmpf   ", 1)
	defer if sok {
		delete(spaced.toks)
	}
	testing.expect(t, sok, "gen_line: surrounding whitespace should be ignored")
	expect_toks(t, spaced, []string{"jmpf"})

	// Rejected: nothing to parse, an unknown mnemonic, and an operand count
	// that disagrees with the instruction's arity in either direction.
	for src in ([]string {
			"",
			"   ",
			"frobnicate",
			"movi",
			"movi fp",
			"movi fp 1 2",
			"jmpf fp",
			"push",
			"push a b",
			"add a",
		}) {
		bad, bok := assembler.gen_line(src, 1)
		testing.expectf(t, !bok, "gen_line(%q) should have failed", src)
		if bok {
			delete(bad.toks)
		}
	}
}

@(test)
gen_lines_test :: proc(t: ^testing.T) {
	// The multi-line form is what an alias expansion actually goes through.
	// Blank lines are skipped so a template can be laid out readably.
	out: [dynamic]assembler.Line
	defer {
		for line in out {
			delete(line.toks)
		}
		delete(out)
	}

	ok := assembler.gen_lines(&out, "movi fp 0x1a\n\nslli fp 8\n\taddi fp 0x2c\njmpf\n", 3)
	testing.expect(t, ok, "gen_lines: valid template should expand")
	expect_lines(
		t,
		out[:],
		[][]string {
			{"movi", "fp", "0x1a"},
			{"slli", "fp", "8"},
			{"addi", "fp", "0x2c"},
			{"jmpf"},
		},
	)

	// A template with no instructions in it is not an error; it produces
	// nothing, which is what a caller appending to a shared list expects.
	empty_ok := assembler.gen_lines(&out, "\n   \n\t\n", 1)
	testing.expect(t, empty_ok, "gen_lines: an all-blank template is not an error")
	testing.expect_value(t, len(out), 4)
}

@(test)
gen_lines_keeps_partial_output_test :: proc(t: ^testing.T) {
	// A bad line stops the expansion, but the lines already appended stay in
	// the caller's list -- they are allocated, so dropping them would leak.
	out: [dynamic]assembler.Line
	defer {
		for line in out {
			delete(line.toks)
		}
		delete(out)
	}

	ok := assembler.gen_lines(&out, "movi fp 0x1a\nfrobnicate\naddi fp 0x2c\n", 1)
	testing.expect(t, !ok, "gen_lines: an unknown mnemonic should fail the expansion")
	expect_lines(t, out[:], [][]string{{"movi", "fp", "0x1a"}})
}

/* -------------------------------------------------------- comments pass */

@(test)
comments_pass_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(
		&p,
		"; a whole-line comment\n" +
		"MOVI A 0        ; trailing comment\n" +
		"\n" +
		"   \t   \n" +
		"\tADD   a   b\n" +
		";\n" +
		"HALT\n",
	)

	// Comments and blank lines emit nothing; everything else becomes one Line
	// of whitespace-separated tokens, lowercased in place.
	expect_lines(
		t,
		p.lines[:],
		[][]string{{"movi", "a", "0"}, {"add", "a", "b"}, {"halt"}},
	)

	// The line number is the line in the source file, not the index in the
	// output, so an error message points at something the user can find.
	testing.expect_value(t, p.lines[0].lineno, 2)
	testing.expect_value(t, p.lines[1].lineno, 5)
	testing.expect_value(t, p.lines[2].lineno, 7)

	// ntoks mirrors the token count and is what every later pass indexes with.
	for line in p.lines {
		testing.expect_value(t, line.ntoks, len(line.toks))
	}
}

@(test)
comments_pass_keeps_labels_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// Label definitions are ordinary tokens at this stage; label_pass is what
	// gives the trailing colon meaning. A label sharing a line with an
	// instruction stays two separate tokens on one line, which is why
	// label_pass only ever inspects toks[0].
	pipe_text(&p, "MAIN:\n\thalt\nDONE: halt\n")

	expect_lines(t, p.lines[:], [][]string{{"main:"}, {"halt"}, {"done:", "halt"}})
}

@(test)
comments_pass_lowercases_in_place_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// The tokens are slices of the source buffer rather than copies, so
	// lowercasing them rewrites the buffer itself. That is what makes the
	// source outliving every Line a hard requirement and not a nicety.
	pipe_text(&p, "MOVI A 0\n")

	testing.expect_value(t, string(p.src), "movi a 0\n")
	testing.expect(
		t,
		raw_data(p.lines[0].toks[0]) == raw_data(p.src),
		"tokens should borrow from the source buffer, not copy it",
	)
}

/* ----------------------------------------------------------- label pass */

@(test)
label_pass_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, LABELS_ASM)
	pipe_labels(&p)
	testing.expect(t, p.label_ok, "label_pass should succeed on labels_test.asm")

	// Each label maps to the address of the next instruction, formatted once
	// as a zero-padded 16-bit hex literal. The padding is not cosmetic: the
	// call expansion slices the string into two bytes, so a short address
	// would be sliced apart in the wrong place.
	expect_labels(
		t,
		p.labels,
		[]string{"_start_", "loop", "done"},
		[]string{"0x0000", "0x0004", "0x000c"},
	)

	// Label lines survive the pass; only the jump operands change. A backward
	// reference is substituted as it is met, a forward one on the second sweep,
	// and both come out identical.
	expect_lines(
		t,
		p.lines[:],
		[][]string {
			{"_start_:"},
			{"movi", "a", "0"},
			{"movi", "b", "4"},
			{"loop:"},
			{"cmpr", "b", "a"},
			{"jeq", "4"}, // forward
			{"addi", "a", "16"},
			{"jmp", "-8"}, // backward
			{"done:"},
			{"halt"},
		},
	)
}

@(test)
label_pass_alias_width_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, ALIAS_ASM)
	pipe_labels(&p)
	testing.expect(t, p.label_ok, "label_pass should succeed on alias_test.asm")

	// An alias is several instructions wide, and the address counter has to
	// account for all of them before alias_pass has expanded anything. The
	// eight-instruction prelude and the eight-instruction call are 0x10 bytes
	// each, so helper sits at 0x10 + 0x10 + 2 = 0x22.
	expect_labels(t, p.labels, []string{"main", "helper"}, []string{"0x0000", "0x0022"})

	// call resolves its label the same way the jumps do, which is what lets
	// alias_pass assume a literal address.
	expect_lines(
		t,
		p.lines[:],
		[][]string {
			{"main:"},
			{"movi", "a", "0xef"},
			{"push", "a"},
			{"movi", "a", "0xbe"},
			{"push", "a"},
			{"movi", "a", "0xad"},
			{"push", "a"},
			{"movi", "a", "0xde"},
			{"push", "a"},
			{"call", "0x0022"},
			{"halt"},
			{"helper:"},
			{"movi", "a", "0x80"},
			{"movi", "b", "0xfe"},
			{"st", "b", "a"},
			{"addi", "a", "1"},
			{"movi", "b", "0xed"},
			{"st", "b", "a"},
			{"addi", "a", "1"},
			{"movi", "b", "0xbe"},
			{"st", "b", "a"},
			{"addi", "a", "1"},
			{"movi", "b", "0xef"},
			{"st", "b", "a"},
			{"ret"},
		},
	)
}

@(test)
label_pass_no_labels_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, DECODE_ASM)
	pipe_labels(&p)

	// A program with no labels passes through untouched and leaves an empty
	// map rather than failing for want of anything to resolve.
	testing.expect(t, p.label_ok, "label_pass: a program with no labels is not an error")
	testing.expect_value(t, len(p.labels), 0)
	expect_mnemonics(
		t,
		p.lines[:],
		[]string{"xor", "addi", "xor", "addi", "add", "xor", "addi", "mul", "subi", "halt"},
	)
}

@(test)
label_pass_out_of_range_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// The offset field reaches 1023 bytes forward. 512 filler instructions put
	// far at 0x0402, needing an offset of 1024 -- one past the end of the
	// field. Truncating it would assemble cleanly and then jump somewhere
	// unrelated, so it is refused instead.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "jmp far\n")
	for _ in 0 ..< 512 {
		strings.write_string(&sb, "halt\n")
	}
	strings.write_string(&sb, "far:\nhalt\n")

	pipe_text(&p, strings.to_string(sb))
	pipe_labels(&p)
	testing.expect(t, !p.label_ok, "a jump beyond the offset field should fail")
}

@(test)
label_pass_reach_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// One instruction closer and it resolves: far lands at 0x0400, an offset of
	// 1022, which is as far as an even-aligned jump can reach.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "jmp far\n")
	for _ in 0 ..< 511 {
		strings.write_string(&sb, "halt\n")
	}
	strings.write_string(&sb, "far:\nhalt\n")

	pipe_text(&p, strings.to_string(sb))
	pipe_labels(&p)
	testing.expect(t, p.label_ok, "a jump within the offset field should resolve")
	expect_toks(t, p.lines[0], []string{"jmp", "1022"})
}

@(test)
label_pass_undefined_label_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, BAD_LABELS_ASM)
	pipe_labels(&p)

	// The label is never defined, so the second sweep has nothing to
	// substitute and the pass has to say so. The operand is left as written
	// rather than silently becoming address zero.
	testing.expect(t, !p.label_ok, "label_pass should fail on an undefined label")
	expect_labels(t, p.labels, []string{"start"}, []string{"0x0000"})
	expect_toks(t, p.lines[1], []string{"jmp", "nowhere"})
}

@(test)
label_pass_missing_operand_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// A jump with no target would index past the end of its own token list,
	// so the arity is checked before the operand is read.
	pipe_text(&p, "start:\n\tjmp\n\thalt\n")
	pipe_labels(&p)

	testing.expect(t, !p.label_ok, "label_pass should fail on a jump with no target")
}

@(test)
label_pass_unknown_instruction_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// An unknown mnemonic has no width, so the addresses of everything after
	// it would be wrong. The pass reports it rather than emitting them.
	pipe_text(&p, "start:\n\tfrobnicate a b\n\thalt\n")
	pipe_labels(&p)

	testing.expect(t, !p.label_ok, "label_pass should fail on an unknown mnemonic")
}

/* ----------------------------------------------------------- alias pass */

@(test)
alias_pass_ret_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, "ret\n")
	pipe_labels(&p)
	pipe_alias(&p)

	testing.expect(t, p.alias_ok, "alias_pass should expand ret")

	// pop moves fp's own width, so the whole return address comes back in one
	// instruction. The line count has to match the width INST_DATA claims for
	// ret, or label_pass has already computed the wrong addresses.
	expect_lines(t, p.expanded[:], [][]string{{"pop", "fp"}, {"jmpf"}})

	ret_data, ok := assembler.GET_INST_DATA("ret")
	testing.expect(t, ok, "ret should be in INST_DATA")
	testing.expectf(
		t,
		int(ret_data.width) == len(p.expanded),
		"ret expands to %d instructions but INST_DATA reserves %d",
		len(p.expanded),
		ret_data.width,
	)
}

@(test)
alias_pass_call_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, ALIAS_ASM)
	pipe_labels(&p)
	pipe_alias(&p)

	testing.expect(t, p.alias_ok, "alias_pass should expand call")

	// Ordinary instructions pass through untouched, the two aliases are
	// replaced, and the label lines are dropped -- so what comes out is exactly
	// the instruction stream, one line per machine instruction.
	expect_mnemonics(
		t,
		p.expanded[:],
		[]string {
			// the prelude, passed through
			"movi", "push", "movi", "push", "movi", "push", "movi", "push",
			// call
			"movi", "add", "addi", "push", "movi", "slli", "addi", "jmpf",
			"halt",
			// the helper body, passed through
			"movi", "movi", "st", "addi", "movi", "st", "addi", "movi", "st",
			"addi", "movi", "st",
			// ret
			"pop", "jmpf",
		},
	)

	// The first half captures the return address: pc reads as the instruction
	// after the add, so CALL_SKIP carries it past the rest of the expansion.
	expect_toks(t, p.expanded[8], []string{"movi", "fp", "0"})
	expect_toks(t, p.expanded[9], []string{"add", "fp", "pc"})
	expect_toks(t, p.expanded[10], []string{"addi", "fp", "12"})
	expect_toks(t, p.expanded[11], []string{"push", "fp"})

	// The address half is the reason label_pass has to hand call a resolved
	// literal: fp is loaded one byte at a time, high byte first, because the
	// immediate field is only eight bits wide. helper is at 0x0022, so the
	// halves are 0x00 and 0x22.
	expect_toks(t, p.expanded[12], []string{"movi", "fp", "0x00"})
	expect_toks(t, p.expanded[13], []string{"slli", "fp", "8"})
	expect_toks(t, p.expanded[14], []string{"addi", "fp", "0x22"})

	// Every line the expansion produced is attributed to the call it came
	// from, which in alias_test.asm is on source line 12. Without that a later
	// pass could only report an error against a line the user never wrote.
	for i in 8 ..< 16 {
		testing.expectf(
			t,
			p.expanded[i].lineno == 12,
			"expanded line %d: got lineno %d, want 12 (the call it came from)",
			i,
			p.expanded[i].lineno,
		)
	}

	// and the lines that were merely forwarded keep their own numbers
	testing.expect_value(t, p.expanded[16].lineno, 13) // halt

	call_data, ok := assembler.GET_INST_DATA("call")
	testing.expect(t, ok, "call should be in INST_DATA")
	testing.expect_value(t, call_data.width, u16(8))
}

@(test)
alias_pass_passthrough_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// A program with no aliases in it keeps its instructions unchanged, tokens
	// and all. Label lines are the one thing dropped: they have no INST_DATA
	// entry, label_pass has already recorded their addresses, and the encoder
	// has no opcode to give them.
	pipe_text(&p, "start:\n\tmovi a 0\n\tadd a b\n\thalt\n")
	pipe_labels(&p)
	pipe_alias(&p)

	testing.expect(t, p.alias_ok, "alias_pass: a program with no aliases should succeed")
	expect_lines(
		t,
		p.expanded[:],
		[][]string{{"movi", "a", "0"}, {"add", "a", "b"}, {"halt"}},
	)
}

@(test)
alias_pass_unresolved_call_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// alias_pass runs after label_pass and builds the address out of the two
	// halves of the operand text, so anything that is not a 16-bit literal is
	// refused instead of being sliced into nonsense. Skipping label_pass here
	// is what leaves the operand unresolved.
	pipe_text(&p, "call helper\n")
	pipe_alias(&p)

	testing.expect(t, !p.alias_ok, "alias_pass should reject an unresolved call operand")
	testing.expect_value(t, len(p.expanded), 0)
}

@(test)
alias_pass_short_call_operand_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// A hex literal that is merely short is refused for the same reason: the
	// expansion slices bytes out of fixed positions in the string.
	pipe_text(&p, "call 0x14\n")
	pipe_alias(&p)

	testing.expect(t, !p.alias_ok, "alias_pass should reject a short call operand")
	testing.expect_value(t, len(p.expanded), 0)
}

/* ---------------------------------------------------------- whole chain */

@(test)
front_end_test :: proc(t: ^testing.T) {
	p: Pipeline
	defer pipe_destroy(&p)

	// The three passes in the order main runs them, over a program that
	// exercises comments, mixed case, a forward jump, a backward jump and both
	// aliases at once.
	pipe_text(
		&p,
		"; count b down to a, then return\n" +
		"MAIN:\n" +
		"\tMOVI a 0        ; 0x0000\n" +
		"\tCALL COUNT      ; 0x0002, eight instructions wide\n" +
		"\tHALT            ; 0x0012\n" +
		"\n" +
		"COUNT:              ; 0x0014\n" +
		"\tCMPR b a\n" +
		"\tJEQ FINISH\n" +
		"\tSUBI b 1\n" +
		"\tJMP COUNT\n" +
		"FINISH:             ; 0x001c\n" +
		"\tRET\n",
	)

	pipe_labels(&p)
	testing.expect(t, p.label_ok, "front end: label pass failed")
	expect_labels(
		t,
		p.labels,
		[]string{"main", "count", "finish"},
		[]string{"0x0000", "0x0014", "0x001c"},
	)

	pipe_alias(&p)
	testing.expect(t, p.alias_ok, "front end: alias pass failed")

	// Two aliases expanded (8 + 2 lines) around six real instructions, with the
	// three label lines dropped once their addresses had been recorded.
	expect_mnemonics(
		t,
		p.expanded[:],
		[]string {
			"movi",
			// call count
			"movi", "add", "addi", "push", "movi", "slli", "addi", "jmpf",
			"halt",
			"cmpr", "jeq", "subi", "jmp",
			// ret
			"pop", "jmpf",
		},
	)

	// call loaded the address count resolved to, while the jumps carry a signed
	// distance from the instruction after them: jeq at 0x0016 reaching finish at
	// 0x001c is +4, jmp at 0x001a reaching count at 0x0014 is -8.
	expect_toks(t, p.expanded[5], []string{"movi", "fp", "0x00"})
	expect_toks(t, p.expanded[7], []string{"addi", "fp", "0x14"})
	expect_toks(t, p.expanded[11], []string{"jeq", "4"})
	expect_toks(t, p.expanded[13], []string{"jmp", "-8"})
}

/* ---------------------------------------------------- instruction pass */

/*
* The last pass: Lines in, machine code out. Two bytes per instruction, little
* endian, laid out per the operand-form tables in docs/cpu-spec.md:
*
*     15-11   10-8    7-0
*     opcode  dst     src / immediate / address
*
* The opcode itself is not a table in the assembler at all -- instruction_pass
* looks the mnemonic up in the hardware's own Op enum -- so these tests are
* really checking that the two halves of the project still agree on the numbers.
*/

// instruction_pass writes each instruction as two little-endian bytes, so a
// mismatch reads far better as the u16 it was meant to encode.
expect_words :: proc(t: ^testing.T, got: []u8, want: []u16, loc := #caller_location) {
	if !testing.expectf(
		t,
		len(got) == len(want) * 2,
		"byte count mismatch: got %d bytes, want %d (%d instructions)",
		len(got),
		len(want) * 2,
		len(want),
		loc = loc,
	) {
		return
	}
	for w, i in want {
		lo, hi := got[i * 2], got[i * 2 + 1]
		testing.expectf(
			t,
			lo == u8(w & 0xFF) && hi == u8(w >> 8),
			"instruction %d: got bytes %02x %02x (0x%04x), want 0x%04x little-endian",
			i,
			lo,
			hi,
			u16(hi) << 8 | u16(lo),
			w,
			loc = loc,
		)
	}
}

// Assembles a single instruction and hands back the word it encoded to.
encode :: proc(t: ^testing.T, src: string, loc := #caller_location) -> (word: u16, ok: bool) {
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, src)
	pipe_encode(&p)

	if !testing.expectf(
		t,
		len(p.code) == 2,
		"encode(%q): emitted %d bytes, want 2",
		src,
		len(p.code),
		loc = loc,
	) {
		return 0, false
	}
	return u16(p.code[0]) | u16(p.code[1]) << 8, true
}

expect_encoding :: proc(t: ^testing.T, src: string, want: u16, loc := #caller_location) {
	got, ok := encode(t, src, loc = loc)
	if !ok {
		return
	}
	testing.expectf(t, got == want, "%q: got 0x%04x, want 0x%04x", src, got, want, loc = loc)
}

@(test)
instruction_pass_operand_classes_test :: proc(t: ^testing.T) {
	// One instruction per operand form, so a change to the class dispatch shows
	// up here as a specific encoding rather than a vague byte-count mismatch.

	// reg-reg: opcode | dst<<8 | src
	expect_encoding(t, "add a b", 0x0001)
	expect_encoding(t, "add b a", 0x0100) // dst and src are not interchangeable
	expect_encoding(t, "xor a a", 0x3000)
	expect_encoding(t, "cmpr b a", 0x6100) // class upper bound, 0x6000

	// The register field is three bits, so the 16-bit registers are reachable
	// by the same encoding as a and b -- which is what lets ld and st name an
	// address anywhere in the 64K space.
	expect_encoding(t, "ld fp sp", 0x5204)
	expect_encoding(t, "st pc sp", 0x5D04)

	// immediate: opcode | dst<<8 | imm
	expect_encoding(t, "movi a 0", 0x6800) // class lower bound
	expect_encoding(t, "addi b 105", 0x7169) // decimal, not hex
	expect_encoding(t, "addi b 0x69", 0x7169) // and the hex form agrees
	expect_encoding(t, "subi a 1", 0x8001)
	expect_encoding(t, "slli fp 8", 0x9A08)
	expect_encoding(t, "srli fp 8", 0xA208) // class upper bound

	// A negative immediate rides as its two's complement byte.
	expect_encoding(t, "addi b -8", 0x71F8)

	// jump: opcode | offset, the offset signed and eleven bits wide. The field
	// runs down from bit 10, so it takes in the three bits the other forms
	// spend on a register.
	expect_encoding(t, "jmp 0x12", 0xA812) // class lower bound
	expect_encoding(t, "jeq 0x0c", 0xB80C)
	expect_encoding(t, "jle 0x04", 0xD804) // class upper bound

	// A backward jump is the two's complement of the distance: -8 & 0x07FF.
	expect_encoding(t, "jmp -8", 0xAFF8)
	expect_encoding(t, "jne -1", 0xB7FF)

	// The ends of the field.
	expect_encoding(t, "jmp 1023", 0xABFF)
	expect_encoding(t, "jmp -1024", 0xAC00)

	// single-reg: opcode | reg<<8, in the field the other forms use for dst
	expect_encoding(t, "push a", 0xE000) // class lower bound
	expect_encoding(t, "push b", 0xE100)
	expect_encoding(t, "pop a", 0xE800) // pop names its own destination
	expect_encoding(t, "pop b", 0xE900)

	// no-operand: opcode alone
	expect_encoding(t, "jmpf", 0xF000) // class lower bound
	expect_encoding(t, "halt", 0xF800)
}

@(test)
instruction_pass_opcode_matches_op_enum_test :: proc(t: ^testing.T) {
	// The strongest check available: every mnemonic the assembler accepts must
	// encode to the opcode the CPU decodes it as. instruction_pass gets the
	// number from reflect over hw.Op, so this is really asserting that a
	// renumbering of the enum carries the assembler with it -- and that every
	// non-alias entry in INST_DATA is actually encodable.
	for inst in assembler.INST_DATA {
		if inst.type == .ALIAS {
			continue // expanded before the encoder ever sees them
		}

		// a minimal, valid instruction of the right shape
		src: string
		switch inst.type {
		case .REGREG:
			src = strings.concatenate({inst.name, " a b"}, context.temp_allocator)
		case .IMM:
			src = strings.concatenate({inst.name, " a 0"}, context.temp_allocator)
		case .JMP_LABEL, .ADDR:
			src = strings.concatenate({inst.name, " 0"}, context.temp_allocator)
		case .REG:
			src = strings.concatenate({inst.name, " a"}, context.temp_allocator)
		case .NONE:
			src = inst.name
		case .ALIAS:
			continue
		}

		word, ok := encode(t, src)
		if !ok {
			continue
		}

		name := strings.to_upper(inst.name, context.temp_allocator)
		op, found := reflect.enum_from_name(hw.Op, name)
		if !testing.expectf(t, found, "%q has no member in hw.Op", inst.name) {
			continue
		}

		testing.expectf(
			t,
			word >> 11 == u16(op),
			"%q encoded opcode %d, but hw.Op.%s is %d",
			inst.name,
			word >> 11,
			name,
			u16(op),
		)
	}

	free_all(context.temp_allocator)
}

@(test)
instruction_pass_is_little_endian_test :: proc(t: ^testing.T) {
	// The low byte sits at the lower address, matching the CPU's own multi-byte
	// loads and stores. Getting this backwards would swap the opcode into the
	// operand field and still produce a plausible-looking file.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, "halt\n") // 0xF800: the two bytes are unmistakably different
	pipe_encode(&p)

	testing.expect_value(t, len(p.code), 2)
	testing.expect_value(t, p.code[0], u8(0x00)) // low
	testing.expect_value(t, p.code[1], u8(0xF8)) // high
}

@(test)
instruction_pass_emits_two_bytes_per_instruction_test :: proc(t: ^testing.T) {
	// The width label_pass reserves for each instruction and the width the
	// encoder actually emits have to agree, or every label address after the
	// first is wrong.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, "movi a 0\nadd a b\njmp 0x12\npush a\nhalt\n")
	pipe_encode(&p)

	testing.expect_value(t, len(p.code), 5 * assembler.INST_SZ)
	expect_words(t, p.code, []u16{0x6800, 0x0001, 0xA812, 0xE000, 0xF800})
}

@(test)
instruction_pass_label_addresses_test :: proc(t: ^testing.T) {
	// A label emits no bytes, so the address label_pass recorded for it has to
	// be the offset its next instruction actually lands at. If the two ever
	// disagree every jump in the program is off.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, "start:\n\tmovi a 0\ndone:\n\thalt\n")
	pipe_labels(&p)
	expect_labels(t, p.labels, []string{"start", "done"}, []string{"0x0000", "0x0002"})

	// The labels have to be read before the encoder runs. label_map's keys are
	// slices of the source buffer, and instruction_pass uppercases mnemonics in
	// that same buffer -- harmless in the real pipeline, where alias_pass has
	// already dropped every label line, but it is why these passes run in this
	// order and not another.
	pipe_alias(&p)
	pipe_encode(&p)

	expect_words(t, p.code, []u16{0x6800, 0xF800})
}

@(test)
instruction_pass_empty_test :: proc(t: ^testing.T) {
	// Nothing to assemble is not an error; it just produces no bytes.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, "; nothing but a comment\n\n\t\n")
	pipe_encode(&p)

	testing.expect_value(t, len(p.lines), 0)
	testing.expect_value(t, len(p.code), 0)
}

@(test)
instruction_pass_decode_fixture_test :: proc(t: ^testing.T) {
	// A whole program with no labels or aliases in it, encoded byte for byte.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, DECODE_ASM)
	pipe_labels(&p)
	pipe_encode(&p)

	testing.expect(t, p.label_ok, "decode fixture: label pass failed")
	expect_words(
		t,
		p.code,
		[]u16 {
			0x3000, // xor  a a
			0x7003, // addi a 3
			0x3101, // xor  b b
			0x7104, // addi b 4
			0x0001, // add  a b
			0x3101, // xor  b b
			0x7102, // addi b 2
			0x1001, // mul  a b
			0x8001, // subi a 1
			0xF800, // halt
		},
	)
}

@(test)
instruction_pass_whole_chain_test :: proc(t: ^testing.T) {
	// All four passes, over a program with a label, a call and a ret in it.
	// This is the only test that pins the bytes an alias actually turns into.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, ALIAS_ASM)
	pipe_labels(&p)
	pipe_alias(&p)
	pipe_encode(&p)

	testing.expect(t, p.label_ok, "whole chain: label pass failed")
	testing.expect(t, p.alias_ok, "whole chain: alias pass failed")

	expect_words(
		t,
		p.code,
		[]u16 {
			// the prelude
			0x68EF, // movi a 0xef
			0xE000, // push a
			0x68BE, // movi a 0xbe
			0xE000, // push a
			0x68AD, // movi a 0xad
			0xE000, // push a
			0x68DE, // movi a 0xde
			0xE000, // push a
			// call helper, which label_pass resolved to 0x0022
			0x6A00, // movi fp 0
			0x0205, // add  fp pc     <- pc reads as the instruction after this
			0x720C, // addi fp 12     <- CALL_SKIP, past the rest of the expansion
			0xE200, // push fp        <- the return address
			0x6A00, // movi fp 0x00   <- high byte of the target
			0x9A08, // slli fp 8
			0x7222, // addi fp 0x22   <- low byte of the target
			0xF000, // jmpf
			0xF800, // halt
			// helper
			0x6880, // movi a 0x80
			0x69FE, // movi b 0xfe
			0x5900, // st   b a
			0x7001, // addi a 1
			0x69ED, // movi b 0xed
			0x5900, // st   b a
			0x7001, // addi a 1
			0x69BE, // movi b 0xbe
			0x5900, // st   b a
			0x7001, // addi a 1
			0x69EF, // movi b 0xef
			0x5900, // st   b a
			// ret
			0xEA00, // pop  fp
			0xF000, // jmpf
		},
	)

	// The byte count has to match what label_pass reserved for the aliases, or
	// helper's recorded address of 0x0022 points into the middle of the call.
	testing.expect_value(t, len(p.code), 31 * assembler.INST_SZ)
	testing.expect_value(t, p.code[0x22], u8(0x80)) // low byte of movi a 0x80
	testing.expect_value(t, p.code[0x23], u8(0x68))
}

@(test)
instruction_pass_uppercases_mnemonics_test :: proc(t: ^testing.T) {
	// The opcode is looked up by reflecting over hw.Op, whose members are
	// uppercase, so the encoder uppercases the mnemonic to match -- in place,
	// in the source buffer the tokens point into. That is a visible side effect
	// and worth pinning: it means the pass is not repeatable on the same lines,
	// since a second run would no longer find the now-uppercase mnemonic in
	// INST_DATA.
	p: Pipeline
	defer pipe_destroy(&p)

	pipe_text(&p, "movi a 0\nhalt\n")
	pipe_encode(&p)

	expect_words(t, p.code, []u16{0x6800, 0xF800})
	testing.expect_value(t, string(p.src), "movi a 0\nhalt\n")
}
