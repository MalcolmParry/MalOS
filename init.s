.intel_syntax noprefix
.code64

.section .text
.global _start
_start:
	int 0x80
.loop:
	pause
	jmp .loop 

.section .rodata
	.ascii "hello world"
