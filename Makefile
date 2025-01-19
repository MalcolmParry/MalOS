#.DEFAULT_GOAL := build_x86-64

x86-64_asm_source := $(shell find src/Arch/x86-64/ -name *.asm)
x86-64_asm_obj := $(patsubst src/%.asm, bin/int/asm/%.o, $(x86-64_asm_source))

zig_obj := bin/int/zig/zig.o

x86-64_obj := $(x86-64_asm_obj) $(zig_obj)

$(x86-64_asm_obj): bin/int/asm/%.o : src/%.asm
	@echo "Compiling file $(patsubst bin/int/asm/%.o, src/%.asm, $@)"
	@mkdir -p $(dir $@)
	@nasm -f elf64 $(patsubst bin/int/asm/%.o, src/%.asm, $@) -o $@

$(zig_obj): $(shell find src/ -name *.zig)
	@echo "Compiling zig files"
	@mkdir -p bin/int/zig
	@zig build-obj -O ReleaseSafe -target x86_64-freestanding src/Main.zig -femit-bin=$(zig_obj) -freference-trace -mcmodel=kernel -fcompiler-rt

.PHONY: build_x86-64
build_x86-64: $(x86-64_obj)
	@mkdir -p bin
	@echo "Linking $(x86-64_obj)"
	@ld -n -g -o bin/Kernel.elf -T build/x86-64/Linker.ld $(x86-64_obj)
	@objcopy --only-keep-debug bin/Kernel.elf bin/Kernel.sym
	@objcopy --strip-debug bin/Kernel.elf
	@cp bin/Kernel.elf build/x86-64/iso/boot/Kernel.elf
	@echo "Making iso"
	@grub-mkrescue /usr/lib/grub/i386-pc -o bin/Kernel.iso build/x86-64/iso 2> /dev/null
	@echo "Success"

x86-64_run_cmd = qemu-system-x86_64 -drive file=bin/Kernel.iso,format=raw -display gtk -m 1G

.PHONY: run_x86-64
run_x86-64:
	$(x86-64_run_cmd)

.PHONY: debug_x86
debug_x86-64:
	$(x86-64_run_cmd) -S -s

.PHONY: clean
clean:
	@rm -rf bin
	@rm build/x86-64/iso/boot/Kernel.elf 2> /dev/null || :
	@rm build/x86-64/iso/boot/SymTable.mod 2> /dev/null || :

.PHONY: build
build: build_x86-64

.PHONY: run
run: run_x86-64

.PHONY: debug
debug: debug_x86-64
