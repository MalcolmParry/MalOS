section .text
bits 64
global outb
outb:
	mov edx, edi
	mov eax, esi

	out dx, al
	ret

global inb
inb:
	mov edx, edi
	xor rax, rax

	in al, dx
	ret