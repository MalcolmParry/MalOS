global _start64
extern kernelEntry 
global _start64

section .text
bits 64
_start64:
	xor ax, ax
	mov ss, ax
	mov ds, ax
	mov es, ax
	mov fs, ax
	mov gs, ax

	mov rax, cr0
	; write protect
	or rax, (1 << 16)
	mov cr0, rax

	mov rax, cr4
	; allow simd stuff, enable global pages
	or rax, (1 << 9) | (1 << 7)
	mov cr4, rax
	
	; sysv callconv requires 16 byte alignment before pushing return addr
	and rsp, ~15
	xor ebp, ebp
	; null return address so stack trace knows where to stop
	push 0
	jmp kernelEntry 
