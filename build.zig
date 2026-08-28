const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

const output_sub_dir = "x86_64/";
const asm_source_path = "src/arch/x86_64/";
const iso_dir_path = "build/x86_64/iso/";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_arch = .x86_64,
        .ofmt = .elf,
        .cpu_model = .baseline,
    });

    const iso = try addBuildIsoStep(b, optimize, target);
    try addRunIsoStep(b, iso);
}

fn addBuildIsoStep(b: *Build, optimize: std.builtin.OptimizeMode, target: Build.ResolvedTarget) !Build.LazyPath {
    const grub_dir = b.graph.environ_map.get("GRUB_DIR") orelse "/usr/lib/grub/";

    const debug_info = switch (optimize) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => true,
    };

    const kernel_compile = b.addObject(.{
        .name = "kernel.elf",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
            .single_threaded = true,
            .strip = !debug_info,
            .omit_frame_pointer = !debug_info,
        }),
    });
    kernel_compile.bundle_compiler_rt = true;

    const iso_install_dir = b.addInstallDirectory(.{ .source_dir = b.path(iso_dir_path), .install_dir = .{ .custom = output_sub_dir ++ "iso" }, .install_subdir = "" });
    const link = b.addSystemCommand(&.{
        // zig fmt: off
        "ld",
        "-n",
        "--gc-sections",
        "-T", "build/x86_64/linker.ld",
        "-z", "noexecstack",
        // zig fmt: on
    });
    switch (debug_info) {
        true => link.addArg("-g"),
        false => link.addArg("-s"),
    }

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

    const symbol_table_build = GenSymTabStep.init(b, kernel);

    const iso_build = b.addSystemCommand(&.{
        "grub-mkrescue",
        b.fmt("{s}/i386-pc", .{grub_dir}),
    });
    iso_build.addArg("-o");
    const iso = iso_build.addOutputFileArg(output_sub_dir ++ "kernel.iso");
    iso_build.addArg(b.fmt("{s}/{s}", .{ b.install_prefix, output_sub_dir ++ "iso" }));
    iso_build.addFileInput(kernel);
    iso_build.expectStdErrMatch(" completed successfully.");
    iso_build.step.dependOn(&kernel_install.step);
    iso_build.step.dependOn(&symbol_table_build.step);

    var iso_dir = try std.Io.Dir.cwd().openDir(b.graph.io, iso_dir_path, .{ .iterate = true });
    defer iso_dir.close(b.graph.io);
    var iter = try iso_dir.walk(b.allocator);
    defer iter.deinit();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        iso_build.addFileInput(b.path(b.fmt("{s}/{s}", .{ iso_dir_path, entry.path })));
    }

    const iso_install = b.addInstallFile(iso, output_sub_dir ++ "kernel.iso");
    iso_install.step.dependOn(&iso_build.step);
    b.getInstallStep().dependOn(&iso_install.step);

    const test_step = b.step("test", "run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
            }),
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    return iso;
}

fn linkAssembly(b: *Build, link: *Build.Step.Run) !void {
    var asm_source_dir = try std.Io.Dir.cwd().openDir(b.graph.io, asm_source_path, .{ .iterate = true });
    defer asm_source_dir.close(b.graph.io);

    var iter = try asm_source_dir.walk(b.allocator);
    defer iter.deinit();
    while (try iter.next(b.graph.io)) |entry| {
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
        // zig fmt: off
        "qemu-system-x86_64",
        "-display", "gtk",
        "-nodefaults",
        "-serial", "vc",
        // "-vga", "std",
        "-m", "32M",
        "-smp", "4",
        "-drive", "file=zig-out/disk.img,format=raw,if=ide",
        "-cdrom",
        // zig fmt: on
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

    fn init(b: *Build, kernel_elf: Build.LazyPath) *@This() {
        const this = b.allocator.create(GenSymTabStep) catch @panic("oom");
        this.* = .{
            .step = .init(.{
                .owner = b,
                .id = .custom,
                .name = "generate symbol table",
                .makeFn = make,
            }),
            .kernel_elf = kernel_elf,
        };

        kernel_elf.addStepDependencies(&this.step);
        return this;
    }

    fn make(step: *Build.Step, opts: Build.Step.MakeOptions) anyerror!void {
        const this: *@This() = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const alloc = b.allocator;
        const cwd = std.Io.Dir.cwd();
        var man = b.graph.cache.obtain();
        defer man.deinit();
        _ = opts;

        var buffer: [2048]u8 = undefined;
        const kernel_path = this.kernel_elf.generated.file.path orelse return error.NoKernel;
        const kernel = try cwd.openFile(io, kernel_path, .{});
        _ = try man.addOpenedFile(this.kernel_elf.getPath3(b, step), kernel, null);
        defer kernel.close(io);

        if (try step.cacheHitAndWatch(&man)) {
            if (b.verbose) std.log.info("symbol table cached", .{});
            step.result_cached = true;
            return;
        }

        if (b.verbose) std.log.info("generating symbol table", .{});

        var reader = kernel.reader(io, &buffer);
        const header = try std.elf.Header.read(&reader.interface);
        if (!header.is_64) return error.Failed;
        const sections = try b.allocator.alloc(std.elf.Elf64_Shdr, header.shnum);

        var iter = header.iterateSectionHeaders(&reader);
        while (try iter.next()) |shdr| {
            sections[iter.index - 1] = shdr;
        }

        var own_syms = std.ArrayList(Symbol).empty;
        defer own_syms.deinit(alloc);

        var elf_syms: std.ArrayList(std.elf.Elf64.Sym) = .empty;
        defer elf_syms.deinit(alloc);

        var own_strs: std.ArrayList(u8) = .empty;
        defer own_strs.deinit(alloc);

        for (sections) |section| {
            if (section.sh_type != std.elf.SHT_SYMTAB) continue;
            const strtab_header = &sections[section.sh_link];
            const strtab_offset = strtab_header.sh_offset;

            if (section.sh_entsize != @sizeOf(std.elf.Elf64.Sym)) return error.Failed;
            const symbol_count = section.sh_size / @sizeOf(std.elf.Elf64.Sym);

            try elf_syms.resize(alloc, symbol_count);
            try reader.seekTo(section.sh_offset);
            try reader.interface.readSliceEndian(std.elf.Elf64.Sym, elf_syms.items, .little);

            try own_syms.ensureUnusedCapacity(b.allocator, symbol_count);
            for (elf_syms.items) |elf_sym| {
                try reader.seekTo(strtab_offset + elf_sym.name);
                const name = try reader.interface.takeDelimiter(0) orelse continue;

                own_syms.appendAssumeCapacity(.{
                    .addr = elf_sym.value,
                    .name_offset = @intCast(own_strs.items.len),
                    .name_len = @intCast(name.len),
                });

                try own_strs.appendSlice(alloc, name);
            }
        }

        std.mem.sort(Symbol, own_syms.items, {}, struct {
            fn lessThan(_: void, lhs: Symbol, rhs: Symbol) bool {
                return lhs.addr < rhs.addr;
            }
        }.lessThan);

        const module_dir = b.fmt("{s}/{s}", .{ b.install_prefix, output_sub_dir ++ "iso/boot/" });
        try cwd.createDirPath(io, module_dir);

        {
            const sym_tab_file = try cwd.createFile(io, b.fmt("{s}/symbol_table.mod", .{module_dir}), .{ .truncate = true });
            defer sym_tab_file.close(io);
            try sym_tab_file.writePositionalAll(io, std.mem.sliceAsBytes(own_syms.items), 0);
        }

        {
            const sym_name_file = try cwd.createFile(io, b.fmt("{s}/symbol_names.mod", .{module_dir}), .{ .truncate = true });
            defer sym_name_file.close(io);
            try sym_name_file.writePositionalAll(io, own_strs.items, 0);
        }

        try step.writeManifestAndWatch(&man);
    }
};
