global _start64
extern kernelEntry 

section .text
bits 64
_start64:
	xor ax, ax
	mov ss, ax
	mov ds, ax
	mov es, ax
	mov fs, ax
	mov gs, ax

	; sysv callconv requires 16 byte alignment before pushing return addr
	and rsp, ~15
	xor ebp, ebp
	; null return address so stack trace knows where to stop
	push 0
	jmp kernelEntry 
