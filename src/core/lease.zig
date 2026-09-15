const std = @import("std");
const ProxyEndpoint = @import("endpoint.zig").ProxyEndpoint;
const time = @import("../utils/time.zig");
const pool_mod = @import("pool.zig");
pub const ProxyPool = pool_mod.ProxyPool;
pub const ProxyEntry = pool_mod.ProxyEntry;

pub const ProxyLease = struct {
    pool: *ProxyPool,
    entry: *ProxyEntry,
    slot_index: usize,
    released: bool,

    pub fn init(
        pool: *ProxyPool,
        entry: *ProxyEntry,
        slot_index: usize,
    ) ProxyLease {
        return .{
            .pool = pool,
            .entry = entry,
            .slot_index = slot_index,
            .released = false,
        };
    }

    pub fn release(self: *ProxyLease) void {
        if (!self.released) {
            self.released = true;
            self.entry.releaseLease();
            self.pool.cleanupDraining();
        }
    }

    pub fn deinit(self: *ProxyLease) void {
        self.release();
    }

    pub fn getUrl(self: *const ProxyLease) []const u8 {
        return self.entry.raw_url;
    }

    pub fn getRedactedUrl(self: *const ProxyLease) []const u8 {
        return self.entry.redacted_url;
    }

    pub fn getSlotIndex(self: *const ProxyLease) usize {
        return self.slot_index;
    }

    pub fn getEndpoint(self: *const ProxyLease) *const ProxyEndpoint {
        return &self.entry.endpoint;
    }

    pub fn asHttpProxy(self: *const ProxyLease) std.http.Client.Proxy {
        return .{
            .protocol = switch (self.entry.endpoint.scheme) {
                .http, .socks5 => .plain,
                .https => .tls,
            },
            .host = .{ .bytes = self.entry.endpoint.host },
            .port = self.entry.endpoint.port,
            .authorization = self.entry.endpoint.auth_header,
            .supports_connect = true,
        };
    }

    pub fn registerSuccess(self: *ProxyLease) void {
        self.entry.health.registerSuccess();
    }

    pub fn registerFailure(self: *ProxyLease) void {
        self.entry.health.registerFailure(time.nowMs());
    }
};

