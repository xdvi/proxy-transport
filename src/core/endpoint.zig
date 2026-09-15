const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Scheme = enum {
    http,
    https,
    socks5,
};

pub const ProxyEndpoint = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    username: ?[]const u8,
    password: ?[]const u8,
    auth_header: ?[]const u8,

    pub fn parse(allocator: Allocator, url: []const u8) !ProxyEndpoint {
        var rest = url;
        var scheme: Scheme = .http;
        var default_port: u16 = 80;

        if (std.mem.indexOf(u8, rest, "://")) |idx| {
            const scheme_str = rest[0..idx];
            if (std.ascii.eqlIgnoreCase(scheme_str, "https")) {
                scheme = .https;
                default_port = 443;
            } else if (std.ascii.eqlIgnoreCase(scheme_str, "socks5")) {
                scheme = .socks5;
                default_port = 1080;
            } else if (std.ascii.eqlIgnoreCase(scheme_str, "http")) {
                scheme = .http;
                default_port = 80;
            }
            rest = rest[idx + 3 ..];
        }

        var username: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var auth_header: ?[]const u8 = null;

        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at_idx| {
            const userinfo = rest[0..at_idx];
            rest = rest[at_idx + 1 ..];

            if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon_idx| {
                username = try allocator.dupe(u8, userinfo[0..colon_idx]);
                password = try allocator.dupe(u8, userinfo[colon_idx + 1 ..]);
            } else {
                username = try allocator.dupe(u8, userinfo);
            }

            const b64_len = std.base64.standard.Encoder.calcSize(userinfo.len);
            const encoded_buf = try allocator.alloc(u8, b64_len);
            defer allocator.free(encoded_buf);
            _ = std.base64.standard.Encoder.encode(encoded_buf, userinfo);

            auth_header = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded_buf});
        }

        if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
            rest = rest[0..slash_idx];
        }

        var host: []const u8 = undefined;
        var port: u16 = default_port;

        if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon_idx| {
            host = try allocator.dupe(u8, rest[0..colon_idx]);
            const port_str = rest[colon_idx + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch default_port;
        } else {
            host = try allocator.dupe(u8, rest);
        }

        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .username = username,
            .password = password,
            .auth_header = auth_header,
        };
    }

    pub fn deinit(self: *ProxyEndpoint, allocator: Allocator) void {
        allocator.free(self.host);
        if (self.username) |u| allocator.free(u);
        if (self.password) |p| allocator.free(p);
        if (self.auth_header) |a| allocator.free(a);
        self.* = undefined;
    }
};
