package hardware

MEM_SIZE :: 65536

// The whole address space, flat. Named as a type so Machine can hold one by
// value rather than the array literal being spelled out at every use.
Memory :: [MEM_SIZE]u8
