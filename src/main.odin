package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "debug"
import hw "hardware"
import rl "vendor:raylib"


machine: hw.Machine

// Window Constants
PANE_PAD :: 5
// corner segments for every rounded pane; raylib ignores this at roundedness 0
ROUND_SEGMENTS :: 8
WIN_W :: 1280
WIN_H :: 720
WIN_FILL :: 0.85

ui_scale: f32 = 1

fit_window :: proc() {
	mon := rl.GetCurrentMonitor()
	mpos := rl.GetMonitorPosition(mon)
	mw := f32(rl.GetMonitorWidth(mon))
	mh := f32(rl.GetMonitorHeight(mon))
	ui_scale = min(mw * WIN_FILL / WIN_W, mh * WIN_FILL / WIN_H)
	w := i32(WIN_W * ui_scale)
	h := i32(WIN_H * ui_scale)
	rl.SetWindowSize(w, h)
	rl.SetWindowPosition(i32(mpos.x) + (i32(mw) - w) / 2, i32(mpos.y) + (i32(mh) - h) / 2)
}

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

SCREEN_W :: TERM_W / 2
SCREEN_H :: TERM_H - (TERM_H / 3)
SCREEN_X :: TERM_X + (TERM_W - SCREEN_W) / 2
SCREEN_Y :: TERM_Y + (TERM_H - SCREEN_H) / 2
SCREEN_ROUNDEDNESS :: 0.04
SCREEN_BG: rl.Color : rl.LIGHTGRAY
SCREEN_BORDER_COLOR :: rl.GRAY
SCREEN_TEXT_COLOR :: rl.BLACK
SCREEN_FONT_SIZE :: 16

// Memory Pane Constants
MEM_PANE_X :: TERM_X
MEM_PANE_Y :: TERM_Y + TERM_H + 5
MEM_PANE_H :: 240
MEM_PANE_W :: TERM_W
MEM_PANE_BG_COLOR: rl.Color : {15, 15, 15, 255}
MEM_PANE_BORDER_COLOR :: rl.GRAY
MEM_SELECTION_BG_COLOR: rl.Color : {50, 60, 90, 255}
MEM_FONT_SIZE :: 16
MEM_PANE_ROUNDEDNESS :: 0.0
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
STACK_PANE_ROUNDEDNESS :: 0.0
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
REG_PANE_ROUNDEDNESS :: 0.0
REG_TEXT_COLOR :: rl.RAYWHITE

// Keybind Pane Constants
KEY_FONT_SIZE :: 14
KEY_PANE_X :: REG_PANE_X
KEY_PANE_Y :: REG_PANE_Y + REG_PANE_H + (PANE_PAD * 2)
KEY_PANE_W :: REG_PANE_W
KEY_PANE_BG_COLOR: rl.Color : {15, 15, 15, 255}
KEY_PANE_BORDER_COLOR :: rl.GRAY
KEY_PANE_ROUNDEDNESS :: 0.0
KEY_TEXT_COLOR :: rl.RAYWHITE

keybinds := [?]cstring {
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
	"g      goto address (memory)",
	"e      edit register (regs)",
}
KEY_ROWS :: i32(len(keybinds))
KEY_PANE_H :: (KEY_ROWS * KEY_FONT_SIZE) + (PANE_PAD * 2)

// Status Pane Constants
STATUS_W :: TERM_W
STATUS_H :: 20
STATUS_X :: TERM_X
STATUS_Y :: TERM_Y + TERM_H - STATUS_H
STATUS_ROUNDEDNESS :: 0.0
STATUS_BG: rl.Color : TERM_BG
STATUS_BORDER_COLOR :: 0
STATUS_TEXT_COLOR :: rl.RAYWHITE
STATUS_FONT_SIZE :: 16


// Sweetie 16, by GrafxKid. The index each colour sits at is the value a
// framebuffer byte holds, so SWEETIE16 is the lookup and the names are for
// spelling a colour out in host-side code.
SW_BLACK: rl.Color : {0x1A, 0x1C, 0x2C, 255} // 0  #1a1c2c
SW_PURPLE: rl.Color : {0x5D, 0x27, 0x5D, 255} // 1  #5d275d
SW_RED: rl.Color : {0xB1, 0x3E, 0x53, 255} // 2  #b13e53
SW_ORANGE: rl.Color : {0xEF, 0x7D, 0x57, 255} // 3  #ef7d57
SW_YELLOW: rl.Color : {0xFF, 0xCD, 0x75, 255} // 4  #ffcd75
SW_LIME: rl.Color : {0xA7, 0xF0, 0x70, 255} // 5  #a7f070
SW_GREEN: rl.Color : {0x38, 0xB7, 0x64, 255} // 6  #38b764
SW_TEAL: rl.Color : {0x25, 0x71, 0x79, 255} // 7  #257179
SW_NAVY: rl.Color : {0x29, 0x36, 0x6F, 255} // 8  #29366f
SW_BLUE: rl.Color : {0x3B, 0x5D, 0xC9, 255} // 9  #3b5dc9
SW_SKY: rl.Color : {0x41, 0xA6, 0xF6, 255} // 10 #41a6f6
SW_CYAN: rl.Color : {0x73, 0xEF, 0xF7, 255} // 11 #73eff7
SW_WHITE: rl.Color : {0xF4, 0xF4, 0xF4, 255} // 12 #f4f4f4
SW_LIGHT_GREY: rl.Color : {0x94, 0xB0, 0xC2, 255} // 13 #94b0c2
SW_GREY: rl.Color : {0x56, 0x6C, 0x86, 255} // 14 #566c86
SW_DARK_GREY: rl.Color : {0x33, 0x3C, 0x57, 255} // 15 #333c57

PALETTE_SIZE :: 16
SWEETIE16 :: [PALETTE_SIZE]rl.Color {
	SW_BLACK,
	SW_PURPLE,
	SW_RED,
	SW_ORANGE,
	SW_YELLOW,
	SW_LIME,
	SW_GREEN,
	SW_TEAL,
	SW_NAVY,
	SW_BLUE,
	SW_SKY,
	SW_CYAN,
	SW_WHITE,
	SW_LIGHT_GREY,
	SW_GREY,
	SW_DARK_GREY,
}

FB_W :: 128
FB_H :: 96
FB_BASE :: 0x8000
FB_BASE_2 :: 0xB000
FB_LEN :: FB_W * FB_H
KBD_ADDR :: FB_BASE_2 + FB_LEN
DISP_PAGE_ADDR :: KBD_ADDR + 1

fb_pixels: [FB_LEN]rl.Color
fb_tex: rl.Texture2D

fb_init :: proc() {
	img := rl.GenImageColor(FB_W, FB_H, SW_BLACK)
	defer rl.UnloadImage(img)
	fb_tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(fb_tex, .POINT)
}

// Wraps rather than clamps, so a bad index is still a colour and never an
// out-of-bounds read.
palette_color :: proc(i: u8) -> rl.Color {
	pal := SWEETIE16
	return pal[i % PALETTE_SIZE]
}

status_buf: [128]u8
status: string

/*
* A one-line text prompt, drawn in the status pane.
*
* While one is active it swallows every key, so the pane scroll keys and the
* global bindings cannot fire from the same keystrokes that are being typed
* into it. The pane that opened the prompt is carried along, because the panes
* are locals in main and a commit needs to act on the one that asked.
*/
PROMPT_MAX :: 256

Prompt :: struct {
	active: bool,
	label:  string,
	buf:    [PROMPT_MAX]u8,
	len:    int,
	target: ^Pane,
	commit: proc(pane: ^Pane, text: string),
}

prompt: Prompt

prompt_open :: proc(
	label: string,
	target: ^Pane,
	commit: proc(pane: ^Pane, text: string),
) {
	prompt = Prompt {
		active = true,
		label  = label,
		target = target,
		commit = commit,
	}
}

prompt_text :: proc() -> string {
	return string(prompt.buf[:prompt.len])
}

// Returns true while the prompt still owns the keyboard.
prompt_update :: proc() -> bool {
	if !prompt.active {
		return false
	}

	if rl.IsKeyPressed(.ESCAPE) {
		prompt.active = false
		set_status("cancelled")
		return true
	}

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		prompt.active = false
		if prompt.len == 0 {
			set_status("cancelled")
		} else if prompt.commit != nil {
			prompt.commit(prompt.target, prompt_text())
		}
		return true
	}

	if rl.IsKeyPressed(.BACKSPACE) && prompt.len > 0 {
		prompt.len -= 1
	}

	// GetCharPressed drains the character queue, so a fast typist loses
	// nothing to the frame rate
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		if c < 32 || c > 126 || prompt.len >= PROMPT_MAX {
			continue
		}
		prompt.buf[prompt.len] = u8(c)
		prompt.len += 1
	}

	return true
}

// Scrolls a memory pane so that addr is selected, centred where there is room
// above and below it.
mem_goto :: proc(pane: ^Pane, text: string) {
	t := text
	if len(t) > 2 && (t[:2] == "0x" || t[:2] == "0X") {
		t = t[2:]
	}

	addr, ok := strconv.parse_u64_of_base(t, 16)
	if !ok {
		set_status("goto: %q is not a hex address", text)
		return
	}
	if addr >= hw.MEM_SIZE {
		set_status("goto: 0x%X is past the end of memory", addr)
		return
	}

	row := i32(addr) / BYTES_PER_ROW
	max_top := max(MAX_MEM_ROWS - pane.num_rows, 0)
	pane.top = clamp(row - pane.num_rows / 2, 0, max_top)
	pane.selection = row - pane.top
	set_status("goto 0x%04X", addr)
}

Mode :: enum {
	idle,
	running,
	debug,
	halted,
}

mode: Mode = .idle

prog_path := "o.out"
prog_path_buf: [256]u8

set_prog_path :: proc(p: string) {
	n := copy(prog_path_buf[:], p)
	prog_path = string(prog_path_buf[:n])
}

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

CYCLES_PER_FRAME :: 16000
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
	roundedness:         f32,
	row:                 proc(i: i32, allocator: runtime.Allocator) -> cstring,
}

// Corner radius is a fraction of the pane's shorter side, and raylib falls back
// to a plain rectangle at 0, so a square pane costs nothing to draw this way.
draw_rect :: proc(x, y, width, height: i32, roundedness: f32, color: rl.Color) {
	rl.DrawRectangleRounded(
		{f32(x), f32(y), f32(width), f32(height)},
		roundedness,
		ROUND_SEGMENTS,
		color,
	)
}

Pane :: struct {
	using base:  PaneBase,
	top:         i32,
	selection:   i32,
	key_handler: proc(pane: ^Pane),
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
	f, loaded := load_mono_font(i32(f32(size) * ui_scale + 0.5))
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
	if prompt.active {
		return fmt.ctprintf("%s%s_", prompt.label, prompt_text())
	}
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

sync_stack_pane :: proc(pane: ^Pane) {
	depth := stack_depth()
	max_top := max(depth - STACK_MAX_ROWS, 0)
	pane.top = clamp(pane.top, 0, max_top)
	pane.num_rows = clamp(depth - pane.top, 0, STACK_MAX_ROWS)
	pane.selection = clamp(pane.selection, 0, max(pane.num_rows - 1, 0))
}

load_prog :: proc(pane: ^Pane, fpath: string) {
	f, err := os.open(fpath, os.O_RDONLY)
	if err != os.ERROR_NONE {
		set_status("Failed to load file:", err)
		return
	}
	defer os.close(f)

	sz, _ := os.file_size(f)
	if sz <= 0 || int(sz) > hw.MEM_SIZE {
		set_status("Bad program size:", sz)
		return
	}

	_, rerr := os.read_full(f, machine.memory[:sz])
	if rerr != os.ERROR_NONE {
		set_status("Failed to read file into memory:", rerr)
		return
	}
	set_prog_path(fpath)
	return
}

reload_prog :: proc(stack_pane: ^Pane) {
	hw.machine_init(&machine)
	load_prog(stack_pane, prog_path)
	sync_stack_pane(stack_pane)
	mode = .idle
	set_status("reloaded %s", prog_path)
}

draw_pane :: proc(v: ^Pane, allocator: runtime.Allocator) {
	font := get_font(v.font_size)
	draw_rect(v.x, v.y, v.width, v.height, v.roundedness, v.bg_color)
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

draw_screen :: proc(pane: Pane) {
	front := machine.memory[DISP_PAGE_ADDR] == FB_BASE_2 >> 8 ? FB_BASE_2 : FB_BASE
	for i in 0 ..< FB_LEN {
		fb_pixels[i] = palette_color(machine.memory[front + i])
	}
	rl.UpdateTexture(fb_tex, raw_data(fb_pixels[:]))
	rl.DrawTexturePro(
		fb_tex,
		{0, 0, FB_W, FB_H},
		{SCREEN_X, SCREEN_Y, SCREEN_W, SCREEN_H},
		{0, 0},
		0,
		rl.WHITE,
	)
}

mem_key_handler :: proc(pane: ^Pane) {
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

	if (rl.IsKeyPressed(rl.KeyboardKey.G)) {
		prompt_open("goto: 0x", pane, mem_goto)
	}
}

regs_key_handler :: proc(pane: ^Pane) {
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

	if (rl.IsKeyPressed(rl.KeyboardKey.E)) {
		row := pane.top + pane.selection
		if row >= 0 && row < REG_ROWS {
			labels := REG_EDIT_LABELS
			prompt_open(labels[row], pane, reg_edit)
		}
	}
}

REG_ROW_CODES :: [REG_ROWS]u16{hw.R_A, hw.R_B, hw.R_X, hw.R_SP, hw.R_FP, hw.R_PC, hw.R_FLAGS}
REG_ROW_NAMES :: [REG_ROWS]string{"a", "b", "x", "sp", "fp", "pc", "flags"}
REG_EDIT_LABELS :: [REG_ROWS]string {
	"a = 0x",
	"b = 0x",
	"x = 0x",
	"sp = 0x",
	"fp = 0x",
	"pc = 0x",
	"flags = 0x",
}

reg_edit :: proc(pane: ^Pane, text: string) {
	row := pane.top + pane.selection
	if row < 0 || row >= REG_ROWS {
		return
	}
	codes := REG_ROW_CODES
	names := REG_ROW_NAMES
	code := codes[row]
	name := names[row]

	t := text
	if len(t) > 2 && (t[:2] == "0x" || t[:2] == "0X") {
		t = t[2:]
	}

	val, ok := strconv.parse_u64_of_base(t, 16)
	if !ok {
		set_status("%s: %q is not a hex value", name, text)
		return
	}

	_, reg_max, _ := hw.RegRead(&machine, code)
	if val > u64(reg_max) {
		set_status("%s: 0x%X does not fit in %d bits", name, val, reg_max == 0xFF ? 8 : 16)
		return
	}

	hw.RegWrite(&machine, code, u16(val))
	set_status("%s = 0x%X", name, val)
}

stack_key_handler :: proc(pane: ^Pane) {
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

	set_status("ready")

	mem_pane := init_pane(
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
			roundedness = MEM_PANE_ROUNDEDNESS,
			row = mem_row,
		},
		mem_key_handler,
	)

	stack_pane := init_pane(
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
			roundedness = STACK_PANE_ROUNDEDNESS,
			row = stack_row,
		},
		stack_key_handler,
	)
	sync_stack_pane(stack_pane)

	reg_pane := init_pane(
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
			roundedness = REG_PANE_ROUNDEDNESS,
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
			roundedness = KEY_PANE_ROUNDEDNESS,
			row = keybind_row,
		},
		nil,
	)

	border_pane := init_pane(
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
			roundedness = TERM_ROUNDEDNESS,
			row = nil,
		},
		nil,
	)

	screen_pane := init_pane(
		PaneBase {
			x = SCREEN_X,
			y = SCREEN_Y,
			width = SCREEN_W,
			height = SCREEN_H,
			bg_color = SCREEN_BG,
			border_color = SCREEN_BORDER_COLOR,
			text_color = SCREEN_TEXT_COLOR,
			font_size = SCREEN_FONT_SIZE,
			num_rows = 0,
			roundedness = SCREEN_ROUNDEDNESS,
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
			roundedness = STATUS_ROUNDEDNESS,
			row = get_status,
		},
		nil,
	)

	panes: []^Pane = {mem_pane, stack_pane, reg_pane, keybind_pane, border_pane, status_pane}

	focused_pane: ^Pane = panes[0]

	debug.log("machine initialized")

	debug.log("initializing window")

	rl.InitWindow(WIN_W, WIN_H, "MO-8")
	rl.SetTargetFPS(60)
	fit_window()
	debug.log("done initializing window")

	// textures need the GL context the window just created
	fb_init()
	defer rl.UnloadTexture(fb_tex)

	defer font_cache_destroy()

	// MAIN LOOP
	for rl.WindowShouldClose() == false {
		rl.BeginDrawing()
		rl.ClearBackground(rl.DARKGRAY)
		rl.BeginMode2D(rl.Camera2D{zoom = ui_scale})

		if prompt_update() {
			// the prompt has the keyboard; no binding fires this frame
		} else if ctrl_held() {
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
				focused_pane = border_pane
			}
			if rl.IsKeyPressed(.R) {
				mode = .running
				machine.regs = {
					sp = hw.STACK_BASE,
				}
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
			if (rl.IsKeyPressed(.P)) {
				prompt_open("prog path: ", screen_pane, load_prog)
			}
		} else {
			if focused_pane.key_handler != nil {
				focused_pane.key_handler(focused_pane)
			}
		}

		// poll for key input
		if mode == .running {
			if rl.IsKeyDown(rl.KeyboardKey.LEFT) {
				machine.memory[KBD_ADDR] = 1
			} else if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {
				machine.memory[KBD_ADDR] = 2
			} else if rl.IsKeyDown(rl.KeyboardKey.UP) {
				machine.memory[KBD_ADDR] = 3
			} else if rl.IsKeyDown(rl.KeyboardKey.DOWN) {
				machine.memory[KBD_ADDR] = 4
			} else if rl.IsKeyDown(rl.KeyboardKey.RIGHT_SHIFT) {
				machine.memory[KBD_ADDR] = 5
			} else if rl.IsKeyDown(rl.KeyboardKey.LEFT_SHIFT) {
				machine.memory[KBD_ADDR] = 5
			} else if rl.IsKeyDown(rl.KeyboardKey.ENTER) {
				machine.memory[KBD_ADDR] = 6
			} else {
				machine.memory[KBD_ADDR] = 0
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

		for pane in panes {
			draw_rect(
				pane.x - 2,
				pane.y - 2,
				pane.width + 4,
				pane.height + 4,
				pane.roundedness,
				pane == focused_pane ? FOCUS_RING : pane.border_color,
			)
			draw_pane(pane, context.temp_allocator)
		}
		draw_screen(screen_pane^)

		rl.EndMode2D()
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
