const std = @import("std");
const proxy = @import("proxy_transport");
const testing = std.testing;

test "pool: empty pool returns null lease for direct egress" {
    var pool = try proxy.pool.ProxyPool.init(testing.allocator, &.{}, 3, 60_000);
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 0), pool.len());
    try testing.expect(!pool.usesProxy());
    try testing.expect(!pool.isRotating());

    const lease = pool.acquireLease();
    try testing.expect(lease == null);
}

test "pool: round robin rotates across available proxies" {
    const urls = [_][]const u8{
        "http://proxy1.local:8080",
        "http://proxy2.local:8080",
    };

    var pool = try proxy.pool.ProxyPool.init(testing.allocator, &urls, 3, 60_000);
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 2), pool.len());
    try testing.expect(pool.usesProxy());
    try testing.expect(pool.isRotating());

    var l1 = pool.acquireLease().?;
    var l2 = pool.acquireLease().?;
    var l3 = pool.acquireLease().?;

    try testing.expectEqualStrings("http://proxy1.local:8080", l1.getUrl());
    try testing.expectEqualStrings("http://proxy2.local:8080", l2.getUrl());
    try testing.expectEqualStrings("http://proxy1.local:8080", l3.getUrl());
}

test "pool: skips banned proxies and fail-open selects when all banned" {
    const urls = [_][]const u8{
        "http://proxy1.local:8080",
        "http://proxy2.local:8080",
    };

    var pool = try proxy.pool.ProxyPool.init(testing.allocator, &urls, 1, 60_000);
    defer pool.deinit();

    // Ban proxy1
    var l1 = pool.acquireLease().?;
    try testing.expectEqualStrings("http://proxy1.local:8080", l1.getUrl());
    l1.registerFailure();

    // Next lease should skip banned proxy1 and choose proxy2
    var l2 = pool.acquireLease().?;
    try testing.expectEqualStrings("http://proxy2.local:8080", l2.getUrl());

    // Ban proxy2 as well
    l2.registerFailure();

    // Now all proxies are banned -> fail-open policy must still return a proxy
    var l3 = pool.acquireLease().?;
    try testing.expect(l3.getUrl().len > 0);
}

test "pool: lease reporting updates slot stats" {
    const urls = [_][]const u8{
        "http://user:pass@proxy1.local:8080",
    };

    var pool = try proxy.pool.ProxyPool.init(testing.allocator, &urls, 2, 60_000);
    defer pool.deinit();

    var lease = pool.acquireLease().?;
    try testing.expectEqualStrings("http://user:pass@proxy1.local:8080", lease.getUrl());
    lease.registerSuccess();

    const stats = pool.getStats(0).?;
    try testing.expectEqualStrings("http://proxy1.local:8080", stats.url);
    try testing.expectEqual(@as(u64, 1), stats.successes);
    try testing.expectEqual(@as(u64, 0), stats.failures);
}

test "pool: lease exposes structured endpoint and basic auth" {
    const urls = [_][]const u8{
        "http://botuser:mypass@proxy.crawler.internal:3128",
    };

    var pool = try proxy.pool.ProxyPool.init(testing.allocator, &urls, 3, 60_000);
    defer pool.deinit();

    const lease = pool.acquireLease().?;
    const ep = lease.getEndpoint();
    try testing.expectEqualStrings("proxy.crawler.internal", ep.host);
    try testing.expectEqual(@as(u16, 3128), ep.port);
    try testing.expectEqualStrings("Basic Ym90dXNlcjpteXBhc3M=", ep.auth_header.?);
}

test "pool: lease converts directly to std.http.Client.Proxy" {
    const urls = [_][]const u8{
        "http://botuser:mypass@proxy.crawler.internal:3128",
    };

    var pool = try proxy.pool.ProxyPool.init(testing.allocator, &urls, 3, 60_000);
    defer pool.deinit();

    const lease = pool.acquireLease().?;
    const std_proxy = lease.asHttpProxy();

    try testing.expectEqualStrings("proxy.crawler.internal", std_proxy.host.bytes);
    try testing.expectEqual(@as(u16, 3128), std_proxy.port);
    try testing.expect(std_proxy.supports_connect);
    try testing.expectEqualStrings("Basic Ym90dXNlcjpteXBhc3M=", std_proxy.authorization.?);
}
