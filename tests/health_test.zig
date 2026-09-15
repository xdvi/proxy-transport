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

test "health: exponential backoff with max cooldown cap and jitter" {
    const threshold: u32 = 1;
    const base_cooldown: u64 = 1_000;
    const max_cooldown: u64 = 4_000;

    var health = proxy.health.ProxyHealth.initWithMax(threshold, base_cooldown, max_cooldown);

    // 1st failure (exponent 0): raw ceiling is base_cooldown = 1_000
    health.registerFailure(10_000);
    const banned_1 = health.getBannedUntilMs();
    try testing.expect(banned_1 >= 10_000);
    try testing.expect(banned_1 <= 10_000 + 1_000);

    // 2nd failure (exponent 1): raw ceiling is 2_000
    health.registerFailure(10_000);
    const banned_2 = health.getBannedUntilMs();
    try testing.expect(banned_2 >= 10_000);
    try testing.expect(banned_2 <= 10_000 + 2_000);

    // 3rd failure (exponent 2): raw ceiling is 4_000 (max cap)
    health.registerFailure(10_000);
    const banned_3 = health.getBannedUntilMs();
    try testing.expect(banned_3 >= 10_000);
    try testing.expect(banned_3 <= 10_000 + 4_000);

    // 4th failure (exponent 3): raw ceiling would be 8_000, but capped at max_cooldown = 4_000
    health.registerFailure(10_000);
    const banned_4 = health.getBannedUntilMs();
    try testing.expect(banned_4 >= 10_000);
    try testing.expect(banned_4 <= 10_000 + 4_000);
}

