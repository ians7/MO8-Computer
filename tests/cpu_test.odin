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

@(test)
add_test :: proc(t: ^testing.T) {
	hw.cpu.a = 1
	hw.cpu.b = 2
	inst: u16 = 0x0001
	hw.read_inst(inst)
	testing.expectf(t, hw.cpu.a == 3, "expected %v, got %v", 3, hw.cpu.a)
}

@(test)
addi_test ::proc(t: ^testing.T) {
	hw.cpu.a = 1
	inst: u16 = 0x82
	hw.read_inst(inst)
	testing.expectf(t, hw.cpu.a == 3, "expected %v, got %v", 3, hw.cpu.a)
}

@(test)
sub_test ::proc(t: ^testing.T) {

}

@(test)
subi_test ::proc(t: ^testing.T) {

}

@(test)
mul_test ::proc(t: ^testing.T) {

}

@(test)
div_test ::proc(t: ^testing.T) {

}

@(test)
not_test ::proc(t: ^testing.T) {

}

@(test)
or_test ::proc(t: ^testing.T) {

}

@(test)
ori_test ::proc(t: ^testing.T) {

}

@(test)
xor_test ::proc(t: ^testing.T) {

}

@(test)
xori_test ::proc(t: ^testing.T) {

}

@(test)
and_test ::proc(t: ^testing.T) {

}

@(test)
andi_test ::proc(t: ^testing.T) {

}

@(test)
srl_test ::proc(t: ^testing.T) {

}

@(test)
sra_test ::proc(t: ^testing.T) {

}

@(test)
ld_test ::proc(t: ^testing.T) {

}

@(test)
st_test ::proc(t: ^testing.T) {

}

@(test)
mov_test ::proc(t: ^testing.T) {

}

@(test)
cmp_test ::proc(t: ^testing.T) {

}

@(test)
cmpr_test ::proc(t: ^testing.T) {

}

@(test)
jr_test ::proc(t: ^testing.T) {

}

@(test)
jeq_test ::proc(t: ^testing.T) {

}

@(test)
jgt_test ::proc(t: ^testing.T) {

}

@(test)
jge_test ::proc(t: ^testing.T) {

}

@(test)
jlt_test ::proc(t: ^testing.T) {

}

@(test)
jle_test ::proc(t: ^testing.T) {

}

@(test)
push_test ::proc(t: ^testing.T) {

}

@(test)
pop_test ::proc(t: ^testing.T) {

}

@(test)
call_test ::proc(t: ^testing.T) {

}

@(test)
ret_test ::proc(t: ^testing.T) {

}

@(test)
halt_test ::proc(t: ^testing.T) {

}

