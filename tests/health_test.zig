const std = @import("std");
const proxy = @import("proxy_transport");
const testing = std.testing;

test "health: starts healthy and tracks successes" {
    var health = proxy.health.ProxyHealth.init(3, 60_000);
    try testing.expect(!health.isBanned(1000));

    health.registerSuccess();
    const stats = health.getStats(1000);
    try testing.expectEqual(@as(u64, 1), stats.successes);
    try testing.expectEqual(@as(u64, 0), stats.failures);
    try testing.expect(!stats.banned);
}

test "health: bans after reaching failure threshold and unbans after cooldown" {
    const threshold: u32 = 2;
    const cooldown_ms: u64 = 5_000;
    var health = proxy.health.ProxyHealth.init(threshold, cooldown_ms);

    const now_ms: u64 = 10_000;
    // 1st failure: consecutive=1, threshold=2 -> not banned
    health.registerFailure(now_ms);
    try testing.expect(!health.isBanned(now_ms));

    // 2nd failure: consecutive=2, threshold=2 -> banned until now_ms + 5_000 = 15_000
    health.registerFailure(now_ms);
    try testing.expect(health.isBanned(now_ms));
    try testing.expect(health.isBanned(now_ms + 4_999));

    // After cooldown expired (at 15_000)
    try testing.expect(!health.isBanned(now_ms + 5_000));
}

test "health: success resets consecutive failure count" {
    var health = proxy.health.ProxyHealth.init(3, 10_000);
    health.registerFailure(1_000);
    health.registerFailure(1_000);
    try testing.expectEqual(@as(u32, 2), health.getConsecutiveFailures());

    health.registerSuccess();
    try testing.expectEqual(@as(u32, 0), health.getConsecutiveFailures());
    try testing.expect(!health.isBanned(1_000));
}
