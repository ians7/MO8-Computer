package tests

import "core:testing"
import hw "../src/hardware"

@(test)
opcode_decode_test :: proc(t: ^testing.T) {
	for op in hw.Op {
		encoded := u16(op) << 11
		got := hw.read_inst(encoded)
		testing.expectf(t, got == op, "expected %v, got %v (encoded 0x%04x)", op, got, encoded)
	}
}
