const std = @import("std");
const proxy = @import("proxy_transport");
const testing = std.testing;

test "tunnel: formats CONNECT request without auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ep = try proxy.endpoint.ProxyEndpoint.parse(arena.allocator(), "http://10.0.0.1:8080");
    var buf: [512]u8 = undefined;
    const req = try proxy.tunnel.formatConnectRequest(&ep, "api.service.internal", 443, &buf);

    try testing.expect(std.mem.startsWith(u8, req, "CONNECT api.service.internal:443 HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, req, "Host: api.service.internal:443\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Proxy-Authorization") == null);
    try testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "tunnel: formats CONNECT request with Basic proxy authorization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ep = try proxy.endpoint.ProxyEndpoint.parse(
        arena.allocator(),
        "http://bot:secret@10.0.0.1:8080",
    );
    var buf: [512]u8 = undefined;
    const req = try proxy.tunnel.formatConnectRequest(&ep, "target.com", 443, &buf);

    try testing.expect(std.mem.indexOf(u8, req, "Proxy-Authorization: Basic Ym90OnNlY3JldA==\r\n") != null);
}

test "tunnel: parse 200 Connection Established response" {
    const resp = "HTTP/1.1 200 Connection established\r\nProxy-Agent: Tinyproxy\r\n\r\n";
    try proxy.tunnel.parseConnectResponse(resp);
}

test "tunnel: parse 407 Proxy Authentication Required error" {
    const resp = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n";
    try testing.expectError(error.ProxyAuthenticationRequired, proxy.tunnel.parseConnectResponse(resp));
}
