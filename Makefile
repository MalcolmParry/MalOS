asm_source := $(shell find src/ -name *.asm)
asm_obj := $(patsubst src/%.asm, bin/int/asm/%.o, $(asm_source))

zig_obj := bin/int/zig/zig.o

obj := $(asm_obj) $(zig_obj)

$(asm_obj): bin/int/asm/%.o : src/%.asm
	mkdir -p $(dir $@)
	nasm -f elf64 $(patsubst bin/int/asm/%.o, src/%.asm, $@) -o $@

$(zig_obj): $(shell find src/ -name *.zig)
	mkdir -p bin/int/zig
	zig build-obj -O ReleaseSafe -target x86_64-freestanding src/Kernel/Main.zig -femit-bin=$(zig_obj) -freference-trace

.PHONY: build
build: $(obj)
	mkdir -p bin
	ld -n -gdwarf-4 -o bin/Kernel.elf -T Linker.ld $(obj)
	objcopy --only-keep-debug bin/Kernel.elf bin/Kernel.sym
	objcopy --strip-debug bin/Kernel.elf
	cp bin/Kernel.elf iso/boot/Kernel.elf
	grub-mkrescue /usr/lib/grub/i386-pc -o bin/Kernel.iso iso

.PHONY: clean
clean:
	rm -rf bin
	rm iso/boot/Kernel.elf
