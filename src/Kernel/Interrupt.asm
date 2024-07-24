%macro pusha 0
push rax
push rbx
push rcx
push rdx
push rsi
push rdi
%endmacro

%macro popa 0
pop rdi
pop rsi
pop rdx
pop rcx
pop rbx
pop rax
%endmacro

section .text
bits 64
extern irq_undef
global _irq_undef
_irq_undef:
	pusha

	call irq_undef

	popa
	iretq
