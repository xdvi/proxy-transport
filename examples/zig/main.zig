const std = @import("std");
const proxy = @import("proxy_transport");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const sample_config =
        \\# Proxy list configuration
        \\http://proxy-us-east.internal:8080
        \\http://proxy-eu-west.internal:3128
        \\socks5://proxy-ap-south.internal:1080
    ;

    var pool = try proxy.pool.ProxyPool.fromText(allocator, sample_config, 3, 60_000);
    defer pool.deinit();

    std.debug.print("Proxy Pool initialized with {d} proxies\n", .{pool.len()});

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (pool.acquireLease()) |lease| {
            std.debug.print("Acquired lease slot {d}: {s}\n", .{
                lease.getSlotIndex(),
                lease.getUrl(),
            });
        }
    }
}
