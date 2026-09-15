const std = @import("std");
const ProxyPool = @import("pool.zig").ProxyPool;

pub const ProxyLease = struct {
    pool: *ProxyPool,
    slot_index: usize,
    raw_url: []const u8,
    redacted_url: []const u8,

    pub fn init(pool: *ProxyPool, slot_index: usize, raw_url: []const u8, redacted_url: []const u8) ProxyLease {
        return .{
            .pool = pool,
            .slot_index = slot_index,
            .raw_url = raw_url,
            .redacted_url = redacted_url,
        };
    }

    pub fn getUrl(self: *const ProxyLease) []const u8 {
        return self.raw_url;
    }

    pub fn getRedactedUrl(self: *const ProxyLease) []const u8 {
        return self.redacted_url;
    }

    pub fn getSlotIndex(self: *const ProxyLease) usize {
        return self.slot_index;
    }

    pub fn registerSuccess(self: *ProxyLease) void {
        self.pool.registerSuccess(self.slot_index);
    }

    pub fn registerFailure(self: *ProxyLease) void {
        self.pool.registerFailure(self.slot_index);
    }
};
