package main

import "debug"
import hw "hardware"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import rl "vendor:raylib"

BYTES_PER_ROW :: 8
term_w: i32 = 768
term_h: i32 = 432
term_x: i32 = 256
term_y: i32 = 36
term_roundedness: f32 = 0.08
term_bg: rl.Color = {0, 0, 0, 255}
term := rl.Rectangle{f32(term_x), f32(term_y), f32(term_w), f32(term_h)}

machine: hw.Machine


ScrollList :: struct {
	rect:      rl.Rectangle,
	scroll:    f32, // pixel offset from top of content
	selected:  int,
	row_h:     f32,
	font_size: f32, // kept separate from row_h so the face can be drawn at the
	goto_addr: bool, // rows map to addresses, so <C-x> can jump to one
}

Pane :: enum {
	Terminal,
	Memory,
	Registers,
	Stack,
}

pane_switch :: proc(focus: ^Pane) -> bool {
	if !ctrl_held() {
		return false
	}
	before := focus^
	if rl.IsKeyPressed(.UP) {
		focus^ = .Terminal
	}
	if rl.IsKeyPressed(.DOWN) {
		focus^ = .Memory
	}
	if rl.IsKeyPressed(.LEFT) {
		focus^ = .Registers
	}
	if rl.IsKeyPressed(.RIGHT) {
		focus^ = .Stack
	}
	return focus^ != before
}

MONO_FONT_PATHS :: [?]cstring {
	"/usr/local/share/fonts/fonts/ttf/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
	"/usr/share/fonts/liberation-fonts/LiberationMono-Regular.ttf",
}

MEM_FONT_SIZE :: 16

// Outline on whichever pane has the keyboard.
FOCUS_RING :: rl.Color{240, 200, 110, 255}

load_mono_font :: proc(size: i32) -> (font: rl.Font, loaded: bool) {
	for path in MONO_FONT_PATHS {
		if !rl.FileExists(path) {
			continue
		}
		f := rl.LoadFontEx(path, size, nil, 0)
		if rl.IsFontValid(f) {
			debug.logf("font: %s at %dpx", path, size)
			return f, true
		}
		rl.UnloadFont(f)
	}
	debug.log("font: no monospace face found, using the built-in one")
	return rl.GetFontDefault(), false
}

// True on the initial press and on each auto-repeat while the key is held.
key_step :: proc(key: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}

ctrl_held :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

is_hex :: proc(c: rune) -> bool {
	return(
		(c >= '0' && c <= '9') ||
		(c >= 'a' && c <= 'f') ||
		(c >= 'A' && c <= 'F') \
	)
}

InputMode :: enum {
	Normal, // j/k and the arrows move the selection
	Goto, // every keystroke is address text until Enter or Escape
}

Input :: struct {
	mode: InputMode,
	buf:  [4]u8, // hex digits typed so far; 4 covers the whole 16-bit space
	len:  int,
}

list_input :: proc(s: ^ScrollList, cmd: ^Input, count: int) -> (addr: int, ok: bool) {
	switch cmd.mode {
	case .Normal:
		if ctrl_held() {
			if s.goto_addr && rl.IsKeyPressed(.X) {
				cmd.mode = .Goto
				cmd.len = 0
				for rl.GetCharPressed() != 0 {
				}
			}
			return -1, false
		}

		if key_step(.DOWN) || key_step(.J) {
			s.selected = min(s.selected + 1, count - 1)
		}
		if key_step(.UP) || key_step(.K) {
			s.selected = max(s.selected - 1, 0)
		}

	case .Goto:
		// drain the queue: several keys can land in one frame
		for {
			c := rl.GetCharPressed()
			if c == 0 {
				break
			}
			if is_hex(c) && cmd.len < len(cmd.buf) {
				cmd.buf[cmd.len] = u8(c)
				cmd.len += 1
			}
		}

		if key_step(.BACKSPACE) && cmd.len > 0 {
			cmd.len -= 1
		}
		if rl.IsKeyPressed(.ESCAPE) {
			cmd.mode = .Normal
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			cmd.mode = .Normal
			// an empty prompt is a cancel, not a jump to 0
			if cmd.len > 0 {
				if a, pok := strconv.parse_int(string(cmd.buf[:cmd.len]), 16); pok {
					return a, true
				}
			}
		}
	}
	return -1, false
}

// returns true if selection changed
list_update_draw :: proc(
	s: ^ScrollList,
	cmd: ^Input,
	count: int,
	font: rl.Font,
	label: proc(i: int) -> cstring,
	focused: bool,
	empty: cstring = "(empty)",
) -> bool {
	content_h := f32(count) * s.row_h
	max_scroll := max(0, content_h - s.rect.height)
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, s.rect)
	changed := false

	if hovered {
		s.scroll -= rl.GetMouseWheelMove() * s.row_h * 3
	}
	s.scroll = clamp(s.scroll, 0, max_scroll)

	// The row count moves under the selection: the stack grows and shrinks as
	// a program runs, so an index that was valid last frame can be past the end
	// of the list by this one. Re-clamping here covers every path into the
	// list, rather than each place the selection is set.
	s.selected = clamp(s.selected, 0, max(0, count - 1))

	before := s.selected
	if focused && count > 0 {
		if addr, ok := list_input(s, cmd, count); ok {
			s.selected = clamp(addr / BYTES_PER_ROW, 0, count - 1)
		}
	}
	changed = s.selected != before

	sel_y := f32(s.selected) * s.row_h
	if sel_y < s.scroll {
		s.scroll = sel_y
	}
	if sel_y + s.row_h > s.scroll + s.rect.height {
		s.scroll = sel_y + s.row_h - s.rect.height
	}

	if hovered && rl.IsMouseButtonPressed(.LEFT) {
		i := int((mouse.y - s.rect.y + s.scroll) / s.row_h)
		if i >= 0 && i < count {
			s.selected = i
			changed = true
		}
	}

	rl.DrawRectangleRec(s.rect, rl.Color{20, 20, 24, 255})

	rl.BeginScissorMode(i32(s.rect.x), i32(s.rect.y), i32(s.rect.width), i32(s.rect.height))

	first := max(0, int(s.scroll / s.row_h))
	last := min(count, first + int(s.rect.height / s.row_h) + 2)

	if count <= 0 {
		rl.DrawTextEx(
			font,
			empty,
			rl.Vector2{s.rect.x + 6, s.rect.y + (s.row_h - s.font_size) * 0.5},
			s.font_size,
			1,
			rl.Color{120, 120, 130, 255},
		)
	}

	for i in first ..< last {
		y := s.rect.y + f32(i) * s.row_h - s.scroll

		if i == s.selected {
			sel_bg :=
				focused ? rl.Color{50, 60, 90, 255} : rl.Color{34, 36, 44, 255}
			rl.DrawRectangleRec(rl.Rectangle{s.rect.x, y, s.rect.width, s.row_h}, sel_bg)
		}

		text_y := y + (s.row_h - s.font_size) * 0.5
		rl.DrawTextEx(
			font,
			label(i),
			rl.Vector2{s.rect.x + 6, text_y},
			s.font_size,
			1,
			rl.RAYWHITE,
		)
	}

	rl.EndScissorMode()

	// scrollbar
	if content_h > s.rect.height {
		track_w := f32(8)
		track_x := s.rect.x + s.rect.width - track_w
		thumb_h := s.rect.height * (s.rect.height / content_h)
		thumb_y := s.rect.y + (s.scroll / max_scroll) * (s.rect.height - thumb_h)
		rl.DrawRectangleRec(
			rl.Rectangle{track_x, s.rect.y, track_w, s.rect.height},
			rl.Color{30, 30, 36, 255},
		)
		rl.DrawRectangleRec(
			rl.Rectangle{track_x, thumb_y, track_w, thumb_h},
			rl.Color{90, 90, 100, 255},
		)
	}

	if focused {
		rl.DrawRectangleLinesEx(s.rect, 2, FOCUS_RING)
	}

	if cmd.mode == .Goto {
		bar_h := s.row_h + 4
		bar := rl.Rectangle{s.rect.x, s.rect.y + s.rect.height - bar_h, s.rect.width, bar_h}
		rl.DrawRectangleRec(bar, rl.Color{40, 40, 52, 255})
		rl.DrawTextEx(
			font,
			fmt.ctprintf("goto 0x%s_", string(cmd.buf[:cmd.len])),
			rl.Vector2{bar.x + 6, bar.y + (bar_h - s.font_size) * 0.5},
			s.font_size,
			1,
			rl.Color{240, 200, 110, 255},
		)
	}

	return changed
}

/*
* Program loading and the fetch-execute loop.
*
* exec_inst never touches pc on its own, so the fetch is what advances it, and
* it does so before the instruction runs. That ordering is load-bearing: jumps
* are relative, and the offset they add is measured from the instruction after
* the jump, which is exactly what pc holds by then. The assembler computes its
* offsets against the same rule.
*/

// Instructions per frame while a program runs. The machine is driven from the
// draw loop, so this is the whole cycle budget between two frames: high enough
// that a real program finishes promptly, low enough that a runaway loop still
// leaves the window responsive.
CYCLES_PER_FRAME :: 4096

// Status text lives in a fixed global buffer rather than being printed into the
// temp allocator: the message has to survive from the frame that produced it
// until the next one replaces it, and temp memory is freed at every frame end.
status_buf: [128]u8
status: string

set_status :: proc(format: string, args: ..any) {
	status = fmt.bprintf(status_buf[:], format, ..args)
}

// A one-line text prompt, drawn over the terminal pane. Unlike the memory
// pane's Goto prompt this takes any printable character, since it collects a
// file path rather than hex digits.
Prompt :: struct {
	active: bool,
	label:  string,
	buf:    [256]u8,
	len:    int,
}

prompt_open :: proc(p: ^Prompt, label: string) {
	p.active = true
	p.label = label
	p.len = 0
	// The chord's own key is already in the character queue; drop it so it does
	// not land in the buffer as the first character typed.
	for rl.GetCharPressed() != 0 {
	}
}

// Returns the entered text on Enter. The text aliases p.buf, so it is only
// valid until the next prompt is opened -- consume it in the calling frame.
prompt_input :: proc(p: ^Prompt) -> (text: string, ok: bool) {
	for {
		c := rl.GetCharPressed()
		if c == 0 {
			break
		}
		if c >= ' ' && c <= '~' && p.len < len(p.buf) {
			p.buf[p.len] = u8(c)
			p.len += 1
		}
	}

	if key_step(.BACKSPACE) && p.len > 0 {
		p.len -= 1
	}
	if rl.IsKeyPressed(.ESCAPE) {
		p.active = false
		p.len = 0
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		p.active = false
		n := p.len
		p.len = 0
		// an empty prompt is a cancel
		if n > 0 {
			return string(p.buf[:n]), true
		}
	}
	return "", false
}

// Wipes the machine and copies the file in at address 0. The reset is part of
// loading: a program is assembled expecting a fresh stack pointer and cleared
// memory, so leaving the previous run's state behind would make a load
// depend on whatever ran before it.
load_program :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != os.ERROR_NONE {
		set_status("load: %s: %v", path, err)
		return false
	}
	if len(data) > hw.MEM_SIZE {
		set_status("load: %s is %d bytes, memory holds %d", path, len(data), hw.MEM_SIZE)
		return false
	}

	hw.machine_init(&machine)
	copy(machine.memory[:], data)
	set_status("load: %s, %d bytes at 0x0000", path, len(data))
	return true
}

/*
* Decodes the instruction pc points at without running it.
*
* This is what a step is about to execute, which is the one thing worth looking
* at while stepping: by the time step returns, pc has already moved past it.
*/
peek :: proc(m: ^hw.Machine) -> (op: hw.Op, inst: u16, ok: bool) {
	at := m.regs.pc
	if int(at) + 1 >= hw.MEM_SIZE {
		return .HALT, 0, false
	}

	inst = u16(m.memory[at]) | u16(m.memory[at + 1]) << 8
	return hw.Op(inst >> 11), inst, true
}

// One fetch-execute cycle. Instructions are 16 bits, little-endian, matching
// what the assembler writes out. pc is advanced before the instruction runs,
// which is the base every relative jump is measured from.
//
// running is false once the machine has stopped: on HALT, or when pc has walked
// off the end of the address space with no room left for a whole instruction.
//
// `at` is the address the instruction was fetched from, reported back because pc
// no longer points at it by the time this returns -- HALT in particular parks pc
// at the top of memory, which says nothing about where the program stopped.
step :: proc(m: ^hw.Machine) -> (op: hw.Op, at: u16, running: bool) {
	at = m.regs.pc
	if int(at) + 1 >= hw.MEM_SIZE {
		return .HALT, at, false
	}

	inst := u16(m.memory[at]) | u16(m.memory[at + 1]) << 8
	m.regs.pc = at + 2

	op = hw.exec_inst(m, inst)
	return op, at, op != .HALT
}

mem_row :: proc(i: int) -> cstring {
	base := i * BYTES_PER_ROW
	return fmt.ctprintf(
		"%04X: %02X %02X %02X %02X %02X %02X %02X %02X",
		u16(base),
		machine.memory[base + 0],
		machine.memory[base + 1],
		machine.memory[base + 2],
		machine.memory[base + 3],
		machine.memory[base + 4],
		machine.memory[base + 5],
		machine.memory[base + 6],
		machine.memory[base + 7],
	)
}

REG_ROWS :: 6

reg_row :: proc(i: int) -> cstring {
	r := machine.regs
	switch i {
	case 0:
		return fmt.ctprintf("a       0x%02X", r.a)
	case 1:
		return fmt.ctprintf("b       0x%02X", r.b)
	case 2:
		return fmt.ctprintf("sp      0x%04X", r.sp)
	case 3:
		return fmt.ctprintf("fp      0x%04X", r.fp)
	case 4:
		return fmt.ctprintf("pc      0x%04X", r.pc)
	case 5:
		f := r.flags
		return fmt.ctprintf(
			"flags   0x%02X  %c%c%c%c",
			f,
			f & u8(hw.S.carry) != 0 ? 'C' : '-',
			f & u8(hw.S.zero) != 0 ? 'Z' : '-',
			f & u8(hw.S.of) != 0 ? 'O' : '-',
			f & u8(hw.S.n) != 0 ? 'N' : '-',
		)
	}
	return ""
}

/*
* The stack view.
*
* The stack grows downward from STACK_BASE, and push writes at sp after
* decrementing it, so the live bytes are the ones from sp up to STACK_BASE - 1
* and the depth is the distance between the two. An untouched machine has
* sp == STACK_BASE and so shows nothing, which is the honest answer: the byte
* at sp has not been pushed yet.
*
* Row 0 is the top of the stack. Reading downward is then reading back in time,
* the most recent push first, which is the order a return address or a saved
* register is actually looked for.
*/
stack_depth :: proc() -> int {
	// Clamped, because nothing stops a program from setting sp above the base:
	// sp is writable like any other register, and STACK_BASE is a convention
	// machine_init starts it at rather than a limit the hardware enforces. An
	// sp past the base means nothing has been pushed below it, which reads as
	// an empty stack -- a raw subtraction would go negative and silently draw
	// no rows at all.
	return max(0, int(hw.STACK_BASE) - int(machine.regs.sp))
}

stack_row :: proc(i: int) -> cstring {
	addr := int(machine.regs.sp) + i
	if addr >= hw.MEM_SIZE {
		return ""
	}
	// The arrow marks where sp points, so the top is findable at a glance once
	// the list has been scrolled away from it.
	return fmt.ctprintf(
		"%s %04X: %02X",
		i == 0 ? "->" : "  ",
		u16(addr),
		machine.memory[addr],
	)
}

main :: proc() {
	// The hardware reports through context.logger, so give it somewhere to go.
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	hw.machine_init(&machine)
	debug.log("machine initialized")

	debug.log("initializing window")
	win_width: i32 = 1280
	win_height: i32 = 720

	rl.InitWindow(win_width, win_height, "MO-8")
	rl.SetTargetFPS(60)
	debug.log("done initializing window")

	mem_view := ScrollList {
		rect      = rl.Rectangle{f32(term_x), f32(term_y + term_h) + 12, f32(term_w), 220},
		row_h     = 20,
		font_size = MEM_FONT_SIZE,
		goto_addr = true, // rows are addresses here, so <C-x> means something
	}
	mem_rows := hw.MEM_SIZE / BYTES_PER_ROW
	mem_cmd: Input

	reg_view := ScrollList {
		rect      = rl.Rectangle {
			8,
			f32(term_y),
			f32(term_x) - 16,
			f32(REG_ROWS) * 20 + 8,
		},
		row_h     = 20,
		font_size = MEM_FONT_SIZE,
	}
	reg_cmd: Input

	// Fills the column to the right of the terminal, running the full height of
	// the terminal and memory panes together. Sized off mem_view rather than
	// off the same numbers again, so moving that pane carries this one with it.
	stack_view := ScrollList {
		rect      = rl.Rectangle {
			f32(term_x + term_w) + 12,
			f32(term_y),
			f32(win_width - term_x - term_w - 20),
			mem_view.rect.y + mem_view.rect.height - f32(term_y),
		},
		row_h     = 20,
		font_size = MEM_FONT_SIZE,
	}
	stack_cmd: Input

	focus := Pane.Memory

	prompt: Prompt
	running := false
	// Free-running and stepping are the same machine driven at two speeds, and
	// never both at once: whichever is turned on turns the other off.
	stepping := false
	set_status("<C-l> load   <C-r> run   <C-d> step   <C-k> kill")

	font, font_loaded := load_mono_font(MEM_FONT_SIZE)
	defer if font_loaded {
		rl.UnloadFont(font)
	}

	// MAIN LOOP
	for rl.WindowShouldClose() == false {
		rl.BeginDrawing()
		rl.ClearBackground(rl.RAYWHITE)

		// Machine commands are read before anything else: while a pane is
		// collecting an address, or the load prompt is open, every keystroke
		// belongs to that prompt and a chord must not be pulled out from under
		// it.
		typing := prompt.active || mem_cmd.mode == .Goto || reg_cmd.mode == .Goto
		if !typing && ctrl_held() {
			if rl.IsKeyPressed(.L) {
				running = false
				stepping = false
				prompt_open(&prompt, "load")
			}
			if rl.IsKeyPressed(.R) {
				machine.regs.pc = 0
				running = true
				stepping = false
				set_status("run: from 0x0000")
			}
			// Stepping picks up wherever pc already is rather than resetting
			// it, which is what makes it compose with the other two: <C-l>
			// leaves pc at 0 so a fresh program steps from the top, and <C-k>
			// leaves it mid-program so a runaway can be stopped and then walked
			// through from the instruction it died on.
			if rl.IsKeyPressed(.D) {
				stepping = !stepping
				running = false
				set_status(
					stepping \
					? "step: <space> runs one instruction" \
					: "step: off",
				)
			}
			// A kill leaves the machine exactly where it stopped rather than
			// resetting it, so the panes can be walked over the state the
			// program was in at the moment it was interrupted. <C-r> is what
			// starts over.
			if rl.IsKeyPressed(.K) && (running || stepping) {
				running = false
				stepping = false
				set_status("killed at 0x%04X", machine.regs.pc)
			}
		}

		if prompt.active {
			if path, entered := prompt_input(&prompt); entered {
				load_program(path)
			}
		} else if pane_switch(&focus) {
			mem_cmd = Input{}
			reg_cmd = Input{}
			stack_cmd = Input{}
		}

		// The machine runs on the frame's own budget, so a program that never
		// halts costs frames rather than locking the window up.
		if running {
			for _ in 0 ..< CYCLES_PER_FRAME {
				op, at, still := step(&machine)
				if !still {
					running = false
					set_status("halted: %v at 0x%04X", op, at)
					break
				}
			}
		}

		// One instruction per press, and one per auto-repeat while space is
		// held, so a long stretch can be walked through by leaning on the key.
		// The panes stay live throughout: the point of stepping is to read the
		// registers, memory and stack between one instruction and the next.
		if stepping && !typing && key_step(.SPACE) {
			op, at, still := step(&machine)
			if still {
				set_status("step: %v at 0x%04X", op, at)
			} else {
				stepping = false
				set_status("halted: %v at 0x%04X", op, at)
			}
		}

		rl.DrawRectangleRounded(term, term_roundedness, 1, term_bg)

		if focus == .Terminal {
			rl.DrawRectangleRoundedLines(term, term_roundedness, 1, FOCUS_RING)
		}

		mode := running ? "running | " : stepping ? "step | " : ""
		term_line := prompt.active \
			? fmt.ctprintf("%s: %s_", prompt.label, string(prompt.buf[:prompt.len])) \
			: fmt.ctprintf("%s%s", mode, status)
		term_bottom := term.y + term.height - MEM_FONT_SIZE - 10
		rl.DrawTextEx(
			font,
			term_line,
			rl.Vector2{term.x + 10, term_bottom},
			MEM_FONT_SIZE,
			1,
			prompt.active ? rl.Color{240, 200, 110, 255} : rl.RAYWHITE,
		)

		// The instruction a press of space would run, on the line above the
		// status. The status says what the last step did, so the two together
		// read as one line back and one line forward.
		if stepping && !prompt.active {
			next_op, next_inst, next_ok := peek(&machine)
			next_line :=
				next_ok \
				? fmt.ctprintf(
					"next  %04X: %04X  %v",
					machine.regs.pc,
					next_inst,
					next_op,
				) \
				: fmt.ctprintf("next  %04X: past the end of memory", machine.regs.pc)
			rl.DrawTextEx(
				font,
				next_line,
				rl.Vector2{term.x + 10, term_bottom - MEM_FONT_SIZE - 6},
				MEM_FONT_SIZE,
				1,
				FOCUS_RING,
			)
		}

		// A running machine owns the keyboard through the chords above; the
		// panes keep drawing but stop taking input, so j/k cannot fight the
		// program for it.
		pane_live := !prompt.active && !running
		list_update_draw(
			&mem_view,
			&mem_cmd,
			mem_rows,
			font,
			mem_row,
			pane_live && focus == .Memory,
		)
		list_update_draw(
			&reg_view,
			&reg_cmd,
			REG_ROWS,
			font,
			reg_row,
			pane_live && focus == .Registers,
		)
		list_update_draw(
			&stack_view,
			&stack_cmd,
			stack_depth(),
			font,
			stack_row,
			pane_live && focus == .Stack,
			"(stack empty)",
		)

		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}
