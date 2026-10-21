.intel_syntax noprefix
.code64

.section .text
.global _start
_start:
	xor eax, eax
	lea rdi, [rip + msg]
	mov esi, 12
	int 0x80
.loop:
	pause
	jmp .loop 

.section .rodata
msg:
	.ascii "hello world"
	.byte 0x0a
