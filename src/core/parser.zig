const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn parseLines(allocator: Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item);
        }
        list.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        const owned = try allocator.dupe(u8, line);
        try list.append(allocator, owned);
    }

    return try list.toOwnedSlice(allocator);
}

pub fn redactUrl(allocator: Allocator, url: []const u8) ![]const u8 {
    const at_index = std.mem.indexOfScalar(u8, url, '@') orelse {
        return try allocator.dupe(u8, url);
    };

    const scheme_end = if (std.mem.indexOf(u8, url, "://")) |idx| idx + 3 else 0;
    if (at_index < scheme_end) {
        return try allocator.dupe(u8, url);
    }

    return try std.fmt.allocPrint(allocator, "{s}{s}", .{
        url[0..scheme_end],
        url[at_index + 1 ..],
    });
}

pub fn normalizeUrl(allocator: Allocator, url: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, url, "://") != null) {
        return try allocator.dupe(u8, url);
    }
    return try std.fmt.allocPrint(allocator, "http://{s}", .{url});
}
