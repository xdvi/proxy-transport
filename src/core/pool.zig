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

    pub fn deinit(self: *ProxyEntry, allocator: Allocator) void {
        allocator.free(self.raw_url);
        allocator.free(self.redacted_url);
        self.endpoint.deinit(allocator);
        allocator.destroy(self);
    }

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
    entries: []*ProxyEntry,
    draining: std.ArrayList(*ProxyEntry),
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
        const entries = try allocator.alloc(*ProxyEntry, urls.len);
        errdefer allocator.free(entries);

        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                entry.deinit(allocator);
            }
        }

        for (urls, 0..) |url, i| {
            const normalized = try parser.normalizeUrl(allocator, url);
            errdefer allocator.free(normalized);
            const redacted = try parser.redactUrl(allocator, normalized);
            errdefer allocator.free(redacted);
            var ep = try ProxyEndpoint.parse(allocator, normalized);
            errdefer ep.deinit(allocator);

            const entry = try allocator.create(ProxyEntry);
            entry.* = .{
                .raw_url = normalized,
                .redacted_url = redacted,
                .endpoint = ep,
                .health = ProxyHealth.initWithMax(failure_threshold, cooldown_ms, cooldown_ms *| 16),
                .active_leases = AtomicU32.init(0),
                .max_concurrency = max_concurrency,
            };
            entries[i] = entry;
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .draining = .empty,
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
        for (self.entries) |entry| {
            entry.deinit(self.allocator);
        }
        self.allocator.free(self.entries);

        for (self.draining.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.draining.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn cleanupDraining(self: *ProxyPool) void {
        var idx: usize = 0;
        while (idx < self.draining.items.len) {
            const entry = self.draining.items[idx];
            if (entry.active_leases.load(.monotonic) == 0) {
                _ = self.draining.orderedRemove(idx);
                entry.deinit(self.allocator);
            } else {
                idx += 1;
            }
        }
    }

    pub fn reloadUrls(self: *ProxyPool, new_urls: []const []const u8) !void {
        const ParsedItem = struct {
            raw: []const u8,
            redacted: []const u8,
            endpoint: ProxyEndpoint,
        };

        const parsed_items = try self.allocator.alloc(ParsedItem, new_urls.len);
        defer self.allocator.free(parsed_items);

        var parsed_count: usize = 0;
        errdefer {
            for (parsed_items[0..parsed_count]) |*item| {
                self.allocator.free(item.raw);
                self.allocator.free(item.redacted);
                item.endpoint.deinit(self.allocator);
            }
        }

        for (new_urls, 0..) |url, i| {
            const normalized = try parser.normalizeUrl(self.allocator, url);
            errdefer self.allocator.free(normalized);
            const redacted = try parser.redactUrl(self.allocator, normalized);
            errdefer self.allocator.free(redacted);
            var ep = try ProxyEndpoint.parse(self.allocator, normalized);
            errdefer ep.deinit(self.allocator);

            parsed_items[i] = .{
                .raw = normalized,
                .redacted = redacted,
                .endpoint = ep,
            };
            parsed_count += 1;
        }

        const new_entries = try self.allocator.alloc(*ProxyEntry, new_urls.len);
        errdefer self.allocator.free(new_entries);

        var initialized: usize = 0;
        errdefer {
            for (new_entries[0..initialized]) |entry| {
                var was_existing = false;
                for (self.entries) |existing| {
                    if (existing == entry) {
                        was_existing = true;
                        break;
                    }
                }
                if (!was_existing) {
                    entry.deinit(self.allocator);
                }
            }
        }

        for (parsed_items, 0..) |*item, i| {
            var existing_entry: ?*ProxyEntry = null;

            for (self.entries) |existing| {
                if (std.mem.eql(u8, existing.raw_url, item.raw)) {
                    existing_entry = existing;
                    break;
                }
            }

            if (existing_entry == null) {
                var d_idx: usize = 0;
                while (d_idx < self.draining.items.len) {
                    if (std.mem.eql(u8, self.draining.items[d_idx].raw_url, item.raw)) {
                        existing_entry = self.draining.orderedRemove(d_idx);
                        break;
                    } else {
                        d_idx += 1;
                    }
                }
            }

            if (existing_entry) |reused| {
                self.allocator.free(item.raw);
                self.allocator.free(item.redacted);
                item.endpoint.deinit(self.allocator);
                new_entries[i] = reused;
            } else {
                const entry = try self.allocator.create(ProxyEntry);
                entry.* = .{
                    .raw_url = item.raw,
                    .redacted_url = item.redacted,
                    .endpoint = item.endpoint,
                    .health = ProxyHealth.initWithMax(self.failure_threshold, self.cooldown_ms, self.cooldown_ms *| 16),
                    .active_leases = AtomicU32.init(0),
                    .max_concurrency = self.max_concurrency_per_proxy,
                };
                new_entries[i] = entry;
            }
            initialized += 1;
        }

        for (self.entries) |old_entry| {
            var retained = false;
            for (new_entries) |new_entry| {
                if (old_entry == new_entry) {
                    retained = true;
                    break;
                }
            }

            if (!retained) {
                if (old_entry.active_leases.load(.monotonic) > 0) {
                    try self.draining.append(self.allocator, old_entry);
                } else {
                    old_entry.deinit(self.allocator);
                }
            }
        }

        self.allocator.free(self.entries);
        self.entries = new_entries;
        self.cleanupDraining();
    }

    pub fn reloadFromText(self: *ProxyPool, text: []const u8) !void {
        const parsed_lines = try parser.parseLines(self.allocator, text);
        defer {
            for (parsed_lines) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(parsed_lines);
        }

        return self.reloadUrls(parsed_lines);
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
                return ProxyLease.init(self, self.entries[slot], slot);
            }
        }

        i = 0;
        while (i < total) : (i += 1) {
            const slot = (start + i) % total;
            if (!self.entries[slot].health.isBanned(now_ms)) {
                if (self.entries[slot].tryAcquireLease()) {
                    return ProxyLease.init(self, self.entries[slot], slot);
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
            return ProxyLease.init(self, self.entries[fallback_slot], fallback_slot);
        }

        return null;
    }

    pub fn releaseLease(self: *ProxyPool, slot_index: usize) void {
        if (slot_index < self.entries.len) {
            self.entries[slot_index].releaseLease();
            self.cleanupDraining();
        }
    }

    pub fn getActiveLeases(self: *const ProxyPool, slot_index: usize) u32 {
        if (slot_index < self.entries.len) {
            return self.entries[slot_index].active_leases.load(.monotonic);
        }
        return 0;
    }

    pub fn getTotalActiveLeases(self: *const ProxyPool) usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total += entry.active_leases.load(.monotonic);
        }
        for (self.draining.items) |entry| {
            total += entry.active_leases.load(.monotonic);
        }
        return total;
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
        const entry = self.entries[slot_index];
        const h_stats = entry.health.getStats(time.nowMs());
        return .{
            .url = entry.redacted_url,
            .successes = h_stats.successes,
            .failures = h_stats.failures,
            .banned = h_stats.banned,
        };
    }
};
