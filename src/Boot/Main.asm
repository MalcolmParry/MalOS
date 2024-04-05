global _start

section .text
bits 32
_start:
    mov al, 'O'
    mov ah, 0x02
    mov [0xb8000], ax
    mov al, 'R'
    mov [0xb8002], ax

    hlt