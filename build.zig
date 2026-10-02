const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_arch = .x86_64,
        .ofmt = .elf,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.penryn },
    });

    try addBuildStep(b, optimize, target);
    try addRunStep(b);
}

fn addBuildStep(b: *Build, optimize: std.builtin.OptimizeMode, target: Build.ResolvedTarget) !void {
    const io = b.graph.io;
    const alloc = b.allocator;
    const cwd = std.Io.Dir.cwd();

    const grub_dir = b.graph.environ_map.get("GRUB_DIR") orelse "/usr/lib/grub/";
    const grub_i386_pc = b.fmt("{s}/i386-pc/", .{grub_dir});

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

    const options = b.addOptions();
    options.addOption([]const u8, "build_root", b.build_root.path.?);
    options.addOption(bool, "single_core", true);
    kernel_compile.root_module.addOptions("options", options);

    const link = b.addSystemCommand(&.{
        // zig fmt: off
        "ld",
        "-n",
        "--gc-sections",
        "-z", "noexecstack",
        "-T",
        // zig fmt: on
    });
    link.addFileArg(b.path("build/x86_64/linker.ld"));
    switch (debug_info) {
        true => link.addArg("-g"),
        false => link.addArg("-s"),
    }

    link.addArg("-o");
    const kernel = link.addOutputFileArg("kernel.elf");
    link.addFileArg(kernel_compile.getEmittedBin());
    try linkAssembly(b, link);

    const kernel_install = b.addInstallFile(kernel, "kernel.elf");
    b.getInstallStep().dependOn(&kernel_install.step);

    const multiboot_check = b.addSystemCommand(&.{ "grub-file", "--is-x86-multiboot2" });
    multiboot_check.addFileArg(kernel);

    const tar = b.addSystemCommand(&.{
        "tar",
        "--format=ustar",
        "--sort=name",
        "--mtime=@0",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        "-cf",
    });
    const src_tar = tar.addOutputFileArg("kernel_src.tar");
    tar.addArgs(&.{ "-C", b.build_root.path.?, "src" });

    var src_dir = try cwd.openDir(io, b.pathJoin(&.{ b.build_root.path.?, "src" }), .{ .iterate = true });
    defer src_dir.close(io);

    var src_iter = try src_dir.walk(alloc);
    defer src_iter.deinit();
    while (try src_iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        tar.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ b.build_root.path.?, "src", entry.path }) });
    }

    const root = b.addWriteFiles();
    _ = root.addCopyDirectory(b.path("build/x86_64/disk/"), "", .{});
    _ = root.addCopyFile(kernel, "boot/kernel.elf");
    _ = root.addCopyFile(src_tar, "boot/kernel_src.tar");
    root.step.dependOn(&multiboot_check.step);

    const mk_fs_img = b.addSystemCommand(&.{ "mkfs.ext2", "-q", "-d" });
    mk_fs_img.addDirectoryArg(root.getDirectory());
    const fs_img = mk_fs_img.addOutputFileArg("fs.img");
    mk_fs_img.addArg("31M");

    const mk_core_img = b.addSystemCommand(&.{
        // zig fmt: off
        "grub-mkimage",
        "-O", "i386-pc",
        "-d", grub_i386_pc,
        "-p", "(hd0,msdos1)/boot/grub",
        "biosdisk", "part_msdos", "ext2", "normal", "multiboot2", "boot", "serial",
        "-o"
        // zig fmt: on
    });
    const core_img = mk_core_img.addOutputFileArg("core.img");

    const mk_disk = b.addSystemCommand(&.{"sh"});
    mk_disk.addFileArg(b.path("build/x86_64/mk-disk.sh"));
    mk_disk.addFileArg(.{ .cwd_relative = b.fmt("{s}/boot.img", .{grub_i386_pc}) });
    mk_disk.addFileArg(core_img);
    mk_disk.addFileArg(fs_img);
    const disk_img = mk_disk.addOutputFileArg("disk.img");

    const disk_install = b.addInstallFile(disk_img, "disk.img");
    b.getInstallStep().dependOn(&disk_install.step);
}

fn linkAssembly(b: *Build, link: *Build.Step.Run) !void {
    const asm_source_path = b.pathJoin(&.{ b.build_root.path.?, "src/arch/x86_64/" });
    var asm_source_dir = try std.Io.Dir.cwd().openDir(b.graph.io, asm_source_path, .{ .iterate = true });
    defer asm_source_dir.close(b.graph.io);

    var iter = try asm_source_dir.walk(b.allocator);
    defer iter.deinit();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".asm")) continue;

        const source_file: Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ asm_source_path, entry.path }) };
        const asm_compile = b.addSystemCommand(&.{
            "nasm",
            "-f",
            "elf64",
        });

        asm_compile.addFileArg(source_file);
        const asm_object = asm_compile.addPrefixedOutputFileArg("-o", b.fmt("{s}.o", .{entry.basename}));

        link.addFileArg(asm_object);
    }
}

const OutputMode = enum {
    serial,
    vga,
};

const DiskMode = enum {
    ide,
    ahci,
};

fn addRunStep(b: *Build) !void {
    const output_mode = b.option(OutputMode, "output", "") orelse .serial;
    const disk_mode = b.option(DiskMode, "disk", "") orelse .ide;

    const display = switch (output_mode) {
        .serial => "none",
        .vga => "gtk",
    };

    const run_step = b.step("run", "Run the iso in qemu");
    const run = b.addSystemCommand(&.{
        // zig fmt: off
        "qemu-system-x86_64",
        "-enable-kvm",
        "-cpu", "Penryn",
        "-display", display,
        "-nodefaults",
        "-m", "32M",
        "-smp", "4",
        // zig fmt: on
    });
    run.setCwd(.{ .cwd_relative = b.install_prefix });

    switch (output_mode) {
        .serial => run.addArgs(&.{ "-serial", "mon:stdio" }),
        .vga => run.addArgs(&.{ "-vga", "std" }),
    }

    switch (disk_mode) {
        .ide => run.addArgs(&.{
            "-drive", "file=disk.img,format=raw,if=ide,id=disk0",
        }),
        .ahci => run.addArgs(&.{
            "-drive",  "file=disk.img,format=raw,if=none,id=disk0",
            "-device", "pci-bridge,id=bridge1,chassis_nr=1",
            "-device", "ahci,id=ahci0,bus=bridge1",
            "-device", "ide-hd,drive=disk0,bus=ahci0.0",
        }),
    }

    if (b.option(bool, "gdb", "Use gdb with qemu") orelse false)
        run.addArgs(&.{ "-s", "-S" });

    run.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run.step);
}
