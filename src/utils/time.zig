const std = @import("std");
const builtin = @import("builtin");

pub fn nowMs() u64 {
    if (comptime builtin.os.tag == .windows) {
        const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
        const now_ns = @as(i96, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns;
        const ms = @divTrunc(now_ns, std.time.ns_per_ms);
        return if (ms < 0) 0 else @intCast(ms);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        return if (ms < 0) 0 else @intCast(ms);
    }
}

pub fn sleepMs(ms: u32) void {
    if (comptime builtin.os.tag == .windows) {
        Sleep(ms);
    } else {
        const ns: u64 = @as(u64, ms) * std.time.ns_per_ms;
        var request = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&request, null);
    }
}

const Sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
}.Sleep else {};
