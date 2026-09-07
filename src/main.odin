package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "debug"
import hw "hardware"
import rl "vendor:raylib"


machine: hw.Machine

// Window Constants
PANE_PAD :: 5
WIN_W :: 1280
WIN_H :: 720

// Terminal Screen Constants
TERM_W :: 768
TERM_H :: 432
TERM_X :: 256
TERM_Y :: 36
TERM_ROUNDEDNESS :: 0.08
TERM_BG: rl.Color : rl.BLACK
TERM_BORDER_COLOR :: rl.GRAY
TERM_TEXT_COLOR :: rl.BLACK
TERM_FONT_SIZE :: 16

// Memory Pane Constants
MEM_PANE_X :: TERM_X
MEM_PANE_Y :: TERM_Y + TERM_H + 5
MEM_PANE_H :: 240
MEM_PANE_W :: TERM_W
MEM_PANE_BG_COLOR: rl.Color : {15, 15, 15, 255}
MEM_PANE_BORDER_COLOR :: rl.GRAY
MEM_SELECTION_BG_COLOR: rl.Color : {50, 60, 90, 255}
MEM_FONT_SIZE :: 16
BYTES_PER_ROW :: 8
MEM_NUM_ROWS :: (MEM_PANE_H - MEM_FONT_SIZE) / MEM_FONT_SIZE
MAX_MEM_ROWS :: hw.MEM_SIZE / BYTES_PER_ROW
MEM_TEXT_COLOR :: rl.RAYWHITE

// Stack Pane Constants
STACK_PANE_BG_COLOR: rl.Color : {15, 15, 15, 255}
STACK_SELECTION_BG_COLOR: rl.Color : {50, 60, 90, 255}
STACK_FONT_SIZE :: 18
STACK_PANE_X :: TERM_X + TERM_W + 10
STACK_PANE_Y :: TERM_Y
STACK_PANE_H :: TERM_H + 5 + MEM_PANE_H
STACK_PANE_W :: ((WIN_W - TERM_W) / 2) - 20
STACK_PANE_BORDER_COLOR :: rl.GRAY
STACK_MAX_ROWS :: (STACK_PANE_H - STACK_FONT_SIZE) / STACK_FONT_SIZE
STACK_BOTTOM :: ((hw.MEM_SIZE / BYTES_PER_ROW) - 15)
STACK_TEXT_COLOR :: rl.RAYWHITE

// Register Pane Constants
REG_ROWS :: 7
REG_FONT_SIZE :: 16
REG_PANE_X :: PANE_PAD * 2
REG_PANE_Y :: TERM_Y
REG_PANE_W :: TERM_X - (REG_PANE_X * 2)
REG_PANE_H :: (REG_ROWS * REG_FONT_SIZE) + (PANE_PAD * 2)
REG_PANE_BG_COLOR: rl.Color : {15, 15, 15, 255}
REG_PANE_BORDER_COLOR :: rl.GRAY
REG_TEXT_COLOR :: rl.RAYWHITE

// Keybind Pane Constants
KEY_FONT_SIZE :: 14
KEY_PANE_X :: REG_PANE_X
KEY_PANE_Y :: REG_PANE_Y + REG_PANE_H + (PANE_PAD * 2)
KEY_PANE_W :: REG_PANE_W
KEY_PANE_BG_COLOR: rl.Color : {15, 15, 15, 255}
KEY_PANE_BORDER_COLOR :: rl.GRAY
KEY_TEXT_COLOR :: rl.RAYWHITE

keybinds := [?]cstring{
	"-- KEYBINDS --",
	"",
	"C-h    focus regs",
	"C-j    focus memory",
	"C-k    focus terminal",
	"C-l    focus stack",
	"",
	"C-r    run",
	"C-d    debug",
	"C-x    kill",
	"C-e    reload",
	"space  step (debug)",
	"",
	"j / k  scroll pane",
}
KEY_ROWS :: i32(len(keybinds))
KEY_PANE_H :: (KEY_ROWS * KEY_FONT_SIZE) + (PANE_PAD * 2)

// Status Pane Constants
STATUS_W :: TERM_W
STATUS_H :: 20
STATUS_X :: TERM_X
STATUS_Y :: TERM_Y + TERM_H - STATUS_H
STATUS_BG: rl.Color : TERM_BG
STATUS_BORDER_COLOR :: 0
STATUS_TEXT_COLOR :: rl.RAYWHITE
STATUS_FONT_SIZE :: 16


status_buf: [128]u8
status: string

Mode :: enum {
	idle,
	running,
	debug,
	halted,
}

mode: Mode = .idle

prog_path := "o.out"

mode_label :: proc(m: Mode) -> string {
	switch m {
	case .idle:
		return "IDLE"
	case .running:
		return "RUNNING"
	case .debug:
		return "DEBUG"
	case .halted:
		return "HALTED"
	}
	return "?"
}

CYCLES_PER_FRAME :: 1
// Outline on whichever pane has the keyboard.
FOCUS_RING :: rl.Color{240, 200, 110, 255}

MONO_FONT_PATHS :: [?]cstring {
	"/usr/local/share/fonts/fonts/ttf/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
	"/usr/share/fonts/liberation-fonts/LiberationMono-Regular.ttf",
}

BUFFER_TYPE :: enum {
	msg,
	prompt,
	screen_display,
}

Buffer :: struct {
	type:         BUFFER_TYPE,
	x:            i32,
	y:            i32,
	width:        i32,
	height:       i32,
	font_size:    i32,
	bg_color:     rl.Color,
	border_color: rl.Color,
}

PaneBase :: struct {
	x, y, width, height: i32,
	bg_color:            rl.Color,
	border_color:        rl.Color,
	sel_color:           rl.Color,
	text_color:          rl.Color,
	font_size:           i32,
	num_rows:            i32,
	row:                 proc(i: i32, allocator: runtime.Allocator) -> cstring,
}

Pane :: struct {
	using base:  PaneBase,
	key_handler: proc(pane: ^Pane),
}

ScrollPane :: struct {
	using base:  PaneBase,
	top:         i32,
	selection:   i32,
	key_handler: proc(pane: ^ScrollPane),
}

AnyPane :: union {
	^Pane,
	^ScrollPane,
}

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

// Glyphs are rasterized into a bitmap atlas at one fixed size, and DrawTextEx
// scales that bitmap rather than re-rasterizing. Drawing at any size other than
// the baked one warps the stems, so every size in use gets its own atlas.
CachedFont :: struct {
	font:   rl.Font,
	loaded: bool,
}

font_cache: map[i32]CachedFont

get_font :: proc(size: i32) -> rl.Font {
	if cf, ok := font_cache[size]; ok {
		return cf.font
	}
	f, loaded := load_mono_font(size)
	font_cache[size] = CachedFont{f, loaded}
	return f
}

font_cache_destroy :: proc() {
	for _, cf in font_cache {
		if cf.loaded {
			rl.UnloadFont(cf.font)
		}
	}
	delete(font_cache)
}

set_status :: proc(format: string, args: ..any) {
	status = fmt.bprintf(status_buf[:], format, ..args)
}

get_status :: proc(_: i32, allocator: runtime.Allocator) -> cstring {
	return fmt.ctprintf("[%s]  %s", mode_label(mode), status)
}

ctrl_held :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

mem_row :: proc(i: i32, allocator := context.allocator) -> cstring {
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

reg_row :: proc(i: i32, allocator: runtime.Allocator) -> cstring {
	r := machine.regs
	switch i {
	case 0:
		return fmt.ctprintf("a       0x%02X", r.a)
	case 1:
		return fmt.ctprintf("b       0x%02X", r.b)
	case 2:
		return fmt.ctprintf("x       0x%04X", r.x)
	case 3:
		return fmt.ctprintf("sp      0x%04X", r.sp)
	case 4:
		return fmt.ctprintf("fp      0x%04X", r.fp)
	case 5:
		return fmt.ctprintf("pc      0x%04X", r.pc)
	case 6:
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

keybind_row :: proc(i: i32, allocator: runtime.Allocator) -> cstring {
	if i < 0 || i >= KEY_ROWS {
		return ""
	}
	return keybinds[i]
}

stack_depth :: proc() -> i32 {
	return i32(hw.STACK_BASE) - i32(machine.regs.sp)
}

stack_row :: proc(i: i32, allocator: runtime.Allocator) -> cstring {
	addr := i32(machine.regs.sp) + i
	if addr < 0 || addr >= hw.STACK_BASE {
		return ""
	}
	return fmt.ctprintf("%s %04X: %02X", i == 0 ? "->" : "  ", u16(addr), machine.memory[addr])
}

sync_stack_pane :: proc(pane: ^ScrollPane) {
	depth := stack_depth()
	max_top := max(depth - STACK_MAX_ROWS, 0)
	pane.top = clamp(pane.top, 0, max_top)
	pane.num_rows = clamp(depth - pane.top, 0, STACK_MAX_ROWS)
	pane.selection = clamp(pane.selection, 0, max(pane.num_rows - 1, 0))
}

load_prog :: proc(fpath: string) -> bool {
	f, err := os.open(fpath, os.O_RDONLY)
	if err != os.ERROR_NONE {
		fmt.eprintln("Failed to load file:", err)
		return false
	}
	defer os.close(f)

	sz, _ := os.file_size(f)
	if sz <= 0 || int(sz) > hw.MEM_SIZE {
		fmt.eprintln("Bad program size:", sz)
		return false
	}

	_, rerr := os.read_full(f, machine.memory[:sz])
	if rerr != os.ERROR_NONE {
		fmt.eprintln("Failed to read file into memory:", rerr)
		return false
	}
	return true
}

reload_prog :: proc(stack_pane: ^ScrollPane) {
	hw.machine_init(&machine)
	if !load_prog(prog_path) {
		mode = .halted
		set_status("reload failed: %s", prog_path)
		return
	}
	sync_stack_pane(stack_pane)
	mode = .idle
	set_status("reloaded %s", prog_path)
}

draw_pane :: proc(v: ^Pane, allocator: runtime.Allocator) {
	font := get_font(v.font_size)
	rl.DrawRectangle(v.x, v.y, v.width, v.height, v.bg_color)
	for i in 0 ..< v.num_rows {
		y := v.y + i * v.font_size + PANE_PAD
		rl.DrawRectangle(v.x, y, v.width, v.font_size, v.bg_color)
		rl.DrawTextEx(
			font,
			v.row(i, allocator),
			{f32(v.x + PANE_PAD), f32(y)},
			f32(v.font_size),
			1,
			v.text_color,
		)
	}
}

draw_scrollpane :: proc(v: ^ScrollPane, allocator: runtime.Allocator) {
	font := get_font(v.font_size)
	rl.DrawRectangle(v.x, v.y, v.width, v.height, v.bg_color)
	for i in 0 ..< v.num_rows {
		y := v.y + i * v.font_size + PANE_PAD
		rl.DrawRectangle(v.x, y, v.width, v.font_size, i == v.selection ? v.sel_color : v.bg_color)
		rl.DrawTextEx(
			font,
			v.row(v.top + i, allocator),
			{f32(v.x + PANE_PAD), f32(y)},
			f32(v.font_size),
			1,
			v.text_color,
		)
	}
}


mem_key_handler :: proc(pane: ^ScrollPane) {
	if (rl.IsKeyPressed(rl.KeyboardKey.J)) {
		if pane.selection < MEM_NUM_ROWS - 1 {
			pane.selection += 1
		} else if pane.top + pane.num_rows < MAX_MEM_ROWS {
			pane.top += 1
		}
	}

	if (rl.IsKeyPressed(rl.KeyboardKey.K)) {
		if pane.selection > 0 {
			pane.selection -= 1
		} else if pane.top > 0 {
			pane.top -= 1
		}
	}
}

regs_key_handler :: proc(pane: ^ScrollPane) {
	if (rl.IsKeyPressed(rl.KeyboardKey.J)) {
		if pane.selection < REG_ROWS - 1 {
			pane.selection += 1
		} else if pane.top + pane.num_rows > REG_ROWS {
			pane.top += 1
		}
	}

	if (rl.IsKeyPressed(rl.KeyboardKey.K)) {
		if pane.selection > 0 {
			pane.selection -= 1
		} else if pane.top > 0 {
			pane.top -= 1
		}
	}

	// Eventually going to be edit mode for registers
	if (rl.IsKeyPressed(rl.KeyboardKey.E)) {
		if pane.selection > 0 {
			pane.selection -= 1
		} else if pane.top > 0 {
			pane.top -= 1
		}
	}
}

stack_key_handler :: proc(pane: ^ScrollPane) {
	if (rl.IsKeyPressed(rl.KeyboardKey.J)) {
		if pane.selection < pane.num_rows - 1 {
			pane.selection += 1
		} else if pane.top + STACK_MAX_ROWS < stack_depth() {
			pane.top += 1
			sync_stack_pane(pane)
		}
	}

	if (rl.IsKeyPressed(rl.KeyboardKey.K)) {
		if pane.selection > 0 {
			pane.selection -= 1
		} else if pane.top > 0 {
			pane.top -= 1
			sync_stack_pane(pane)
		}
	}
}

init_pane :: proc(
	base: PaneBase,
	key_handler: proc(pane: ^Pane),
	allocator := context.allocator,
) -> ^Pane {
	pane := new(Pane, allocator)
	pane.base = base
	pane.key_handler = key_handler
	return pane
}

init_scrollpane :: proc(
	base: PaneBase,
	key_handler: proc(pane: ^ScrollPane),
	allocator := context.allocator,
) -> ^ScrollPane {
	pane := new(ScrollPane, allocator)
	pane.base = base
	pane.key_handler = key_handler
	return pane
}

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

main :: proc() {
	// The hardware reports through context.logger, so give it somewhere to go.
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	if len(os.args) > 1 {
		prog_path = os.args[1]
	}

	hw.machine_init(&machine)
	if !load_prog(prog_path) {
		os.exit(1)
	}

	set_status("ready")

	mem_pane := init_scrollpane(
		PaneBase {
			x = MEM_PANE_X,
			y = MEM_PANE_Y,
			width = MEM_PANE_W,
			height = MEM_PANE_H,
			bg_color = MEM_PANE_BG_COLOR,
			border_color = MEM_PANE_BORDER_COLOR,
			sel_color = MEM_SELECTION_BG_COLOR,
			text_color = MEM_TEXT_COLOR,
			font_size = MEM_FONT_SIZE,
			num_rows = MEM_NUM_ROWS,
			row = mem_row,
		},
		mem_key_handler,
	)

	stack_pane := init_scrollpane(
		PaneBase {
			x = STACK_PANE_X,
			y = STACK_PANE_Y,
			width = STACK_PANE_W,
			height = STACK_PANE_H,
			bg_color = STACK_PANE_BG_COLOR,
			border_color = STACK_PANE_BORDER_COLOR,
			sel_color = STACK_SELECTION_BG_COLOR,
			text_color = STACK_TEXT_COLOR,
			font_size = STACK_FONT_SIZE,
			row = stack_row,
		},
		stack_key_handler,
	)
	sync_stack_pane(stack_pane)

	reg_pane := init_scrollpane(
		PaneBase {
			x = REG_PANE_X,
			y = REG_PANE_Y,
			width = REG_PANE_W,
			height = REG_PANE_H,
			bg_color = REG_PANE_BG_COLOR,
			border_color = REG_PANE_BORDER_COLOR,
			sel_color = STACK_SELECTION_BG_COLOR,
			text_color = REG_TEXT_COLOR,
			font_size = REG_FONT_SIZE,
			num_rows = REG_ROWS,
			row = reg_row,
		},
		regs_key_handler,
	)

	keybind_pane := init_pane(
		PaneBase {
			x = KEY_PANE_X,
			y = KEY_PANE_Y,
			width = KEY_PANE_W,
			height = KEY_PANE_H,
			bg_color = KEY_PANE_BG_COLOR,
			border_color = KEY_PANE_BORDER_COLOR,
			text_color = KEY_TEXT_COLOR,
			font_size = KEY_FONT_SIZE,
			num_rows = KEY_ROWS,
			row = keybind_row,
		},
		nil,
	)

	term_pane := init_pane(
		PaneBase {
			x = TERM_X,
			y = TERM_Y,
			width = TERM_W,
			height = TERM_H,
			bg_color = TERM_BG,
			border_color = TERM_BORDER_COLOR,
			text_color = TERM_TEXT_COLOR,
			font_size = TERM_FONT_SIZE,
			num_rows = 0,
			row = nil,
		},
		nil,
	)

	status_pane := init_pane(
		PaneBase {
			x = STATUS_X,
			y = STATUS_Y,
			width = STATUS_W,
			height = STATUS_H,
			bg_color = STATUS_BG,
			border_color = STATUS_BORDER_COLOR,
			text_color = STATUS_TEXT_COLOR,
			font_size = STATUS_FONT_SIZE,
			num_rows = 1,
			row = get_status,
		},
		nil,
	)

	panes: []AnyPane = {mem_pane, stack_pane, reg_pane, keybind_pane, term_pane, status_pane}

	focused_pane: AnyPane = panes[0]

	debug.log("machine initialized")

	debug.log("initializing window")

	rl.InitWindow(WIN_W, WIN_H, "MO-8")
	rl.SetTargetFPS(60)
	debug.log("done initializing window")

	defer font_cache_destroy()

	// MAIN LOOP
	for rl.WindowShouldClose() == false {
		rl.BeginDrawing()
		rl.ClearBackground(rl.DARKGRAY)

		if ctrl_held() {
			if rl.IsKeyPressed(.L) {
				focused_pane = stack_pane
			}
			if rl.IsKeyPressed(.J) {
				focused_pane = mem_pane
			}
			if rl.IsKeyPressed(.H) {
				focused_pane = reg_pane
			}
			if rl.IsKeyPressed(.K) {
				focused_pane = term_pane
			}
			if rl.IsKeyPressed(.R) {
				mode = .running
				machine.regs = {sp = hw.STACK_BASE}
				sync_stack_pane(stack_pane)
				set_status("running")
			}
			if rl.IsKeyPressed(.D) {
				mode = .debug
				set_status("space to step")
			}
			if rl.IsKeyPressed(.E) {
				reload_prog(stack_pane)
			}
			if rl.IsKeyPressed(.X) {
				mode = .halted
				set_status("killed at 0x%04X", machine.regs.pc)
			}
		} else {
			switch &v in &focused_pane {
			case ^Pane:
				if v.key_handler != nil {
					v.key_handler(v)
				}
			case ^ScrollPane:
				if v.key_handler != nil {
					v.key_handler(v)
				}
			}
		}

		switch mode {
		case .running:
			for _ in 0 ..< CYCLES_PER_FRAME {
				op, at, still := step(&machine)
				if op == .PUSH {
					sync_stack_pane(stack_pane)
				}
				if !still {
					mode = .halted
					set_status("%v at 0x%04X", op, at)
					break
				}
			}
		case .debug:
			if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
				op, at, still := step(&machine)
				if still {
					set_status("step: %v at 0x%04X", op, at)
				} else {
					mode = .halted
					set_status("%v at 0x%04X", op, at)
				}
				sync_stack_pane(stack_pane)
			}
		case .idle, .halted:
		}

		for &pane in panes {
			switch &v in pane {
			case ^Pane:
				rl.DrawRectangle(
					v.x - 2,
					v.y - 2,
					v.width + 4,
					v.height + 4,
					pane == focused_pane ? FOCUS_RING : v.border_color,
				)
				draw_pane(v, context.temp_allocator)

			case ^ScrollPane:
				rl.DrawRectangle(
					v.x - 2,
					v.y - 2,
					v.width + 4,
					v.height + 4,
					pane == focused_pane ? FOCUS_RING : v.border_color,
				)
				draw_scrollpane(v, context.temp_allocator)
			}
		}

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
