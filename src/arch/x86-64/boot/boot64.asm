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

	mov rax, cr4
	; allow simd stuff, enable global pages
	or rax, (1 << 9) | (1 << 7)
	mov cr4, rax
	
	; have to use call instruction instead of jmp bc
	; 16 byte aligned stack is required for some instructions
	; and zig assumes that rsp is 16 byte aligned prior to call
	; and call adds 8 bytes to stack
	xor rbp, rbp
	call kernelEntry 

	; definitely shouldn't happen
	; bc KernelMain is noreturn
	cli
.halt:
	hlt
	jmp .halt

section .rodata
; testing if paging can stop code from executing here
global functionInRodata
functionInRodata:
	ret
