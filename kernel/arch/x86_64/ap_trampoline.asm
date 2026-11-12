org 0
bits 16
	cli
	mov dx, 0x3f8
	mov al, 'a'
	out dx, al
	mov al, 'p'
	out dx, al
	mov al, 0x0a
	out dx, al
.loop:
	hlt
	jmp .loop
