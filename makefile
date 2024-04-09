asm_source := $(shell find src/ -name *.asm)
asm_obj := $(patsubst src/%.asm, bin/int/%.o, $(asm_source))

cpp_source := $(shell find src/ -name *.cpp)
cpp_obj := $(patsubst src/%.cpp, bin/int/%.o, $(cpp_source))

obj := $(asm_obj) $(cpp_obj)

$(asm_obj): bin/int/%.o : src/%.asm
	mkdir -p $(dir $@)
	nasm -f elf64 $(patsubst bin/int/%.o, src/%.asm, $@) -o $@

$(cpp_obj): bin/int/%.o : src/%.cpp
	mkdir -p $(dir $@)
	x86_64-elf-g++ -c $(patsubst bin/int/%.o, src/%.cpp, $@) -o $@ -ffreestanding -O3 -Wall -Wextra -fno-exceptions -fno-rtti -gdwarf-4 -masm=intel -m64

.PHONY: build
build: $(obj)
	mkdir -p bin
	x86_64-elf-ld -n -gdwarf-4 -o bin/kernel.elf -T linker.ld $(obj)
	objcopy --only-keep-debug bin/kernel.elf bin/kernel.sym
	objcopy --strip-debug bin/kernel.elf
	cp bin/kernel.elf iso/boot/kernel.elf
	grub-mkrescue /usr/lib/grub/i386-pc -o bin/kernel.iso iso

.PHONY: clean
clean:
	rm -rf bin
	rm iso/boot/kernel.elf