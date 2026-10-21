MAGIC equ 0xe852_50d6
ARCH_i386 equ 0
LENGTH equ (multiboot_end - multiboot)

TAG_END equ 0
TAG_INFORMATION_REQUEST equ 1
TAG_ADDRESS equ 2
TAG_ENTRY_ADDRESS equ 3
TAG_CONSOLE_FLAGS equ 4
TAG_FRAMEBUFFER equ 5
TAG_MODULE_ALIGN equ 6
TAG_EFI_BS equ 7
TAG_ENTRY_ADDRESS_EFI32 equ 8
TAG_ENTRY_ADDRESS_EFI64 equ 9
TAG_RELOCATABLE equ 10

INFO_MODULES equ 3
INFO_MMAP equ 6
INFO_ELF_SECTIONS equ 9

section .boot_header
align 8
multiboot:
	dd MAGIC
	dd ARCH_i386
	dd LENGTH
	dd 0x1_0000_0000 - (MAGIC + ARCH_i386 + LENGTH)

align 8
info_tag:
.start:
	dw TAG_INFORMATION_REQUEST ; tag
	dw 0 ; flags
	dd (.end - .start) ; length
	dd INFO_MODULES
	dd INFO_MMAP
	dd INFO_ELF_SECTIONS
.end:

align 8
fb_tag:
.start:
	dw TAG_FRAMEBUFFER
	dw 1
	dd (.end - .start)
	dd 0
	dd 0
	dd 32
.end:

align 8
align_tag:
.start:
	dw TAG_MODULE_ALIGN ; tag
	dw 0 ; flags
	dd (.end - .start) ; length
.end:

align 8
end_tag:
.start:
	dw TAG_END ; tag
	dw 0 ; flags
	dd (.end - .start) ; length
.end:
multiboot_end:
