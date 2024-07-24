asm_source := $(shell find src/ -name *.asm)
asm_obj := $(patsubst src/%.asm, bin/int/%.asm.o, $(asm_source))

cpp_source := $(shell find src/ -name *.cpp)
cpp_obj := $(patsubst src/%.cpp, bin/int/%.cpp.o, $(cpp_source))

obj := $(asm_obj) $(cpp_obj)

$(asm_obj): bin/int/%.asm.o : src/%.asm
	mkdir -p $(dir $@)
	nasm -f elf64 $(patsubst bin/int/%.asm.o, src/%.asm, $@) -o $@

$(cpp_obj): bin/int/%.cpp.o : src/%.cpp
	mkdir -p $(dir $@)
	g++ -c $(patsubst bin/int/%.cpp.o, src/%.cpp, $@) -o $@ -ffreestanding -O3 -Wall -Wextra -fno-exceptions -fno-rtti -gdwarf-4 -masm=intel -m64

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
