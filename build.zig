const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

const output_sub_dir = "x86-64/";
const asm_source_path = "src/arch/x86-64/";
const iso_dir_path = "build/x86-64/iso/";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_arch = .x86_64,
        .ofmt = .elf,
    });

    const iso = try addBuildIsoStep(b, optimize, target);
    try addRunIsoStep(b, iso);
}

fn addBuildIsoStep(b: *Build, optimize: std.builtin.OptimizeMode, target: Build.ResolvedTarget) !Build.LazyPath {
    const kernel_compile = b.addObject(.{
        .name = "kernel.elf",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
            .omit_frame_pointer = false,
        }),
    });
    kernel_compile.bundle_compiler_rt = true;

    const iso_install_dir = b.addInstallDirectory(.{ .source_dir = b.path(iso_dir_path), .install_dir = .{ .custom = output_sub_dir ++ "iso" }, .install_subdir = "" });
    const link = b.addSystemCommand(&.{ "ld", "-n", "-g", "-T", "build/x86-64/linker.ld" });
    link.addArg("-o");
    const kernel = link.addOutputFileArg("kernel.elf");
    link.addFileInput(kernel_compile.getEmittedBin());
    link.addFileArg(kernel_compile.getEmittedBin());
    try linkAssembly(b, link);
    link.step.dependOn(&kernel_compile.step);

    const multiboot_check = b.addSystemCommand(&.{ "grub-file", "--is-x86-multiboot2" });
    multiboot_check.addFileInput(kernel);
    multiboot_check.addFileArg(kernel);

    const kernel_install = b.addInstallFile(kernel, output_sub_dir ++ "iso/boot/kernel.elf");
    kernel_install.step.dependOn(&iso_install_dir.step);
    kernel_install.step.dependOn(&multiboot_check.step);

    const symbol_table_build = try b.allocator.create(GenSymTabStep);
    symbol_table_build.* = .init(b, kernel);
    symbol_table_build.step.dependOn(&link.step);

    const iso_build = b.addSystemCommand(&.{ "grub-mkrescue", "/usr/lib/grub/x86_64-efi" });
    iso_build.addArg("-o");
    const iso = iso_build.addOutputFileArg(output_sub_dir ++ "kernel.iso");
    iso_build.addArg(b.fmt("{s}/{s}", .{ b.install_prefix, output_sub_dir ++ "iso" }));
    iso_build.addFileInput(kernel);
    iso_build.step.dependOn(&kernel_install.step);
    iso_build.step.dependOn(&symbol_table_build.step);

    var iso_dir = try std.fs.cwd().openDir(iso_dir_path, .{ .iterate = true });
    defer iso_dir.close();
    var iter = try iso_dir.walk(b.allocator);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        iso_build.addFileInput(b.path(b.fmt("{s}/{s}", .{ iso_dir_path, entry.path })));
    }

    const iso_install = b.addInstallFile(iso, output_sub_dir ++ "kernel.iso");
    iso_install.step.dependOn(&iso_build.step);
    b.getInstallStep().dependOn(&iso_install.step);

    return iso;
}

fn linkAssembly(b: *Build, link: *Build.Step.Run) !void {
    var asm_source_dir = try std.fs.cwd().openDir(asm_source_path, .{ .iterate = true });
    defer asm_source_dir.close();
    var iter = try asm_source_dir.walk(b.allocator);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".asm")) continue;

        const source_file = b.path(b.fmt("{s}/{s}", .{ asm_source_path, entry.path }));
        const asm_compile = b.addSystemCommand(&.{
            "nasm",
            "-f",
            "elf64",
        });

        asm_compile.addFileInput(source_file);
        asm_compile.addFileArg(source_file);
        const asm_object = asm_compile.addPrefixedOutputFileArg("-o", b.fmt("{s}.o", .{entry.basename}));

        link.addFileArg(asm_object);
        link.step.dependOn(&asm_compile.step);
    }
}

fn addRunIsoStep(b: *Build, iso: Build.LazyPath) !void {
    const run_step = b.step("run", "Run the iso in qemu");
    const run = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-display",
        "gtk",
        "-m",
        "16M",
        "-smp",
        "4",
        "-cdrom",
    });
    run.addFileArg(iso);
    if (b.option(bool, "gdb", "Use gdb with qemu") orelse false)
        run.addArgs(&.{ "-s", "-S" });

    run.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run.step);
}

const GenSymTabStep = struct {
    step: Build.Step,
    kernel_elf: Build.LazyPath,

    const Symbol = @import("src/panic.zig").Symbol;

    fn init(b: *Build, kernel_elf: Build.LazyPath) @This() {
        return .{
            .step = .init(.{
                .owner = b,
                .id = .custom,
                .name = "GenSymTabStep",
                .makeFn = make,
            }),
            .kernel_elf = kernel_elf,
        };
    }

    fn make(step: *Build.Step, opts: Build.Step.MakeOptions) anyerror!void {
        const this: *@This() = @fieldParentPtr("step", step);
        const b = step.owner;
        var man = b.graph.cache.obtain();
        defer man.deinit();
        _ = opts;

        if (b.verbose) std.log.info("generating symbol table", .{});

        var buffer: [128]u8 = undefined;
        const kernel_path = this.kernel_elf.generated.file.path orelse return error.NoKernel;
        const kernel = try std.fs.cwd().openFile(kernel_path, .{});
        _ = try man.addOpenedFile(this.kernel_elf.getPath3(b, step), kernel, null);
        defer kernel.close();

        if (try step.cacheHitAndWatch(&man)) {
            step.result_cached = true;
            return;
        }

        const module_dir = b.fmt("{s}/{s}", .{ b.install_prefix, output_sub_dir ++ "iso/boot/" });
        try std.fs.cwd().makePath(module_dir);
        const symbol_file = try std.fs.cwd().createFile(b.fmt("{s}/symbol_table.mod", .{module_dir}), .{ .truncate = true });
        defer symbol_file.close();
        const symbol_names_file = try std.fs.cwd().createFile(b.fmt("{s}/symbol_names.mod", .{module_dir}), .{ .truncate = true });
        defer symbol_names_file.close();

        var symbol_file_buffer: [64]u8 = undefined;
        var symbol_file_name_buffer: [64]u8 = undefined;
        var symbol_file_writer = symbol_file.writer(&symbol_file_buffer);
        var symbol_file_name_writer = symbol_names_file.writer(&symbol_file_name_buffer);
        var name_index: usize = 0;

        var reader = kernel.reader(&buffer);
        const header = try std.elf.Header.read(&reader.interface);
        std.debug.assert(header.is_64);
        const sections = try b.allocator.alloc(std.elf.Elf64_Shdr, header.shnum);

        var iter = header.iterateSectionHeaders(&reader);
        while (try iter.next()) |shdr| {
            sections[iter.index - 1] = shdr;
        }

        var own_symbols = std.ArrayList(Symbol).empty;
        defer own_symbols.deinit(b.allocator);

        for (sections) |section| {
            if (section.sh_type != std.elf.SHT_SYMTAB) continue;
            const strtab_header = &sections[section.sh_link];
            const strtab_offset = strtab_header.sh_offset;

            std.debug.assert(section.sh_entsize == @sizeOf(std.elf.Elf64_Sym));
            const symbol_count = section.sh_size / @sizeOf(std.elf.Elf64_Sym);
            try own_symbols.ensureTotalCapacity(b.allocator, own_symbols.items.len + symbol_count);

            for (0..symbol_count) |i| {
                try reader.seekTo(section.sh_offset + i * @sizeOf(std.elf.Elf64_Sym));
                var sym: std.elf.Elf64_Sym = undefined;
                const sym_slice = @as([*]std.elf.Elf64_Sym, @ptrCast(&sym))[0..1];
                try reader.interface.readSliceEndian(std.elf.Elf64_Sym, sym_slice, .little);
                // if (sym.st_type() != std.elf.STT_FUNC) continue;

                try reader.seekTo(strtab_offset + sym.st_name);
                const name = try reader.interface.takeDelimiter(0) orelse continue;
                try symbol_file_name_writer.interface.writeAll(name);

                own_symbols.appendAssumeCapacity(.{
                    .addr = sym.st_value,
                    .name_offset = @intCast(name_index),
                    .name_len = @intCast(name.len),
                });
                name_index += name.len;
            }
        }

        std.mem.sort(Symbol, own_symbols.items, @as(u8, 0), struct {
            fn lessThan(_: u8, lhs: Symbol, rhs: Symbol) bool {
                return lhs.addr < rhs.addr;
            }
        }.lessThan);

        try symbol_file_writer.interface.writeSliceEndian(Symbol, own_symbols.items, .little);
        try symbol_file_writer.interface.flush();
        try symbol_file_name_writer.interface.flush();
    }
};
