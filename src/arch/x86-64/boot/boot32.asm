global _start32
global phys_multiboot_info
extern _start64
extern page_table_l4_virt
extern page_table_l3_virt
extern page_table_l2_virt

KERNEL_VIRT_BASE equ 0xffff_ffff_c000_0000
page_table_l4 equ page_table_l4_virt - KERNEL_VIRT_BASE
page_table_l3 equ page_table_l3_virt - KERNEL_VIRT_BASE
page_table_l2 equ page_table_l2_virt - KERNEL_VIRT_BASE

section .boot
bits 32
_start32:
	mov ebp, stack.top - KERNEL_VIRT_BASE
	mov esp, ebp

	mov [phys_multiboot_info - KERNEL_VIRT_BASE], ebx
	
	; check if loaded with multiboot2 loader
	cmp eax, 0x36d7_6289
	jne .no_multiboot

	; check if the cpu supports cpuid instruction
	pushfd
	pop eax
	mov ecx, eax
	xor eax, 1 << 21
	push eax
	popfd
	pushfd
	pop eax
	push ecx
	popfd
	cmp eax, ecx
	je .no_cpuid

	; check if long mode is supported (if have 64 bit cpu)
	mov eax, 0x8000_0000
	cpuid
	cmp eax, 0x8000_0001
	jb .no_long_mode

	mov eax, 0x8000_0001
	cpuid
	test edx, 1 << 29
	jz .no_long_mode

	; setup page tables
	xor ebx, ebx
	mov eax, page_table_l3
	or eax, 0b11 ; present, writable
	mov [page_table_l4], eax
	mov [page_table_l4 + 4], ebx
	mov [page_table_l4 + 511 * 8], eax
	mov [(page_table_l4 + 4) + 511 * 8], ebx

	mov eax, page_table_l2
	or eax, 0b11 ; present, writable
	mov [page_table_l3], eax
	mov [page_table_l3 + 4], ebx
	mov [page_table_l3 + 511 * 8], eax
	mov [(page_table_l3 + 4) + 511 * 8], ebx

	xor ecx, ecx
.loop:
	mov eax, 0x20_0000
	mul ecx
	or eax, 0b1000_0011
	mov [page_table_l2 + ecx * 8], eax
	mov [(page_table_l2 + 4) + ecx * 8], ebx

	inc ecx
	cmp ecx, 512
	jne .loop

	; enable paging
	mov eax, page_table_l4
	mov cr3, eax

	mov eax, cr4
	or eax, 1 << 5
	mov cr4, eax

	mov ecx, 0xc000_0080
	rdmsr
	or eax, 1 << 8
	wrmsr

	mov eax, cr0
	or eax, 1 << 31
	mov cr0, eax

	lgdt [gdt64.ptr]
	jmp gdt64.code:trampoline
.no_multiboot:
	mov eax, no_multiboot_str
	jmp error
.no_cpuid:
	mov eax, no_cpuid_str
	jmp error
.no_long_mode:
	mov eax, no_long_mode_str
	jmp error

error: ; void error(char* str: eax)
	mov edx, 0xb8000
	mov bh, 0x04
.loop:
	mov bl, [eax]
	cmp bl, 0
	je .end
	mov [edx], bx
	inc eax
	add edx, 2
	jmp .loop
.end:
	hlt
	jmp .end

bits 64
trampoline:
	mov rbp, stack.top
	mov rsp, rbp

	mov rax, _start64
	jmp rax

no_multiboot_str:
	db "The OS was not loaded with a multiboot 2 complient bootloader.", 0
no_cpuid_str:
	db "CPUID is not supported.", 0
no_long_mode_str:
	db "Long mode is not supported.", 0

gdt64:
	.null: equ $ - gdt64
		dq 0
	.code: equ $ - gdt64
		dq (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53)
	.ptr:
		dw $ - gdt64 - 1
		dq gdt64

section .bss
align 16
stack:
.bottom:
	resb 1024 * 16
.top:

section .data
phys_multiboot_info:
	dq 0
