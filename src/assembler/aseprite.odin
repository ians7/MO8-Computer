/*
* Aseprite (.ase/.aseprite) decoding, enough of it to turn a sprite into the
* bytes this machine draws: one palette index per pixel.
*
* An .ase file is a container, not an image. The pixels live in a cel chunk
* inside a frame, usually zlib compressed, and a cel can be smaller than the
* canvas and offset within it. So the decode composites every cel of frame 0
* onto a canvas-sized buffer rather than handing back the cel as-is.
*
* Only 8bpp indexed files are accepted. 16bpp and 32bpp would need a palette
* match per pixel to mean anything here, and that is a decision about the
* palette, not about parsing.
*/
package assembler

import "core:bytes"
import "core:compress/zlib"
import "core:log"

ASE_MAGIC :: 0xA5E0
ASE_FRAME_MAGIC :: 0xF1FA
ASE_HEADER_SZ :: 128
ASE_FRAME_HEADER_SZ :: 16
ASE_CHUNK_HEADER_SZ :: 6
ASE_CEL_HEADER_SZ :: 16

ASE_CHUNK_CEL :: 0x2005

ASE_CEL_RAW :: 0
ASE_CEL_LINKED :: 1
ASE_CEL_COMPRESSED :: 2

// Every multi-byte field in the format is little endian. These return 0 past
// the end of the buffer rather than trapping, and the callers bounds-check the
// structures they are walking before trusting a value.
ase_u16 :: #force_inline proc(d: []u8, at: int) -> int {
	if at + 2 > len(d) {
		return 0
	}
	return int(d[at]) | (int(d[at + 1]) << 8)
}

ase_u32 :: #force_inline proc(d: []u8, at: int) -> int {
	if at + 4 > len(d) {
		return 0
	}
	return int(d[at]) | (int(d[at + 1]) << 8) | (int(d[at + 2]) << 16) | (int(d[at + 3]) << 24)
}

ase_i16 :: #force_inline proc(d: []u8, at: int) -> int {
	v := ase_u16(d, at)
	return v >= 0x8000 ? v - 0x10000 : v
}

is_ase :: proc(d: []u8) -> bool {
	return len(d) >= ASE_HEADER_SZ && ase_u16(d, 4) == ASE_MAGIC
}

// Copies one cel onto the canvas at its own offset, clipping anything that
// falls outside. The transparent index is left alone so that cels stacked in
// layer order composite the way they do in the editor.
ase_blit_cel :: proc(
	canvas: []u8,
	cw, ch: int,
	cel: []u8,
	clw, clh, cx, cy: int,
	transparent: u8,
) {
	for y in 0 ..< clh {
		dy := cy + y
		if dy < 0 || dy >= ch {
			continue
		}
		for x in 0 ..< clw {
			dx := cx + x
			if dx < 0 || dx >= cw {
				continue
			}
			px := cel[y * clw + x]
			if px == transparent {
				continue
			}
			canvas[dy * cw + dx] = px
		}
	}
}

// Decodes frame 0 into a canvas-sized buffer of palette indices. The caller
// owns the returned slice.
ase_decode :: proc(
	d: []u8,
	allocator := context.allocator,
) -> (
	pixels: []u8,
	width: int,
	height: int,
	ok: bool,
) {
	if !is_ase(d) {
		return nil, 0, 0, false
	}

	frames := ase_u16(d, 6)
	w := ase_u16(d, 8)
	h := ase_u16(d, 10)
	depth := ase_u16(d, 12)
	transparent := u8(d[28])

	if depth != 8 {
		log.warnf("aseprite: %d bpp is not supported, only 8bpp indexed is", depth)
		return nil, 0, 0, false
	}
	if w <= 0 || h <= 0 {
		log.warnf("aseprite: bad canvas size %dx%d", w, h)
		return nil, 0, 0, false
	}
	if frames < 1 {
		log.warn("aseprite: file has no frames")
		return nil, 0, 0, false
	}

	if ase_u16(d, ASE_HEADER_SZ + 4) != ASE_FRAME_MAGIC {
		log.warn("aseprite: frame 0 has a bad magic number")
		return nil, 0, 0, false
	}

	// the old 16-bit count is only meaningful when the 32-bit one is zero
	nchunks := ase_u32(d, ASE_HEADER_SZ + 12)
	if nchunks == 0 {
		nchunks = ase_u16(d, ASE_HEADER_SZ + 6)
	}

	canvas := make([]u8, w * h, allocator)
	for &b in canvas {
		b = transparent
	}

	frame_end := ASE_HEADER_SZ + ase_u32(d, ASE_HEADER_SZ)
	if frame_end > len(d) {
		frame_end = len(d)
	}

	at := ASE_HEADER_SZ + ASE_FRAME_HEADER_SZ
	cels := 0

	for _ in 0 ..< nchunks {
		if at + ASE_CHUNK_HEADER_SZ > frame_end {
			break
		}

		csize := ase_u32(d, at)
		ctype := ase_u16(d, at + 4)
		if csize < ASE_CHUNK_HEADER_SZ || at + csize > frame_end {
			log.warn("aseprite: chunk runs past the end of the frame")
			delete(canvas, allocator)
			return nil, 0, 0, false
		}

		if ctype != ASE_CHUNK_CEL {
			at += csize
			continue
		}

		body := d[at + ASE_CHUNK_HEADER_SZ:at + csize]
		if len(body) < ASE_CEL_HEADER_SZ {
			log.warn("aseprite: truncated cel chunk")
			delete(canvas, allocator)
			return nil, 0, 0, false
		}

		cx := ase_i16(body, 2)
		cy := ase_i16(body, 4)
		cel_type := ase_u16(body, 7)
		rest := body[ASE_CEL_HEADER_SZ:]

		switch cel_type {
		case ASE_CEL_RAW:
			if len(rest) < 4 {
				log.warn("aseprite: truncated raw cel")
				delete(canvas, allocator)
				return nil, 0, 0, false
			}
			clw := ase_u16(rest, 0)
			clh := ase_u16(rest, 2)
			px := rest[4:]
			if len(px) < clw * clh {
				log.warnf("aseprite: raw cel is %d bytes, expected %d", len(px), clw * clh)
				delete(canvas, allocator)
				return nil, 0, 0, false
			}
			ase_blit_cel(canvas, w, h, px, clw, clh, cx, cy, transparent)
			cels += 1

		case ASE_CEL_COMPRESSED:
			if len(rest) < 4 {
				log.warn("aseprite: truncated compressed cel")
				delete(canvas, allocator)
				return nil, 0, 0, false
			}
			clw := ase_u16(rest, 0)
			clh := ase_u16(rest, 2)

			buf: bytes.Buffer
			if zerr := zlib.inflate(rest[4:], &buf, false, clw * clh); zerr != nil {
				log.warnf("aseprite: could not inflate cel: %v", zerr)
				bytes.buffer_destroy(&buf)
				delete(canvas, allocator)
				return nil, 0, 0, false
			}

			px := bytes.buffer_to_bytes(&buf)
			if len(px) < clw * clh {
				log.warnf("aseprite: cel inflated to %d bytes, expected %d", len(px), clw * clh)
				bytes.buffer_destroy(&buf)
				delete(canvas, allocator)
				return nil, 0, 0, false
			}
			ase_blit_cel(canvas, w, h, px, clw, clh, cx, cy, transparent)
			bytes.buffer_destroy(&buf)
			cels += 1

		case ASE_CEL_LINKED:
			// a link back to an earlier frame's cel, which frame 0 cannot have
			log.warn("aseprite: linked cels are not supported")
			delete(canvas, allocator)
			return nil, 0, 0, false

		case:
			log.warnf("aseprite: cel type %d is not supported", cel_type)
			delete(canvas, allocator)
			return nil, 0, 0, false
		}

		at += csize
	}

	if cels == 0 {
		log.warn("aseprite: frame 0 has no cels")
		delete(canvas, allocator)
		return nil, 0, 0, false
	}

	return canvas, w, h, true
}
