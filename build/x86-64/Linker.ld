ENTRY(_start32)

PHDRS {
	boot PT_LOAD FLAGS(R);
	text PT_LOAD FLAGS(RE);
	rodata PT_LOAD FLAGS(R);
	data PT_LOAD FLAGS(RW);
}

SECTIONS {
	. = 1M;

	__KERNEL_START__ = .;
	__KERNEL_VIRT_BASE__ = 0xffffffffc0000000;
	
	.boot : {
		. = ALIGN(8);
		KEEP(*(.boot_header))
		*(.boot)
		*(.boot_bss)
	} :boot

	. += __KERNEL_VIRT_BASE__;

	.text ALIGN(4K) : AT(ADDR(.text) - __KERNEL_VIRT_BASE__) {
		*(.text .text.*)
	} :text

	.rodata ALIGN(4K) : AT(ADDR(.rodata) - __KERNEL_VIRT_BASE__) {
		*(.rodata .rodata.*)
	} :rodata

	.data ALIGN(4K) : AT(ADDR(.data) - __KERNEL_VIRT_BASE__) {
		*(.data .data.*)
	} :data

	.bss ALIGN(4K) : AT(ADDR(.bss) - __KERNEL_VIRT_BASE__) {
		*(COMMON)
		*(.bss)
		*(.stack)
	} :data

	/* for debug stuff and additional useless sections. don't need to change __KERNEL_END__ */
	. -= __KERNEL_VIRT_BASE__;
	__KERNEL_END__ = .;
}
