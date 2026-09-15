const std = @import("std");

pub const ProxyErrorCode = enum(i32) {
    Success = 0,
    InvalidArgument = -1,
    OutOfMemory = -2,
    BufferTooSmall = -3,
    IoError = -4,
    PoolEmpty = -5,
    InvalidHandle = -6,
    UseAfterFree = -7,

    pub fn toI32(self: ProxyErrorCode) i32 {
        return @intFromEnum(self);
    }
};

pub const ProxyErrorInfo = extern struct {
    code: i32,
    message: [256]u8,
};

pub const ProxyStats = extern struct {
    url: [256]u8,
    successes: u64,
    failures: u64,
    banned: bool,
};
