const std = @import("std");
const proxy = @import("proxy_transport");
const testing = std.testing;

test "parser: ignores comments and blank lines" {
    const input =
        \\# This is a comment
        \\  
        \\http://proxy1.local:8080
        \\   # Another comment
        \\socks5://proxy2.local:1080  
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try proxy.parser.parseLines(arena.allocator(), input);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("http://proxy1.local:8080", parsed[0]);
    try testing.expectEqualStrings("socks5://proxy2.local:1080", parsed[1]);
}

test "parser: redacts credentials from url" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw = "http://myuser:secret123@proxy.example.com:8080/path";
    const redacted = try proxy.parser.redactUrl(arena.allocator(), raw);
    try testing.expectEqualStrings("http://proxy.example.com:8080/path", redacted);

    const no_auth = "http://proxy.example.com:8080";
    const unchanged = try proxy.parser.redactUrl(arena.allocator(), no_auth);
    try testing.expectEqualStrings("http://proxy.example.com:8080", unchanged);
}

test "parser: normalizes url adding default http scheme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw = "127.0.0.1:8888";
    const normalized = try proxy.parser.normalizeUrl(arena.allocator(), raw);
    try testing.expectEqualStrings("http://127.0.0.1:8888", normalized);

    const already_scheme = "socks5://127.0.0.1:1080";
    const unchanged = try proxy.parser.normalizeUrl(arena.allocator(), already_scheme);
    try testing.expectEqualStrings("socks5://127.0.0.1:1080", unchanged);
}
