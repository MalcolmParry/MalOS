proj = ../../

asm_source := $(shell find $(proj)/src/arch/x86-64/ -name *.asm)
asm_obj := $(patsubst $(proj)/src/%.asm, $(proj)/bin/int/asm/%.o, $(asm_source))

zig_obj := $(proj)/bin/int/zig.o

obj := $(asm_obj) $(zig_obj)

$(asm_obj): $(proj)/bin/int/asm/%.o : $(asm_source)
	@echo "Compiling file $(patsubst $(proj)/bin/int/asm/%.o, src/%.asm, $@)"
	@mkdir -p $(dir $@)
	@nasm -f elf64 $(patsubst $(proj)/bin/int/asm/%.o, $(proj)/src/%.asm, $@) -o $@

$(zig_obj): $(shell find $(proj)/src/ -name *.zig)
	@echo "Compiling zig files"
	@mkdir -p $(proj)/bin/int
	@zig build-obj \
		-O Debug \
		-fllvm \
		-target x86_64-freestanding \
		$(proj)/src/main.zig \
		-femit-bin=$(zig_obj) \
		-freference-trace \
		-mcmodel=kernel \
		-fcompiler-rt

.PHONY: build
build: $(obj)
	@mkdir -p $(proj)/bin
	@echo "Linking $(patsubst $(proj)/%, %, $(obj))"
	@ld -n -g -o $(proj)/bin/kernel.elf -T ./linker.ld $(obj)
	@objcopy --strip-debug $(proj)/bin/kernel.elf ./iso/boot/kernel.elf
	@echo "Making iso"
	@grub-mkrescue /usr/lib/grub/i386-efi -o $(proj)/bin/kernel.iso $(proj)/build/x86-64/iso 2> /dev/null
	@echo "Success"

run_cmd = qemu-system-x86_64 \
	-drive file=$(proj)/bin/kernel.iso,format=raw \
	-display gtk \
	-m 2G \
	-smp 4

.PHONY: run
run:
	$(run_cmd)

.PHONY: debug
debug:
	$(run_cmd) -S -s
