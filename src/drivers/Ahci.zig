const std = @import("std");
const mem = @import("../memory.zig");
const pci = @import("pci.zig");
const PageAlloc = @import("../heap/PageAllocator.zig");
const Controller = @This();

pci_addr: pci.Addr,
abar: *volatile Abar,
cap: Abar.Cap,
ports_implemented: std.bit_set.IntegerBitSet(32),

const Abar = extern struct {
    cap: Cap,
    ghc: Ghc,
    is: u32,
    pi: u32,
    vs: u32,
    ccc_ctl: u32,
    ccc_pts: u32,
    em_loc: u32,
    em_ctl: u32,
    cap2: Cap2,
    bohc: BiosToOsHandoff,

    reserved: [0xa0 - 0x2c]u8,
    vendor: [0x100 - 0xa0]u8,

    ports: [32]Port,

    const Cap = packed struct(u32) {
        port_count_minus_1: u5,
        supports_external_sata: bool,
        ems: bool,
        cccs: bool,
        cmd_slot_count_minus_1: u5,
        psc: bool,
        ssc: bool,
        pmd: bool,
        fbss: bool,
        spm: bool,
        sam: bool,
        reserved: u1,
        iss: u4,
        sclo: bool,
        sal: bool,
        salp: bool,
        sss: bool,
        smps: bool,
        ssntf: bool,
        sncq: bool,
        supports_64bit_addr: bool,
    };

    const Ghc = packed struct(u32) {
        reset: bool,
        int_enable: bool,
        mrsm: bool,
        reserved: u28,
        ahci_enable: bool,
    };

    const Cap2 = packed struct(u32) {
        bios2os_handoff: bool,
        idk: u31,
    };

    const BiosToOsHandoff = packed struct(u32) {
        bios_owned: bool,
        os_owned: bool,
        smi_on_change: bool,
        os_ownership_change: bool,
        bios_busy: bool,
        reserved: u27,
    };
};

const Port = extern struct {
    cmd_list_addr: u64 align(4),
    fis_base_addr: u64 align(4),
    int_status: u32,
    int_enable: u32,
    cmd: Cmd,
    reserved: u32,
    task_file_data: u32,
    signature: u32,
    sata_status: u32,
    sata_ctl: u32,
    sata_err: u32,
    sata_active: u32,
    cmd_issue: u32,
    sata_notif: u32,
    fbs: u32,
    reserved2: [11]u32,
    vendor: [4]u32,

    const Cmd = packed struct(u32) {
        start: bool,
        sud: bool,
        pod: bool,
        clo: bool,
        fis_recv_enable: bool,
        reserved: u3,
        ccs: u5,
        mpss: bool,
        fis_recv_running: bool,
        cmd_list_running: bool,
        cps: bool,
        pma: bool,
        hpcp: bool,
        mpsp: bool,
        cpd: bool,
        esp: bool,
        fbscp: bool,
        apste: bool,
        is_atapi: bool,
        dlae: bool,
        alpe: bool,
        asp: bool,
        icc: u4,
    };
};

pub fn initController(pci_addr: pci.Addr) !void {
    var cmd: pci.CmdRegister = @bitCast(pci.read16(pci_addr, 4));
    cmd.mem_space = true;
    cmd.bus_master = true;
    pci.write16(pci_addr, 4, @bitCast(cmd));

    const abar_phys_int = pci.read32(pci_addr, 0x24) & 0xffff_fff0;
    const abar_phys = @as([*]mem.Phys(u8), @ptrFromInt(abar_phys_int))[0..@sizeOf(Abar)];
    const page_offset = abar_phys_int % mem.page_size;
    const abar_phys_pages = mem.physPageAlignOutwards(abar_phys);

    const abar_pages = try PageAlloc.global.map(abar_phys_pages, .{
        .cache_mode = .disabled,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    });
    const abar: *volatile Abar = @ptrFromInt(@intFromPtr(abar_pages.ptr) + page_offset);

    abar.ghc.ahci_enable = true;
    if (!abar.ghc.ahci_enable) return error.AhciEnableFailed;
    abar.ghc.int_enable = false;

    if (abar.cap2.bios2os_handoff) {
        var bohc = abar.bohc;
        bohc.os_owned = true;
        bohc.os_ownership_change = false;
        abar.bohc = bohc;

        while (abar.bohc.bios_owned) {
            std.atomic.spinLoopHint();
        }
    }

    var controller: Controller = .{
        .pci_addr = pci_addr,
        .abar = abar,
        .cap = abar.cap,
        .ports_implemented = undefined,
    };

    if (!controller.cap.supports_64bit_addr) {
        std.log.err("ahci controller doesn't support 64bit addressing", .{});
        return error.Unsupported;
    }

    var pi = abar.pi;
    const port_count = @as(u6, controller.cap.port_count_minus_1) + 1;
    if (pi == 0) {
        pi = @intCast((@as(u64, 1) << port_count) - 1);
    }
    controller.ports_implemented = .{ .mask = pi };
}
