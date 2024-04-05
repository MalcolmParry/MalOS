ENTRY(_start32)

SECTIONS {
	. = 1M;

	.boot : {
		KEEP(*(.multiboot))
	}

	.text : {
		*(.text)
	}
}