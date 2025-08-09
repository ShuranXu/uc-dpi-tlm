/*
With this script, the firmware code, rodata, data, and bss all live in
one RAM region at 0x8000_0000, matching the address we mapped in the ISS (uc_mem_map at RAM_BASE).
This script is a solid fit for our Unicorn-based, RAM-only firmware execution at 0x8000_0000.
*/

/*
Sets the entry symbol for the ELF to _start:
- The linker keeps anything reachable from _start (important with --gc-sections).
- Debuggers/sims treat _start as the default PC if none is specified.
*/

ENTRY(_start)
/* Declares a memory region named RAM. */
MEMORY {
    RAM (rwx): ORIGIN = 0x80000000, LENGTH = 0x00200000  /* 2 MiB */
}

SECTIONS {
    /* Sets the location counter (.) to the start of RAM. */
    /* From here on, output sections are placed starting at 0x8000_0000 unless redirected. */
    . = ORIGIN(RAM);
    /* Creates the output section .text, placing it in RAM. */
    /* KEEP(*(.text.entry)) — keep any .text.entry (e.g., _start) even if --gc-sections would drop it. */
    /* *(.text*) — all code. */
    /* *(.rodata*) — read-only data (literals, const tables) placed with code */
    .text : {
        KEEP(*(.text.entry))   /* keep startup _start */
        *(.text*)              /* all code */
        *(.rodata*)            /* consts/literals */
      } > RAM
    /* Output .data (initialized, writable data) lives in RAM. */
    .data : {*(.data*)} > RAM
    /* Output .bss (zero-init data) also in RAM.*/
    /* *(COMMON) pulls in “common” symbols (uninitialized globals that some compilers emit) and merges them into .bss. */
    .bss : {
        *(.bss*)
        *(COMMON)
    } > RAM
    /* Mark end-of-image & define stack */
    _end = .;
    /* Moves the location counter to the end of the RAM region (0x8000_0000 + 2 MiB) */
    /* We can use this to compute a convenient constant for the top of stack. */
    . = ORIGIN(RAM) + LENGTH(RAM);
    /* Defines a symbol _stack_top at the current location (end of RAM). */
    /* PROVIDE means “define it only if nothing else already did.” */
    /* startup.S can do la sp, _stack_top to place the stack at the top of RAM and grow downward. */
    PROVIDE(_stack_top = .);
}