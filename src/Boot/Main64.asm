global _start64
extern kernel_main

section .text
bits 64
_start64:
	xor ax, ax
	mov ss, ax
	mov ds, ax
	mov es, ax
	mov fs, ax
	mov gs, ax

	mov rax, cr4
	or rax, 1 << 9
	mov cr4, rax

	call kernel_main

	hlt

section .data
global error
error:
	db 0

section .bss
global istack
global istack.bottom
global istack.top

istack:
.bottom:
	resb 1024
.top: