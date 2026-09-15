const std = @import("std");
const proxy = @import("proxy_transport");
const testing = std.testing;

test "endpoint: parse plain http proxy without auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ep = try proxy.endpoint.ProxyEndpoint.parse(arena.allocator(), "http://127.0.0.1:8080");
    try testing.expectEqual(proxy.endpoint.Scheme.http, ep.scheme);
    try testing.expectEqualStrings("127.0.0.1", ep.host);
    try testing.expectEqual(@as(u16, 8080), ep.port);
    try testing.expect(ep.username == null);
    try testing.expect(ep.password == null);
    try testing.expect(ep.auth_header == null);
}

test "endpoint: parse proxy with credentials and computes Basic auth header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ep = try proxy.endpoint.ProxyEndpoint.parse(
        arena.allocator(),
        "http://myuser:secret123@proxy.domain.com:3128",
    );
    try testing.expectEqual(proxy.endpoint.Scheme.http, ep.scheme);
    try testing.expectEqualStrings("proxy.domain.com", ep.host);
    try testing.expectEqual(@as(u16, 3128), ep.port);
    try testing.expectEqualStrings("myuser", ep.username.?);
    try testing.expectEqualStrings("secret123", ep.password.?);
    try testing.expectEqualStrings("Basic bXl1c2VyOnNlY3JldDEyMw==", ep.auth_header.?);
}

test "endpoint: default ports for schemes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ep_http = try proxy.endpoint.ProxyEndpoint.parse(arena.allocator(), "http://node1");
    try testing.expectEqual(@as(u16, 80), ep_http.port);

    const ep_https = try proxy.endpoint.ProxyEndpoint.parse(arena.allocator(), "https://node2");
    try testing.expectEqual(@as(u16, 443), ep_https.port);

    const ep_socks = try proxy.endpoint.ProxyEndpoint.parse(arena.allocator(), "socks5://node3");
    try testing.expectEqual(@as(u16, 1080), ep_socks.port);
}
