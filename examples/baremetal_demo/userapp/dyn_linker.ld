ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
  dynamic PT_DYNAMIC FLAGS(4);
}

SECTIONS
{
  . = 0;

  .text : ALIGN(0x1000)
  {
    *(.text*)
    *(.rodata*)
    *(.eh_frame*)
    *(.note*)
    *(.plt*)
  } :text

  .hash : { *(.hash) } :text
  .dynsym : { *(.dynsym) } :text
  .dynstr : { *(.dynstr) } :text
  .gnu.hash : { *(.gnu.hash) } :text
  .rela.dyn : { *(.rela.dyn) } :text
  .rela.plt : { *(.rela.plt) } :text

  . = ALIGN(0x1000);

  .dynamic : { *(.dynamic) } :data :dynamic
  .got : { *(.got*) } :data
  .data : { *(.data*) } :data
  .bss : { *(.bss*) *(COMMON) } :data
}
