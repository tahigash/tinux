ENTRY(_start32)
SECTIONS
{
    . = 1M;
    __kernel_start = .;
    .text BLOCK(4K) : ALIGN(4K)
    {
        KEEP(*(.note.Xen))
        *(.boot.text)
        *(.text .text.*)
    }
    .rodata BLOCK(4K) : ALIGN(4K)
    {
        *(.rodata .rodata.*)
    }
    .data BLOCK(4K) : ALIGN(4K)
    {
        *(.data .data.*)
    }
    .bss BLOCK(4K) : ALIGN(4K)
    {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
        *(.boot.bss)
    }
    . = ALIGN(4K);
    __kernel_end = .;
}
