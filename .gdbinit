set disassembly-flavor intel
set  disassemble-next-line on
show  disassemble-next-line

set arch i386:x86-64:intel
target remote localhost:1234
symbol-file bin/kernel.elf

define cdump
	dump memory dump.bin ($arg0) ($arg0 + $arg1)
end
