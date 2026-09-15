const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicUsize = std.atomic.Value(usize);
const ProxyHealth = @import("health.zig").ProxyHealth;
const ProxyLease = @import("lease.zig").ProxyLease;
const parser = @import("parser.zig");
const time = @import("../utils/time.zig");

pub const ProxyEntry = struct {
    raw_url: []const u8,
    redacted_url: []const u8,
    health: ProxyHealth,
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

    pub fn init(
        allocator: Allocator,
        urls: []const []const u8,
        failure_threshold: u32,
        cooldown_ms: u64,
    ) !ProxyPool {
        const entries = try allocator.alloc(ProxyEntry, urls.len);
        errdefer allocator.free(entries);

        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                allocator.free(entry.raw_url);
                allocator.free(entry.redacted_url);
            }
        }

        for (urls, 0..) |url, i| {
            const normalized = try parser.normalizeUrl(allocator, url);
            errdefer allocator.free(normalized);
            const redacted = try parser.redactUrl(allocator, normalized);
            errdefer allocator.free(redacted);

            entries[i] = .{
                .raw_url = normalized,
                .redacted_url = redacted,
                .health = ProxyHealth.init(failure_threshold, cooldown_ms),
            };
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .next_index = AtomicUsize.init(0),
            .failure_threshold = failure_threshold,
            .cooldown_ms = cooldown_ms,
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
        for (self.entries) |entry| {
            self.allocator.free(entry.raw_url);
            self.allocator.free(entry.redacted_url);
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

        var i: usize = 0;
        while (i < total) : (i += 1) {
            const slot = (start + i) % total;
            if (!self.entries[slot].health.isBanned(now_ms)) {
                return ProxyLease.init(
                    self,
                    slot,
                    self.entries[slot].raw_url,
                    self.entries[slot].redacted_url,
                );
            }
        }

        const fallback_slot = start % total;
        return ProxyLease.init(
            self,
            fallback_slot,
            self.entries[fallback_slot].raw_url,
            self.entries[fallback_slot].redacted_url,
        );
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
