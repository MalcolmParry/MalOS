const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const output_sub_dir = "x86-64/";
    const asm_source_path = "src/arch/x86-64/";

    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_arch = .x86_64,
        .ofmt = .elf,
    });

    const kernel_compile = b.addObject(.{
        .name = "kernel.elf",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
        }),
    });
    kernel_compile.bundle_compiler_rt = true;

    const iso_dir = b.addInstallDirectory(.{ .source_dir = b.path("build/x86-64/iso"), .install_dir = .{ .custom = output_sub_dir ++ "iso" }, .install_subdir = "" });
    const link = b.addSystemCommand(&.{ "ld", "-n", "-g", "-T", "build/x86-64/linker.ld" });
    link.addArg("-o");
    const kernel = link.addOutputFileArg("kernel.elf");
    link.addFileArg(kernel_compile.getEmittedBin());
    link.step.dependOn(&kernel_compile.step);

    const cwd = std.fs.cwd();
    var asm_source_dir = try cwd.openDir(asm_source_path, .{ .iterate = true });
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

    const multiboot_check = b.addSystemCommand(&.{ "grub-file", "--is-x86-multiboot2" });
    multiboot_check.addFileArg(kernel);

    const kernel_install = b.addInstallFile(kernel, output_sub_dir ++ "iso/boot/kernel.elf");
    kernel_install.step.dependOn(&iso_dir.step);
    kernel_install.step.dependOn(&multiboot_check.step);

    const iso_build = b.addSystemCommand(&.{ "grub-mkrescue", "/usr/lib/grub/i386-efi" });
    iso_build.addArg("-o");
    const iso = iso_build.addOutputFileArg(output_sub_dir ++ "kernel.iso");
    iso_build.addArg(b.fmt("{s}/{s}", .{ b.install_prefix, output_sub_dir ++ "iso" }));
    iso_build.step.dependOn(&kernel_install.step);

    const iso_install = b.addInstallFile(iso, output_sub_dir ++ "kernel.iso");
    iso_install.step.dependOn(&iso_build.step);
    b.getInstallStep().dependOn(&iso_install.step);

    const run_step = b.step("run", "Run the iso in qemu");
    const run = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-display",
        "gtk",
        "-m",
        "2G",
        "-smp",
        "4",
        "-cdrom",
    });
    run.addFileArg(iso);
    if (b.option(bool, "gdb", "Use gdb with qemu") orelse false)
        run.addArgs(&.{ "-s", "-S" });

    run_step.dependOn(&run.step);
    run_step.dependOn(&iso_install.step);
}
