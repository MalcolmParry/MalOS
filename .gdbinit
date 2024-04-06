set disassembly-flavor intel
set  disassemble-next-line on
show  disassemble-next-line

set arch i386:x86-64:intel
target remote localhost:1234
symbol-file bin/kernel.sym