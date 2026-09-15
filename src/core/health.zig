const std = @import("std");
const AtomicU32 = std.atomic.Value(u32);
const AtomicU64 = std.atomic.Value(u64);

pub const HealthStats = struct {
    successes: u64,
    failures: u64,
    banned: bool,
};

pub const JitterMode = enum {
    none,
    full,
    equal,
};

pub const HealthConfig = struct {
    failure_threshold: u32,
    base_cooldown_ms: u64,
    max_cooldown_ms: u64,
    jitter: JitterMode = .full,
};

pub const ProxyHealth = struct {
    base_cooldown_ms: u64,
    max_cooldown_ms: u64,
    banned_until_ms: AtomicU64,
    rng_state: AtomicU64,
    success_count: AtomicU64,
    failure_count: AtomicU64,
    failure_threshold: u32,
    consecutive_failures: AtomicU32,
    jitter: JitterMode,

    pub fn init(failure_threshold: u32, cooldown_ms: u64) ProxyHealth {
        return initWithConfig(.{
            .failure_threshold = failure_threshold,
            .base_cooldown_ms = cooldown_ms,
            .max_cooldown_ms = cooldown_ms *| 16,
            .jitter = .none,
        });
    }

    pub fn initWithMax(failure_threshold: u32, base_cooldown_ms: u64, max_cooldown_ms: u64) ProxyHealth {
        return initWithConfig(.{
            .failure_threshold = failure_threshold,
            .base_cooldown_ms = base_cooldown_ms,
            .max_cooldown_ms = max_cooldown_ms,
            .jitter = .full,
        });
    }

    pub fn initWithConfig(config: HealthConfig) ProxyHealth {
        const seed = 0x8547_8547_1234_5678 ^ (@as(u64, config.failure_threshold) << 32 | @as(u32, @truncate(config.base_cooldown_ms)));
        return .{
            .failure_threshold = config.failure_threshold,
            .base_cooldown_ms = config.base_cooldown_ms,
            .max_cooldown_ms = @max(config.base_cooldown_ms, config.max_cooldown_ms),
            .jitter = config.jitter,
            .consecutive_failures = AtomicU32.init(0),
            .success_count = AtomicU64.init(0),
            .failure_count = AtomicU64.init(0),
            .banned_until_ms = AtomicU64.init(0),
            .rng_state = AtomicU64.init(if (seed == 0) 0x1234_5678_90ab_cdef else seed),
        };
    }

    fn nextRandom(self: *ProxyHealth) u64 {
        var cur = self.rng_state.load(.monotonic);
        while (true) {
            var x = cur;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            if (x == 0) x = 0xdeadbeef_cafebabe;
            if (self.rng_state.cmpxchgWeak(cur, x, .monotonic, .monotonic)) |actual| {
                cur = actual;
            } else {
                return x;
            }
        }
    }

    pub fn calculateCooldown(self: *ProxyHealth, failures: u32) u64 {
        if (failures < self.failure_threshold) return 0;
        const streak = failures - self.failure_threshold;
        const exponent: u6 = @intCast(@min(streak, 6));
        const multiplier: u64 = @as(u64, 1) << exponent;
        const raw = @min(self.max_cooldown_ms, self.base_cooldown_ms *| multiplier);

        return switch (self.jitter) {
            .none => raw,
            .full => if (raw > 0) (self.nextRandom() % raw) + 1 else 0,
            .equal => if (raw > 1) (raw / 2) + (self.nextRandom() % (raw / 2)) else raw,
        };
    }

    pub fn isBanned(self: *const ProxyHealth, now_ms: u64) bool {
        const banned_until = self.banned_until_ms.load(.monotonic);
        const failures = self.consecutive_failures.load(.monotonic);
        return failures >= self.failure_threshold and now_ms < banned_until;
    }

    pub fn getBannedUntilMs(self: *const ProxyHealth) u64 {
        return self.banned_until_ms.load(.monotonic);
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
            const cooldown = self.calculateCooldown(failures);
            self.banned_until_ms.store(now_ms +| cooldown, .monotonic);
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
