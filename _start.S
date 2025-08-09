// _start.S 

// Put following code in the input section .text.entry.
// KEEP(*(.text.entry)) in linker.ld ensures this code (the entry stub)
// is never garbage-collected and ends up at the beginning of the output .text.
.section .text.entry
// Export the symbol _start.
// This makes _start visible to the linker as the program’s entry
// (the script has ENTRY(_start)), so linking and tools know where execution begins.
.global _start
_start:
    la sp, _stack_top // la (“load address”) is a pseudo-instruction
    call main
1: j 1b  // Forever loop if main returns