# CPU design doc

This CPU takes inspiration from various different existing CPUs with some of my own
ideas on top of it.

## Endianness

Little Endian

## Registers

| code | Register | Purpose                                                                     | size (bits) |
| ---- | -------- | --------------------------------------------------------------------------- | ----------- |
| 0    | a        | general purpose register                                                    | 8           |
| 1    | b        | general purpose register                                                    | 8           |
| 2    | fp       | function pointer register for holding the address used by the CALL alias    | 16          |
| 3    | x        | index register; a general purpose 16-bit pointer for addressing memory      | 16          |
| 4    | sp       | stack pointer register                                                      | 16          |
| 5    | pc       | program counter register                                                    | 16          |
| 6    | flags    | status register for boolean indicators reflecting outcome of recent ALU ops | 8           |

1. The processor has two general-purpose registers -- `a` and `b`
2. `fp`, is a compiler-use register to allow for the calling of functions
in the entire 16-bit address space
3. `x` is a memory index register that allows for the loading of data from
the entire 16-bit address space
4. `sp` is the stack pointer register, with a default base of 0x8000
5. `pc` is the program counter register, allowing for instructions in the entire 16-bit address space
6. `flags` is a bitmap that pokemon coliseumcontains information on previously executed ALU operations

#### Flag Table

| Flag Name | Purpose                                                            | Value        |
| --------- | ------------------------------------------------------------------ | ------------ |
| carry     | Indicates a carry out from the previous operation                  | `0b00000001` |
| zero      | Set if the result of the previous operation was zero               | `0b00000010` |
| of        | Overflow; set if the previous operation produced a signed overflow | `0b00000100` |
| n         | Negative; mirrors the most significant bit of the result           | `0b00001000` |

The upper 4 bits are reserved for any future flags that may prove to be useful

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

| class         | opcodes         | boundary           |
| ------------- | --------------- | ------------------ |
| reg-reg       | `add` - `cmpr`  | `REG_REG_MAX`      |
| immediate     | `movi` - `srli` | `IMM_MAX`          |
| relative jump | `jmp` - `jle`   | `ADDR_MAX`         |
| single-reg    | `push` - `pop`  | `SINGLE_REG_MAX`   |
| none          | `jmpf` - `halt` | (everything above) |

**Immediate Operations**
| 15 - 11 | 10 - 8 | 7 - 0 |
|---------|--------|-----------|
| opcode | reg | immediate |

**Jump Operations** (`jmp`, `jne`, `jeq`, `jgt`, `jge`, `jlt`, `jle`)
| 15 - 11 | 10 - 0 |
|---------|---------------|
| opcode | signed offset |

**Reg-Reg Operations**
| 15 - 11 | 10 - 8 | 7 - 3 | 2 - 0 |
|---------|--------|----------|-------|
| opcode | dst | reserved | src |

**Single-Reg Operations** (`push`, `pop`)
| 15 - 11 | 10 - 8 | 7 - 0 |
|---------|--------|----------|
| opcode | reg | reserved |

**None** (`jmpf`, `ret`, `halt`)
| 15 - 11 | 10 - 0 |
|---------|------------|  
| opcode | reserved |
