# CPU design doc

This CPU is taking inspiration from several different existing CPUs, as well as my personal
taste

## Endianness

This is a little endian processor

## Registers

2 general purpose registers, named `a` and `b`. Every register is nameable by an
operand field, whatever its width: the register file is addressed through one
width-aware pair of accessors rather than a pointer that would have to commit to
a width in advance.

| code | register |
| ---- | -------- |
| 0 | `a` |
| 1 | `b` |
| 2 | `fp` |
| 3 | `x` |
| 4 | `sp` |
| 5 | `pc` |
| 6 | `flags` |

Code 7 is unassigned; naming it is an error rather than an alias onto a
real register. A value read from a register is widened to 16 bits and truncated
back to the register's own width on write, so `a` and `b` still behave as bytes
while `fp`, `x`, `sp` and `pc` keep all sixteen. Carry flags at the destination
register's own boundary, so an 8-bit add carries at `0xFF` and a 16-bit add at
`0xFFFF`.
 I want to really limit my resources for a challenge, so I was initially
considering a single accumulator and a general purpose register. I found, however, that having 16-bit
instructions meant that I did not need to have the accumulator register

| Register | Purpose                                                                        | size in bits |
| -------- | ------------------------------------------------------------------------------ | ------------ |
| a        | general purpose register                                                       | 8            |
| b        | general purpose register                                                       | 8            |
| fp       | function pointer register for holding the address used by the CALL alias       | 16           |
| x        | index register; a general purpose 16-bit pointer for addressing memory          | 16           |
| sp       | stack pointer register                                                         | 16           |
| pc       | program counter register                                                       | 16           |
| flags    | status register for boolean indicators reflecting outcome of recent ALU ops    | 8            |

#### Flag Table

| Flag Name | Purpose                                                            | Value        |
| --------- | ------------------------------------------------------------------ | ------------ |
| carry     | Indicates a carry out from the previous operation                  | `0b00000001` |
| zero      | Set if the result of the previous operation was zero               | `0b00000010` |
| of        | Overflow; set if the previous operation produced a signed overflow | `0b00000100` |
| n         | Negative; mirrors the most significant bit of the result           | `0b00001000` |

## ISA

| inst | opcode | function                                                                                        |
| ---- | ------ | ----------------------------------------------------------------------------------------------- |
| add  | 00000  | Add two registers, storing the result in the destination register                               |
| sub  | 00001  | Subtract the value of one register from another, storing the result in the destination register |
| mul  | 00010  | Multiply two registers, storing the result in the destination register                          |
| div  | 00011  | Divide one register by another, storing the result in the destination register                  |
| not  | 00100  | Bitwise complement of the destination register; flips every bit                                 |
| or   | 00101  | Bitwise OR of two registers, storing the result in the destination register                     |
| xor  | 00110  | Bitwise XOR of two registers, storing the result in the destination register                    |
| and  | 00111  | Bitwise AND of two registers, storing the result in the destination register                    |
| srl  | 01000  | Logical shift the destination register right by a register value                                |
| sll  | 01001  | Logical shift the destination register left by a register value                                 |
| ld   | 01010  | Load from the memory address in the source register into the destination register               |
| st   | 01011  | Store the destination register at the memory address in the source register                     |
| cmpr | 01100  | Compare two registers, updating flags                                                           |
| movi | 01101  | Load an immediate value into the destination register                                           |
| addi | 01110  | Add an immediate value to the destination register                                              |
| xori | 01111  | Bitwise XOR of the destination register with an immediate value                                 |
| subi | 10000  | Subtract an immediate value from the destination register                                       |
| andi | 10001  | Bitwise AND of the destination register with an immediate value                                 |
| ori  | 10010  | Bitwise OR of the destination register with an immediate value                                  |
| slli | 10011  | Logical shift the destination register left by an immediate value                               |
| srli | 10100  | Logical shift the destination register right by an immediate value                              |
| jmp  | 10101  | Jump unconditionally by a signed offset relative to PC                                          |
| jne  | 10110  | Jump by a signed offset if the previous cmp indicates not equal                                 |
| jeq  | 10111  | Jump by a signed offset if the previous cmp indicates equal                                     |
| jgt  | 11000  | Jump by a signed offset if the previous cmp indicates greater than                              |
| jge  | 11001  | Jump by a signed offset if the previous cmp indicates greater than or equal                     |
| jlt  | 11010  | Jump by a signed offset if the previous cmp indicates less than                                 |
| jle  | 11011  | Jump by a signed offset if the previous cmp indicates less than or equal                        |
| push | 11100  | Push the operand register onto the stack                                                        |
| pop  | 11101  | Pop a value off the stack into the operand register                                             |
| jmpf | 11110  | Jump to the address held in the fp register                                                     |
| halt | 11111  | Stop program execution                                                                          |

**Note:** In all arithmetic operations, the first operand is the destination register.

**Note:** A register moves its own width. `push`, `pop`, `ld` and `st` all
follow this one rule: `push a` moves one byte and `push pc` moves two, `ld a sp`
loads one byte and `ld fp sp` loads two. Multi-byte moves are little endian, so
the low byte sits at the lower address, and `pop` reads back exactly what `push`
wrote.

For `ld` and `st` the address operand is read at its register's full width. That
is what lets them reach the whole 64K space: an address in `sp`, `fp` or `pc`
names anywhere, while one held in `a` or `b` still covers only the first 256
bytes because that is all a byte can say. There is no separate wide-load
instruction; the width comes from the registers named.

**Note:** Opcodes are grouped by operand form, and the assembler decides which
form an instruction takes from the range its opcode falls in. Each class is one
contiguous run of opcodes, and the classes appear in this order:

| class | opcodes | boundary |
| ----- | ------- | -------- |
| reg-reg | `add` - `cmpr` | `REG_REG_MAX` |
| immediate | `movi` - `srli` | `IMM_MAX` |
| relative jump | `jmp` - `jle` | `ADDR_MAX` |
| single-reg | `push` - `pop` | `SINGLE_REG_MAX` |
| none | `jmpf` - `halt` | (everything above) |

`call` and `ret` hold no opcode at all: both are assembler aliases that expand
into real instructions, so the CPU never decodes them. The two slots they used
to occupy went to `slli` and `srli`, which sit at the end of the immediate run.
Shifting by an immediate rather than by a register matters here more than it
would on a larger machine: with only `a` and `b` to work with, a shift-by-
register spends the entire general purpose file just holding the count.

`push` and `pop` are the only single-register instructions, and `jmpf` sits with
`halt` because its target comes from `fp` rather than from the instruction word.

Reordering this table means reordering the `Op` enum in `src/hardware/cpu.odin`,
the `opcode_map` in `src/assembler/assembler.odin`, and the class boundaries
that go with them.

**Functions:** `call` and `ret` are aliases, eight and two instructions wide.

```
call #addr              ret

movi fp 0               pop  fp
add  fp pc              jmpf
addi fp 12
push fp
movi fp #addr_upper
slli fp 8
addi fp #addr_lower
jmpf
```

The first half saves the return address. There is no reg-reg move, so `movi fp 0`
plus `add fp pc` is how `pc` is copied somewhere it can be worked on -- reading
`pc` directly is fine, but writing to it is a jump, so it cannot be shifted in
place. `pc` reads as the address of the instruction *after* the one executing,
so the copy lands three instructions into the expansion and the `addi` carries it
the remaining six, to the instruction following the call. `push fp` then writes
both bytes, because a register moves its own width.

The second half builds the target. `fp` is 16 bits wide, which is the whole
point: the jumps carry an 11-bit signed offset and so reach only about a kilobyte
either side of themselves, while `fp` names anywhere in the 64K space. A call is
the long-range branch; a jump is the local one. Building the address a byte at a
time is what `slli` is for, and it is why `fp` is reachable from the immediate
class (`movi`, `slli`, `addi`) even though the reg-reg and single-reg forms still
see only `a` and `b`.

`ret` is the mirror: `pop fp` takes both bytes back off the stack and `jmpf`
returns through them. Neither alias touches `a` or `b`, so a callee is free to
use them for arguments.

The `12` is `CALL_SKIP` in the assembler, derived from `CALL_WIDTH` so that
adding an instruction to the expansion moves the return address with it.


**Immediate Operations**
| 15 - 11 | 10 - 8 | 7 - 0 |
|---------|--------|-----------|
| opcode | reg | immediate |

**Jump Operations** (`jmp`, `jne`, `jeq`, `jgt`, `jge`, `jlt`, `jle`)
| 15 - 11 | 10 - 0 |
|---------|---------------|
| opcode | signed offset |

Every jump is **relative**, and the offset is a signed two's complement count of
bytes measured from **the instruction after the jump**. That is where `pc`
already points when the instruction executes, since the fetch advances `pc`
before running it, so the hardware needs no correction term: it sign-extends the
field to sixteen bits and adds. Sign-extending before adding is also what makes a
backward jump need no second case, as `pc + 0xFFFE` wraps to `pc - 2`.

A jump names no register, so the three bits the other forms spend on one are
free, and the offset takes the whole 11-bit field rather than the low byte. That
gives a reach of **-1024 to +1023 bytes**, 511 instructions either way. The
assembler refuses a label outside that range rather than truncating the offset
into one that would assemble cleanly and then jump somewhere unrelated.

`call` is not in this class. It is an alias that expands into real instructions
and carries an absolute 16-bit address, described above.

**Reg-Reg Operations**
| 15 - 11 | 10 - 8 | 7 - 3 | 2 - 0 |
|---------|--------|----------|-------|
| opcode | dst | reserved | src |

**Single-Reg Operations** (`push`, `pop`)
| 15 - 11 | 10 - 8 | 7 - 0 |
|---------|--------|----------|
| opcode | reg | reserved |

The register field is the same field the reg-reg and immediate forms use for
their destination. `push` reads it; `pop` writes the popped value into it, so
`pop a` and `pop b` are distinct instructions rather than aliases for a single
implicit destination.

**None** (`jmpf`, `ret`, `halt`)
| 15 - 11 | 10 - 0 |
|---------|------------|  
| opcode | reserved |
