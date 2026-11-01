ENTRY(_start32)
SECTIONS
{
    . = 1M;
    __kernel_start = .;
    .note.Xen : ALIGN(4)
    {
        KEEP(*(.note.Xen))
    }

    .text : ALIGN(4K)
    {
        *(.boot.text)
        *(.text .text.*)
    }
    .rodata : ALIGN(4K)
    {
        *(.rodata .rodata.*)
    }
    .data : ALIGN(4K)
    {
        *(.data .data.*)
    }
    .bss : ALIGN(4K)
    {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
        *(.boot.bss)
    }
    . = ALIGN(4K);
    __kernel_end = .;
}
