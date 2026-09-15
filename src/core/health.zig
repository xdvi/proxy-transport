const std = @import("std");
const AtomicU32 = std.atomic.Value(u32);
const AtomicU64 = std.atomic.Value(u64);

pub const HealthStats = struct {
    successes: u64,
    failures: u64,
    banned: bool,
};

pub const ProxyHealth = struct {
    failure_threshold: u32,
    cooldown_ms: u64,
    consecutive_failures: AtomicU32,
    success_count: AtomicU64,
    failure_count: AtomicU64,
    banned_until_ms: AtomicU64,

    pub fn init(failure_threshold: u32, cooldown_ms: u64) ProxyHealth {
        return .{
            .failure_threshold = failure_threshold,
            .cooldown_ms = cooldown_ms,
            .consecutive_failures = AtomicU32.init(0),
            .success_count = AtomicU64.init(0),
            .failure_count = AtomicU64.init(0),
            .banned_until_ms = AtomicU64.init(0),
        };
    }

    pub fn isBanned(self: *const ProxyHealth, now_ms: u64) bool {
        const banned_until = self.banned_until_ms.load(.monotonic);
        const failures = self.consecutive_failures.load(.monotonic);
        return failures >= self.failure_threshold and now_ms < banned_until;
    }

    pub fn registerSuccess(self: *ProxyHealth) void {
        self.consecutive_failures.store(0, .monotonic);
        _ = self.success_count.fetchAdd(1, .monotonic);
        self.banned_until_ms.store(0, .monotonic);
    }

    pub fn registerFailure(self: *ProxyHealth, now_ms: u64) void {
        const failures = self.consecutive_failures.fetchAdd(1, .monotonic) + 1;
        _ = self.failure_count.fetchAdd(1, .monotonic);
        if (failures >= self.failure_threshold) {
            self.banned_until_ms.store(now_ms + self.cooldown_ms, .monotonic);
        }
    }

    pub fn getConsecutiveFailures(self: *const ProxyHealth) u32 {
        return self.consecutive_failures.load(.monotonic);
    }

    pub fn getStats(self: *const ProxyHealth, now_ms: u64) HealthStats {
        return .{
            .successes = self.success_count.load(.monotonic),
            .failures = self.failure_count.load(.monotonic),
            .banned = self.isBanned(now_ms),
        };
    }
};
