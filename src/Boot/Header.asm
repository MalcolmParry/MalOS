section .multiboot
multiboot:
.start:
	dd 0xe852_50d6
	dd 0
	dd (.end - .start)
	dd 0x1_0000_0000 - (0xe852_50d6 + 0 + (.end - .start))

	dw 0
	dw 0
	dd 8
.end: