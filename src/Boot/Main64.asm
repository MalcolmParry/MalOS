global _start64
extern kernel_main

section .text
bits 64
int_handler:
	mov al, 'A'
	mov ah, 0x02
	mov [0xb8000], ax
	hlt

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
	
	cli

	call kernel_main
	%if 0
	lidt [idtr]
	mov rax, int_handler
	mov [idt + 49*16], ax
	mov word [idt + 49*16 + 2], 8
	mov word [idt + 49*16 + 4], 0x8e00
	shr rax, 16
	mov [idt + 49*16 + 6], ax
	shr rax, 16
	mov [idt + 49*16 + 8], rax
	%endif

	int 49

	hlt

section .data
idt:
	times (50 * 16) db 0
idtr:
	dw (50*16)-1
	dq idt

global error
error:
	db 0