/*
* Debug-only pretty printers for the assembler's intermediate representation.
*
* These live in package assembler (rather than in package debug) because they
* need access to Line/Inst, and a separate package that imported assembler
* would create an import cycle. Keeping them in their own *file* is what makes
* the split visible: assembler.odin is the product, debug.odin is the scaffold.
*
* Every proc here has an empty counterpart for release builds, so call sites
* stay clean and the whole file costs nothing when DEBUG is off.
*/
package assembler

import "../debug"
import "core:fmt"

// column that the per-line instruction metadata is padded out to
TOK_COLUMN :: 30

when debug.ENABLED {
	/*
	* Returns the colour a given instruction type is rendered in
	*/
	inst_type_color :: proc(t: INST_TYPES) -> string {
		switch t {
		case .ALIAS:
			return debug.MAGENTA
		case .IMM:
			return debug.YELLOW
		case .ADDR:
			return debug.BLUE
		case .REGREG, .REG:
			return debug.GREEN
		case .JMP_LABEL:
			return debug.CYAN
		case .NONE:
			return debug.GREY
		}
		return debug.RESET
	}

	/*
	* Returns the colour a single token is rendered in, based on its role
	*/
	tok_color :: proc(tok: string, is_mnemonic: bool) -> string {
		if len(tok) == 0 {
			return debug.RESET
		}
		if tok[len(tok) - 1] == ':' {
			return debug.MAGENTA // label definition, checked before the
			// mnemonic slot so a label line is not painted as an opcode
		}
		if is_mnemonic {
			return debug.BOLD_CYAN
		}
		if _, ok := REG_SRC(tok); ok {
			return debug.GREEN // register
		}
		if tok[0] == '-' || tok[0] == '$' || ('0' <= tok[0] && tok[0] <= '9') {
			return debug.YELLOW // numeric literal
		}
		return debug.RESET // label reference / unknown
	}

	/*
	* Prints a line with all of its metadata
	*/
	debug_print_line :: proc(l: Line) {
		// 1. print line number
		fmt.eprintf(
			"%s%4d%s %s|%s ",
			debug.GREY,
			l.lineno,
			debug.RESET,
			debug.DIM,
			debug.RESET,
		)

		// 2. print line tokens, coloured by role. ntoks is the number of
		// tokens actually in use, which may be short of len(toks).
		width := 0
		for tok, i in l.toks[:min(l.ntoks, len(l.toks))] {
			fmt.eprintf("%s%s%s ", tok_color(tok, i == 0), tok, debug.RESET)
			width += len(tok) + 1
		}

		// 3. pad so that the metadata lines up into a column
		for _ in width ..< TOK_COLUMN {
			fmt.eprint(" ")
		}

		// 4. print instruction info. Line no longer carries its Inst, so it is
		// looked up from the mnemonic in toks[0].
		fmt.eprintf("%s#%s ", debug.DIM, debug.RESET)

		if l.ntoks == 0 || len(l.toks) == 0 {
			fmt.eprintf("%s<empty>%s\n", debug.GREY, debug.RESET)
			return
		}

		// label definitions survive tokenizing, so they are not errors
		if l.toks[0][len(l.toks[0]) - 1] == ':' {
			fmt.eprintf("%slabel%s\n", debug.MAGENTA, debug.RESET)
			return
		}

		inst, ok := GET_INST_DATA(l.toks[0])
		if !ok {
			// unknown mnemonic: say so rather than print a zeroed Inst, whose
			// empty name and .ALIAS type (enum value 0) would read as real data
			fmt.eprintf("%sunknown mnemonic%s\n", debug.RED, debug.RESET)
			return
		}

		fmt.eprintf("%s%-6s%s", debug.BOLD_CYAN, inst.name, debug.RESET)
		fmt.eprintf("%s| %s", debug.DIM, debug.RESET)
		fmt.eprintf("%s%-6v%s", inst_type_color(inst.type), inst.type, debug.RESET)
		fmt.eprintf("%s| %s", debug.DIM, debug.RESET)
		fmt.eprintf("%s%d op%s", debug.GREY, inst.n_operands, debug.RESET)

		// flag a token count that disagrees with the instruction's arity
		if l.ntoks - 1 != inst.n_operands {
			fmt.eprintf(" %s(got %d)%s", debug.RED, l.ntoks - 1, debug.RESET)
		}
		fmt.eprint("\n")
	}

	/*
	* Prints every parsed line, under a heading
	*/
	debug_print_lines :: proc(lines: []Line) {
		debug.logf("%d parsed lines:", len(lines))
		for l in lines {
			debug_print_line(l)
		}
	}

	/*
	* Prints the label table gathered by label_pass1
	*/
	debug_print_labels :: proc(labels: map[string]string) {
		debug.logf("%d labels:", len(labels))
		for name, addr in labels {
			fmt.eprintf(
				"     %s%-16s%s %s->%s %s%s%s\n",
				debug.MAGENTA,
				name,
				debug.RESET,
				debug.DIM,
				debug.RESET,
				debug.YELLOW,
				addr,
				debug.RESET,
			)
		}
	}
} else {
	debug_print_line :: proc(l: Line) {}
	debug_print_lines :: proc(lines: []Line) {}
	debug_print_labels :: proc(labels: map[string]string) {}
}
