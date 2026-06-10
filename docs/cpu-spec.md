# CPU design doc

This CPU is taking inspiration from several different existing CPUs, namely the 6502 processor
as well as some aspects of RISC-V and MIPS

## Registers

These are the same registers used in the 6502 processor + another general purpose register.
This register was added to make programming more convenient.

| Register | Purpose                                                                     | size in bits |
| -------- | --------------------------------------------------------------------------- | ------------ |
| a/r0     | accumulator register used for all arithemetic instructions                  | 8            |
| b/r1     | general purpose register                                                    | 8            |
| x/r2     | register for direct address indexing                                        | 8            |
| y/r3     | register for indirect address indexing (like dereferencing a pointer in C)  | 8            |
| sp/r4    | stack pointer register                                                      | 16           |
| pc/r5    | program counter register                                                    | 16           |
| flags/r6 | status register for boolean indicators reflecting outcome of recent ALU ops | 8            |

#### Flag Table

| Flag Name | Purpose                                                                                             | Value        |
| --------- | --------------------------------------------------------------------------------------------------- | ------------ |
| carry     | Indicates a carry out from the previous operation                                                   | `0b00000001` |
| zero      | Set if the result of the previous operation was zero                                                | `0b00000010` |
| i         | Interrupt disable; when set, maskable interrupts are ignored                                        | `0b00000100` |
| dec       | Decimal mode; when set, arithmetic operations use BCD encoding                                      | `0b00001000` |
| brk       | Set when a BRK instruction has been executed, distinguishing software interrupts from hardware IRQs | `0b00010000` |
| of        | Overflow; set if the previous operation produced a signed overflow                                  | `0b01000000` |
| n         | Negative; mirrors the most significant bit of the result                                            | `0b10000000` |

**Note:** Bit 5 (`0b00100000`) is unimplemented. On the original 6502 this bit
has no architectural meaning and always reads as 1. It is reserved for future
use.

## ISA

| inst | opcode | function                                                                                        |
| ---- | ------ | ----------------------------------------------------------------------------------------------- |
| add  | 00000  | Add two registers, storing the result in the destination register                               |
| addi | 00001  | Add an immediate value to r0                                                                    |
| sub  | 00010  | Subtract the value of one register from another, storing the result in the destination register |
| subi | 00011  | Subtract an immediate value from r0                                                             |
| mul  | 00100  | Multiply two registers, storing the result in the destination register                          |
| div  | 00101  | Divide one register by another, storing the result in the destination register                  |
| not  | 00110  | Bitwise complement of r0; flips every bit                                                       |
| or   | 00111  | Bitwise OR of r0 with an immediate value                                                        |
| ori  | 01000  | Bitwise OR of two registers, storing the result in the destination register                     |
| xor  | 01001  | Bitwise XOR of r0 with an immediate value                                                       |
| xori | 01010  | Bitwise XOR of two registers, storing the result in the destination register                    |
| and  | 01011  | Bitwise AND of r0 with an immediate value                                                       |
| andi | 01100  | Bitwise AND of two registers, storing the result in the destination register                    |
| srl  | 01101  | Logical shift r0 right by a register value                                                      |
| sra  | 01110  | Arithmetic shift r0 right by a register value                                                   |
| ld   | 01111  | Load a value from a memory address into r0                                                      |
| st   | 10000  | Store r0 at a memory address                                                                    |
| mov  | 10001  | Copy the value of one register into another                                                     |
| cmp  | 10010  | Compare r0 to an immediate value, updating flags                                                |
| cmpr | 10011  | Compare two registers, updating flags                                                           |
| jr   | 10100  | Jump to an address relative to PC by an immediate offset                                        |
| jne  | 10101  | Jump to an address if the previous cmp indicates not equal                                      |
| jeq  | 10110  | Jump to an address if the previous cmp indicates equal                                          |
| jgt  | 10111  | Jump to an address if the previous cmp indicates greater than                                   |
| jge  | 11000  | Jump to an address if the previous cmp indicates greater than or equal                          |
| jlt  | 11001  | Jump to an address if the previous cmp indicates less than                                      |
| jle  | 11010  | Jump to an address if the previous cmp indicates less than or equal                             |
| push | 11011  | Push a specified register onto the stack                                                        |
| pop  | 11100  | Pop from the stack into a specified register                                                    |
| call | 11101  | Push PC onto the stack and jump to the target address                                           |
| ret  | 11110  | Pop the return address from the stack and jump to it                                            |
| halt | 11111  | Stop program execution                                                                          |

**Note:** In all arithmetic operations, the first operand is the destination register.

**Immediate Operations**
| 15 - 11 | 10 - 8 | 7 - 0 |
|----------|--------|---------------|
| opcode | reg | immediate |

**Reg-Reg Operations**
| 15 - 11 | 10 - 8 | 7 - 3 | 2 - 0 |
|----------|--------|--------------|-------|
| opcode | dst | reserved | src |

**Single-Reg Operations**
| 15 - 11 | 10 - 8 | 7 - 0 |
|---------|--------|-------|
| opcode | reg | reserved |

**None**
| 15 - 11 | 10 - 8 - 0 |
|---------|------------|  
| opcode | reserved |
