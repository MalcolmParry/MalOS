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
extern isr_undef
global isr_undef_wrap
isr_undef_wrap:
	pusha

	call isr_undef

	popa
	iretq