const std = @import("std");
const ProxyPool = @import("pool.zig").ProxyPool;
const ProxyEndpoint = @import("endpoint.zig").ProxyEndpoint;

pub const ProxyLease = struct {
    pool: *ProxyPool,
    slot_index: usize,
    raw_url: []const u8,
    redacted_url: []const u8,
    endpoint: *const ProxyEndpoint,
    released: bool,

    pub fn init(
        pool: *ProxyPool,
        slot_index: usize,
        raw_url: []const u8,
        redacted_url: []const u8,
        endpoint_ptr: *const ProxyEndpoint,
    ) ProxyLease {
        return .{
            .pool = pool,
            .slot_index = slot_index,
            .raw_url = raw_url,
            .redacted_url = redacted_url,
            .endpoint = endpoint_ptr,
            .released = false,
        };
    }

    pub fn release(self: *ProxyLease) void {
        if (!self.released) {
            self.released = true;
            self.pool.releaseLease(self.slot_index);
        }
    }

    pub fn deinit(self: *ProxyLease) void {
        self.release();
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

    pub fn getEndpoint(self: *const ProxyLease) *const ProxyEndpoint {
        return self.endpoint;
    }

    pub fn asHttpProxy(self: *const ProxyLease) std.http.Client.Proxy {
        return .{
            .protocol = switch (self.endpoint.scheme) {
                .http, .socks5 => .plain,
                .https => .tls,
            },
            .host = .{ .bytes = self.endpoint.host },
            .port = self.endpoint.port,
            .authorization = self.endpoint.auth_header,
            .supports_connect = true,
        };
    }

    pub fn registerSuccess(self: *ProxyLease) void {
        self.pool.registerSuccess(self.slot_index);
    }

    pub fn registerFailure(self: *ProxyLease) void {
        self.pool.registerFailure(self.slot_index);
    }
};
