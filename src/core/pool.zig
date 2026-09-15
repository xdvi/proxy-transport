const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicUsize = std.atomic.Value(usize);
const AtomicU32 = std.atomic.Value(u32);
const ProxyHealth = @import("health.zig").ProxyHealth;
const ProxyLease = @import("lease.zig").ProxyLease;
const ProxyEndpoint = @import("endpoint.zig").ProxyEndpoint;
const parser = @import("parser.zig");
const time = @import("../utils/time.zig");

pub const ProxyEntry = struct {
    raw_url: []const u8,
    redacted_url: []const u8,
    endpoint: ProxyEndpoint,
    health: ProxyHealth,
    active_leases: AtomicU32,
    max_concurrency: u32,

    pub fn tryAcquireLease(self: *ProxyEntry) bool {
        var cur = self.active_leases.load(.monotonic);
        while (true) {
            if (cur >= self.max_concurrency) return false;
            if (self.active_leases.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic)) |actual| {
                cur = actual;
            } else {
                return true;
            }
        }
    }

    pub fn releaseLease(self: *ProxyEntry) void {
        const prev = self.active_leases.fetchSub(1, .release);
        if (prev == 0) {
            self.active_leases.store(0, .monotonic);
        }
    }
};

pub const PoolStats = struct {
    url: []const u8,
    successes: u64,
    failures: u64,
    banned: bool,
};

pub const ProxyPool = struct {
    allocator: Allocator,
    entries: []ProxyEntry,
    next_index: AtomicUsize,
    failure_threshold: u32,
    cooldown_ms: u64,
    max_concurrency_per_proxy: u32,

    pub fn init(
        allocator: Allocator,
        urls: []const []const u8,
        failure_threshold: u32,
        cooldown_ms: u64,
    ) !ProxyPool {
        return initWithMaxConcurrency(allocator, urls, failure_threshold, cooldown_ms, std.math.maxInt(u32));
    }

    pub fn initWithMaxConcurrency(
        allocator: Allocator,
        urls: []const []const u8,
        failure_threshold: u32,
        cooldown_ms: u64,
        max_concurrency: u32,
    ) !ProxyPool {
        const entries = try allocator.alloc(ProxyEntry, urls.len);
        errdefer allocator.free(entries);

        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |*entry| {
                allocator.free(entry.raw_url);
                allocator.free(entry.redacted_url);
                entry.endpoint.deinit(allocator);
            }
        }

        for (urls, 0..) |url, i| {
            const normalized = try parser.normalizeUrl(allocator, url);
            errdefer allocator.free(normalized);
            const redacted = try parser.redactUrl(allocator, normalized);
            errdefer allocator.free(redacted);
            var ep = try ProxyEndpoint.parse(allocator, normalized);
            errdefer ep.deinit(allocator);

            entries[i] = .{
                .raw_url = normalized,
                .redacted_url = redacted,
                .endpoint = ep,
                .health = ProxyHealth.initWithMax(failure_threshold, cooldown_ms, cooldown_ms *| 16),
                .active_leases = AtomicU32.init(0),
                .max_concurrency = max_concurrency,
            };
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .next_index = AtomicUsize.init(0),
            .failure_threshold = failure_threshold,
            .cooldown_ms = cooldown_ms,
            .max_concurrency_per_proxy = max_concurrency,
        };
    }


    pub fn fromText(
        allocator: Allocator,
        text: []const u8,
        failure_threshold: u32,
        cooldown_ms: u64,
    ) !ProxyPool {
        const parsed_lines = try parser.parseLines(allocator, text);
        defer {
            for (parsed_lines) |line| {
                allocator.free(line);
            }
            allocator.free(parsed_lines);
        }

        return init(allocator, parsed_lines, failure_threshold, cooldown_ms);
    }

    pub fn deinit(self: *ProxyPool) void {
        for (self.entries) |*entry| {
            self.allocator.free(entry.raw_url);
            self.allocator.free(entry.redacted_url);
            entry.endpoint.deinit(self.allocator);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn len(self: *const ProxyPool) usize {
        return self.entries.len;
    }

    pub fn usesProxy(self: *const ProxyPool) bool {
        return self.entries.len > 0;
    }

    pub fn isRotating(self: *const ProxyPool) bool {
        return self.entries.len > 1;
    }

    pub fn acquireLease(self: *ProxyPool) ?ProxyLease {
        const total = self.entries.len;
        if (total == 0) return null;

        const now_ms = time.nowMs();
        const start = self.next_index.fetchAdd(1, .monotonic) % total;

        var best_slot: ?usize = null;
        var min_leases: u32 = std.math.maxInt(u32);

        var i: usize = 0;
        while (i < total) : (i += 1) {
            const slot = (start + i) % total;
            if (!self.entries[slot].health.isBanned(now_ms)) {
                const active = self.entries[slot].active_leases.load(.monotonic);
                if (active < self.entries[slot].max_concurrency and active < min_leases) {
                    min_leases = active;
                    best_slot = slot;
                }
            }
        }

        if (best_slot) |slot| {
            if (self.entries[slot].tryAcquireLease()) {
                return ProxyLease.init(
                    self,
                    slot,
                    self.entries[slot].raw_url,
                    self.entries[slot].redacted_url,
                    &self.entries[slot].endpoint,
                );
            }
        }

        i = 0;
        while (i < total) : (i += 1) {
            const slot = (start + i) % total;
            if (!self.entries[slot].health.isBanned(now_ms)) {
                if (self.entries[slot].tryAcquireLease()) {
                    return ProxyLease.init(
                        self,
                        slot,
                        self.entries[slot].raw_url,
                        self.entries[slot].redacted_url,
                        &self.entries[slot].endpoint,
                    );
                }
            }
        }

        var fallback_slot = start % total;
        var fallback_min: u32 = std.math.maxInt(u32);
        i = 0;
        while (i < total) : (i += 1) {
            const slot = (start + i) % total;
            const active = self.entries[slot].active_leases.load(.monotonic);
            if (active < fallback_min) {
                fallback_min = active;
                fallback_slot = slot;
            }
        }

        if (self.entries[fallback_slot].tryAcquireLease()) {
            return ProxyLease.init(
                self,
                fallback_slot,
                self.entries[fallback_slot].raw_url,
                self.entries[fallback_slot].redacted_url,
                &self.entries[fallback_slot].endpoint,
            );
        }

        return null;
    }

    pub fn releaseLease(self: *ProxyPool, slot_index: usize) void {
        if (slot_index < self.entries.len) {
            self.entries[slot_index].releaseLease();
        }
    }

    pub fn getActiveLeases(self: *const ProxyPool, slot_index: usize) u32 {
        if (slot_index < self.entries.len) {
            return self.entries[slot_index].active_leases.load(.monotonic);
        }
        return 0;
    }


    pub fn registerSuccess(self: *ProxyPool, slot_index: usize) void {
        if (slot_index < self.entries.len) {
            self.entries[slot_index].health.registerSuccess();
        }
    }

    pub fn registerFailure(self: *ProxyPool, slot_index: usize) void {
        if (slot_index < self.entries.len) {
            self.entries[slot_index].health.registerFailure(time.nowMs());
        }
    }

    pub fn getStats(self: *const ProxyPool, slot_index: usize) ?PoolStats {
        if (slot_index >= self.entries.len) return null;
        const entry = &self.entries[slot_index];
        const h_stats = entry.health.getStats(time.nowMs());
        return .{
            .url = entry.redacted_url,
            .successes = h_stats.successes,
            .failures = h_stats.failures,
            .banned = h_stats.banned,
        };
    }
};
