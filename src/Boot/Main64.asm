global _start64
extern KernelMain

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

	jmp KernelMain

halt:
	hlt
	jmp halt

section .data
global error
error:
	db 0
