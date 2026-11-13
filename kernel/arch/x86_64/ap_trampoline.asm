org 0
bits 16
	cli
	cld

	mov ax, cs
	mov ds, ax
	movzx ebx, ax
	shl ebx, 4

	lea eax, [ebx + gdt]
	mov [gdt.base], eax

	lidt [idt]

	mov eax, (1 << 5) | (1 << 7) | (1 << 9)
	mov cr4, eax

	mov eax, [param_cr3]
	mov cr3, eax

	mov ecx, 0xc000_0080
	rdmsr
	or eax, (1 << 8) | (1 << 11)
	wrmsr

	mov eax, cr0
	and eax, ~((1 << 30) | (1 << 29))
	or eax, (1 << 0) | (1 << 16) | (1 << 31)
	mov cr0, eax

	lgdt [gdt.pointer]
	lea eax, [ebx + long_mode]
	mov [jmp_ptr], eax
	o32 jmp far [jmp_ptr]
jmp_ptr:
	dd 0
	dw 8

bits 64
long_mode:
	mov ax, 16
	mov ds, ax
	mov ss, ax

	mov rsp, [rel param_sp]
	mov rax, [rel param_entry]
	mov [rel param_started], qword 1

	push 0
	xor ebp, ebp
	jmp rax

gdt:
.null:
	dq 0x0000_0000_0000_0000
.code:
	dq 0x0020_9a00_0000_0000
	dq 0x0000_9200_0000_0000
align 4
	dw 0
.pointer:
	dw $ - gdt - 1
.base:
	dd gdt

align 4
idt:
	dw 0
	dd 0

times (0xd00 - ($ - $$)) db 0
param_cr3:
	dq 0
param_sp:
	dq 0
param_entry:
	dq 0
param_started:
	dq 0
