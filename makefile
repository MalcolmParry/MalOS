.PHONY: build
build:
	@make -C build/x86-64/ build

.PHONY: run
run:
	@make -C build/x86-64/ run

.PHONY: debug
debug:
	@make -C build/x86-64/ debug

.PHONY: clean
clean:
	@rm -rf bin
	@rm build/x86-64/iso/boot/Kernel.elf 2> /dev/null || :
	@rm build/x86-64/iso/boot/SymTable.mod 2> /dev/null || :
