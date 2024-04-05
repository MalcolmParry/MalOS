asm_source := $(shell find src/ -name *.asm)
asm_obj := $(patsubst src/%.asm, bin/int/%.o, $(asm_source))

$(asm_obj): bin/int/%.o : src/%.asm
	mkdir -p $(dir $@)
	nasm -f elf64 $(patsubst bin/int/%.o, src/%.asm, $@) -o $@

.PHONY: build
build: $(asm_obj)
	mkdir -p bin
	x86_64-elf-ld -n -o bin/kernel.bin -T linker.ld $(asm_obj)
	cp bin/kernel.bin iso/boot/kernel.bin
	grub-mkrescue /usr/lib/grub/i386-pc -o bin/kernel.iso iso

.PHONY: clean
clean:
	rm -rf bin
	rm iso/boot/kernel.bin