const std = @import("std");

test {
    _ = @import("parser_test.zig");
    _ = @import("health_test.zig");
    _ = @import("pool_test.zig");
    _ = @import("ffi_test.zig");
}
