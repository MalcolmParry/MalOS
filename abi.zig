pub const Syscall = enum(usize) {
    debug_print = 0,
};

pub const Status = enum(usize) {
    success = 0,
    invalid_syscall = 1,
    invalid_arg = 2,
    fault = 3,
    too_long = 4,
    unknown = 5,
};
