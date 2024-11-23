ENTRY(_start32)

SECTIONS {
	. = 1M;

	__KERNEL_START__ = .;
	__KERNEL_VIRT_BASE__ = 0xffffffffc0000000;
	
	.boot : {
		. = ALIGN(8);
		KEEP(*(.boot_header))
		*(.boot)
		*(.boot_bss)
	}

	. += __KERNEL_VIRT_BASE__;

	.text ALIGN(4K) : AT(ADDR(.text) - __KERNEL_VIRT_BASE__) {
		*(.text)
	}

	.rodata : AT(ADDR(.rodata) - __KERNEL_VIRT_BASE__) {
		*(.rodata .rodata.*)
	}

	.data : AT(ADDR(.data) - __KERNEL_VIRT_BASE__) {
		*(.data .data.*)
	}

	.bss : AT(ADDR(.bss) - __KERNEL_VIRT_BASE__) {
		*(COMMON)
		*(.bss)
		*(.stack)
	}

	__KERNEL_END__ = .;

	/* for debug stuff and additional useless sections. don't need to change __KERNEL_END__ */
	. -= __KERNEL_VIRT_BASE__;
}
