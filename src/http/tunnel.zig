const std = @import("std");
const ProxyEndpoint = @import("../core/endpoint.zig").ProxyEndpoint;

pub const TunnelError = error{
    BufferTooSmall,
    ProxyAuthenticationRequired,
    ProxyForbidden,
    ProxyConnectionRefused,
    ProxyTunnelFailed,
    InvalidResponse,
};

pub fn formatConnectRequest(
    endpoint: *const ProxyEndpoint,
    target_host: []const u8,
    target_port: u16,
    buf: []u8,
) ![]const u8 {
    if (endpoint.auth_header) |auth| {
        return std.fmt.bufPrint(buf, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: proxy-transport/0.1.0\r\nProxy-Connection: Keep-Alive\r\nProxy-Authorization: {s}\r\n\r\n", .{
            target_host, target_port, target_host, target_port, auth,
        });
    } else {
        return std.fmt.bufPrint(buf, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: proxy-transport/0.1.0\r\nProxy-Connection: Keep-Alive\r\n\r\n", .{
            target_host, target_port, target_host, target_port,
        });
    }
}

pub fn parseConnectResponse(response: []const u8) TunnelError!void {
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 ") and !std.mem.startsWith(u8, response, "HTTP/1.0 ")) {
        return error.InvalidResponse;
    }

    if (response.len < 12) return error.InvalidResponse;

    const status_slice = response[9..12];
    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch {
        return error.InvalidResponse;
    };

    if (status_code >= 200 and status_code <= 299) {
        return;
    }

    if (status_code == 407) {
        return error.ProxyAuthenticationRequired;
    } else if (status_code == 403) {
        return error.ProxyForbidden;
    } else if (status_code == 502 or status_code == 504) {
        return error.ProxyConnectionRefused;
    } else {
        return error.ProxyTunnelFailed;
    }
}
