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
	mov byte [error], 'A'
	call kernel_main

	hlt

section .data
global error
error:
	db 0