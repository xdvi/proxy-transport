const std = @import("std");
const errors = @import("../utils/errors.zig");
const ProxyErrorCode = errors.ProxyErrorCode;
pub const ProxyErrorInfo = errors.ProxyErrorInfo;
pub const ProxyStats = errors.ProxyStats;
pub const ProxyEndpointInfo = errors.ProxyEndpointInfo;
const ProxyPool = @import("../core/pool.zig").ProxyPool;
const ProxyLease = @import("../core/lease.zig").ProxyLease;
const ProxyEndpoint = @import("../core/endpoint.zig").ProxyEndpoint;
const tunnel = @import("../http/tunnel.zig");

const CANARY_POOL_ACTIVE: u64 = 0x50525859_504F4F4C;
const CANARY_LEASE_ACTIVE: u64 = 0x50525859_4C454153;
const CANARY_FREED: u64 = 0x50525859_44454144;

pub const ProxyPoolHandle = struct {
    canary: u64,
    pool: ProxyPool,
};

pub const ProxyLeaseHandle = struct {
    canary: u64,
    lease: ProxyLease,
};

threadlocal var last_error_code: i32 = 0;
threadlocal var last_error_message: [256]u8 = [_]u8{0} ** 256;

pub fn setLastError(code: ProxyErrorCode, msg: []const u8) void {
    last_error_code = code.toI32();
    @memset(&last_error_message, 0);
    const copy_len = @min(msg.len, last_error_message.len - 1);
    @memcpy(last_error_message[0..copy_len], msg[0..copy_len]);
}

pub fn clearLastError() void {
    last_error_code = 0;
    @memset(&last_error_message, 0);
}

fn validatePoolHandle(handle: ?*const ProxyPoolHandle) ?*ProxyPoolHandle {
    if (handle == null) {
        setLastError(.InvalidHandle, "Null pool handle");
        return null;
    }
    const h = @constCast(handle.?);
    if (h.canary == CANARY_FREED) {
        setLastError(.UseAfterFree, "Pool handle used after free");
        return null;
    }
    if (h.canary != CANARY_POOL_ACTIVE) {
        setLastError(.InvalidHandle, "Invalid pool handle canary");
        return null;
    }
    return h;
}

fn validateLeaseHandle(handle: ?*const ProxyLeaseHandle) ?*ProxyLeaseHandle {
    if (handle == null) {
        setLastError(.InvalidHandle, "Null lease handle");
        return null;
    }
    const h = @constCast(handle.?);
    if (h.canary == CANARY_FREED) {
        setLastError(.UseAfterFree, "Lease handle used after free");
        return null;
    }
    if (h.canary != CANARY_LEASE_ACTIVE) {
        setLastError(.InvalidHandle, "Invalid lease handle canary");
        return null;
    }
    return h;
}

pub export fn proxy_pool_new(
    urls: ?[*]const ?[*:0]const u8,
    count: usize,
    failure_threshold: u32,
    cooldown_ms: u64,
) callconv(.c) ?*ProxyPoolHandle {
    const allocator = std.heap.c_allocator;

    var url_slices = allocator.alloc([]const u8, count) catch {
        setLastError(.OutOfMemory, "Failed to allocate url slice buffer");
        return null;
    };
    defer allocator.free(url_slices);

    if (urls) |u_ptr| {
        for (0..count) |i| {
            if (u_ptr[i]) |str| {
                url_slices[i] = std.mem.span(str);
            } else {
                setLastError(.InvalidArgument, "Null url in array");
                return null;
            }
        }
    } else if (count > 0) {
        setLastError(.InvalidArgument, "Null url pointer with count > 0");
        return null;
    }

    const pool = ProxyPool.init(allocator, url_slices, failure_threshold, cooldown_ms) catch {
        setLastError(.OutOfMemory, "Failed to initialize pool: OOM");
        return null;
    };

    const handle = allocator.create(ProxyPoolHandle) catch {
        var p = pool;
        p.deinit();
        setLastError(.OutOfMemory, "Failed to allocate pool handle");
        return null;
    };

    handle.* = .{
        .canary = CANARY_POOL_ACTIVE,
        .pool = pool,
    };
    return handle;
}

pub export fn proxy_pool_from_text(
    proxy_list_text: ?[*:0]const u8,
    failure_threshold: u32,
    cooldown_ms: u64,
) callconv(.c) ?*ProxyPoolHandle {
    if (proxy_list_text == null) {
        setLastError(.InvalidArgument, "Null proxy list text");
        return null;
    }
    const allocator = std.heap.c_allocator;
    const text_slice = std.mem.span(proxy_list_text.?);

    const pool = ProxyPool.fromText(allocator, text_slice, failure_threshold, cooldown_ms) catch {
        setLastError(.OutOfMemory, "Failed to parse text: OOM");
        return null;
    };

    const handle = allocator.create(ProxyPoolHandle) catch {
        var p = pool;
        p.deinit();
        setLastError(.OutOfMemory, "Failed to allocate pool handle");
        return null;
    };

    handle.* = .{
        .canary = CANARY_POOL_ACTIVE,
        .pool = pool,
    };
    return handle;
}

const c = struct {
    extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fclose(stream: *anyopaque) c_int;
    extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: *anyopaque) c_long;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
};

pub export fn proxy_pool_from_file(
    file_path: ?[*:0]const u8,
    failure_threshold: u32,
    cooldown_ms: u64,
) callconv(.c) ?*ProxyPoolHandle {
    if (file_path == null) {
        setLastError(.InvalidArgument, "Null file path");
        return null;
    }
    const allocator = std.heap.c_allocator;
    const path = file_path.?;

    const file = c.fopen(path, "rb") orelse {
        setLastError(.IoError, "Failed to open proxy file");
        return null;
    };
    defer _ = c.fclose(file);

    _ = c.fseek(file, 0, 2);
    const size_long = c.ftell(file);
    if (size_long < 0) {
        setLastError(.IoError, "Failed to get file size");
        return null;
    }
    const size: usize = @intCast(size_long);
    _ = c.fseek(file, 0, 0);

    const content = allocator.alloc(u8, size) catch {
        setLastError(.OutOfMemory, "Failed to allocate buffer for file content");
        return null;
    };
    defer allocator.free(content);

    const read_bytes = c.fread(content.ptr, 1, size, file);
    if (read_bytes != size) {
        setLastError(.IoError, "Failed to read all bytes from proxy file");
        return null;
    }

    const pool = ProxyPool.fromText(allocator, content, failure_threshold, cooldown_ms) catch {
        setLastError(.InvalidArgument, "Failed to parse proxy file content");
        return null;
    };

    const handle = allocator.create(ProxyPoolHandle) catch {
        var p = pool;
        p.deinit();
        setLastError(.OutOfMemory, "Failed to allocate pool handle");
        return null;
    };

    handle.* = .{
        .canary = CANARY_POOL_ACTIVE,
        .pool = pool,
    };
    return handle;
}

pub export fn proxy_pool_free(handle: ?*ProxyPoolHandle) callconv(.c) void {
    const h = validatePoolHandle(handle) orelse return;
    h.pool.deinit();
    h.canary = CANARY_FREED;
    std.heap.c_allocator.destroy(h);
}

pub export fn proxy_pool_reload_urls(
    handle: ?*ProxyPoolHandle,
    urls: ?[*]const ?[*:0]const u8,
    count: usize,
) callconv(.c) i32 {
    const h = validatePoolHandle(handle) orelse return last_error_code;
    const allocator = std.heap.c_allocator;

    var url_slices = allocator.alloc([]const u8, count) catch {
        setLastError(.OutOfMemory, "Failed to allocate url slice buffer");
        return ProxyErrorCode.OutOfMemory.toI32();
    };
    defer allocator.free(url_slices);

    if (urls) |u_ptr| {
        for (0..count) |i| {
            if (u_ptr[i]) |str| {
                url_slices[i] = std.mem.span(str);
            } else {
                setLastError(.InvalidArgument, "Null url in array");
                return ProxyErrorCode.InvalidArgument.toI32();
            }
        }
    } else if (count > 0) {
        setLastError(.InvalidArgument, "Null url pointer with count > 0");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    h.pool.reloadUrls(url_slices) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                setLastError(.OutOfMemory, "Failed to reload pool: OOM");
                return ProxyErrorCode.OutOfMemory.toI32();
            },
            else => {
                setLastError(.InvalidArgument, "Failed to reload pool: invalid URL configuration");
                return ProxyErrorCode.InvalidArgument.toI32();
            },
        }
    };

    return 0;
}

pub export fn proxy_pool_reload_from_text(
    handle: ?*ProxyPoolHandle,
    proxy_list_text: ?[*:0]const u8,
) callconv(.c) i32 {
    const h = validatePoolHandle(handle) orelse return last_error_code;
    if (proxy_list_text == null) {
        setLastError(.InvalidArgument, "Null proxy list text");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    const text_slice = std.mem.span(proxy_list_text.?);
    h.pool.reloadFromText(text_slice) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                setLastError(.OutOfMemory, "Failed to reload pool from text: OOM");
                return ProxyErrorCode.OutOfMemory.toI32();
            },
            else => {
                setLastError(.InvalidArgument, "Failed to reload pool: invalid text content");
                return ProxyErrorCode.InvalidArgument.toI32();
            },
        }
    };

    return 0;
}


pub export fn proxy_pool_acquire_lease(handle: ?*const ProxyPoolHandle) callconv(.c) ?*ProxyLeaseHandle {
    const h = validatePoolHandle(handle) orelse return null;
    const maybe_lease = h.pool.acquireLease();
    if (maybe_lease == null) {
        return null;
    }

    const lease_handle = std.heap.c_allocator.create(ProxyLeaseHandle) catch {
        setLastError(.OutOfMemory, "Failed to allocate lease handle");
        return null;
    };

    lease_handle.* = .{
        .canary = CANARY_LEASE_ACTIVE,
        .lease = maybe_lease.?,
    };
    return lease_handle;
}

pub export fn proxy_lease_free(lease: ?*ProxyLeaseHandle) callconv(.c) void {
    const h = validateLeaseHandle(lease) orelse return;
    h.lease.release();
    h.canary = CANARY_FREED;
    std.heap.c_allocator.destroy(h);
}


pub export fn proxy_lease_get_url(
    lease: ?*const ProxyLeaseHandle,
    out_buf: ?[*]u8,
    out_len: usize,
    out_written: ?*usize,
) callconv(.c) i32 {
    const h = validateLeaseHandle(lease) orelse return last_error_code;
    if (out_buf == null or out_written == null) {
        setLastError(.InvalidArgument, "Null output buffer or written pointer");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    const url = h.lease.getUrl();
    if (url.len > out_len) {
        setLastError(.BufferTooSmall, "Output buffer too small");
        return ProxyErrorCode.BufferTooSmall.toI32();
    }

    @memcpy(out_buf.?[0..url.len], url);
    out_written.?.* = url.len;
    return 0;
}

pub export fn proxy_lease_get_endpoint(
    lease: ?*const ProxyLeaseHandle,
    out_endpoint: ?*ProxyEndpointInfo,
) callconv(.c) i32 {
    const h = validateLeaseHandle(lease) orelse return last_error_code;
    if (out_endpoint == null) {
        setLastError(.InvalidArgument, "Null out_endpoint pointer");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    const ep = h.lease.getEndpoint();
    var info: ProxyEndpointInfo = undefined;
    info.scheme = @intFromEnum(ep.scheme);
    @memset(&info.host, 0);
    const host_len = @min(ep.host.len, info.host.len - 1);
    @memcpy(info.host[0..host_len], ep.host[0..host_len]);
    info.port = ep.port;

    info.has_auth = ep.username != null or ep.password != null;
    @memset(&info.username, 0);
    if (ep.username) |u| {
        const u_len = @min(u.len, info.username.len - 1);
        @memcpy(info.username[0..u_len], u[0..u_len]);
    }

    @memset(&info.password, 0);
    if (ep.password) |p| {
        const p_len = @min(p.len, info.password.len - 1);
        @memcpy(info.password[0..p_len], p[0..p_len]);
    }

    @memset(&info.auth_header, 0);
    if (ep.auth_header) |a| {
        const a_len = @min(a.len, info.auth_header.len - 1);
        @memcpy(info.auth_header[0..a_len], a[0..a_len]);
    }

    out_endpoint.?.* = info;
    return 0;
}

pub export fn proxy_lease_get_index(lease: ?*const ProxyLeaseHandle) callconv(.c) usize {
    const h = validateLeaseHandle(lease) orelse return 0;
    return h.lease.getSlotIndex();
}

pub export fn proxy_lease_register_success(lease: ?*ProxyLeaseHandle) callconv(.c) void {
    const h = validateLeaseHandle(lease) orelse return;
    h.lease.registerSuccess();
}

pub export fn proxy_lease_register_failure(lease: ?*ProxyLeaseHandle) callconv(.c) void {
    const h = validateLeaseHandle(lease) orelse return;
    h.lease.registerFailure();
}

pub export fn proxy_pool_len(handle: ?*const ProxyPoolHandle) callconv(.c) usize {
    const h = validatePoolHandle(handle) orelse return 0;
    return h.pool.len();
}

pub export fn proxy_pool_uses_proxy(handle: ?*const ProxyPoolHandle) callconv(.c) bool {
    const h = validatePoolHandle(handle) orelse return false;
    return h.pool.usesProxy();
}

pub export fn proxy_pool_is_rotating(handle: ?*const ProxyPoolHandle) callconv(.c) bool {
    const h = validatePoolHandle(handle) orelse return false;
    return h.pool.isRotating();
}

pub export fn proxy_pool_get_stats(
    handle: ?*const ProxyPoolHandle,
    slot_index: usize,
    out_stats: ?*ProxyStats,
) callconv(.c) i32 {
    const h = validatePoolHandle(handle) orelse return last_error_code;
    if (out_stats == null) {
        setLastError(.InvalidArgument, "Null output stats pointer");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    const stats = h.pool.getStats(slot_index) orelse {
        setLastError(.InvalidArgument, "Slot index out of range");
        return ProxyErrorCode.InvalidArgument.toI32();
    };

    @memset(&out_stats.?.url, 0);
    const copy_len = @min(stats.url.len, out_stats.?.url.len - 1);
    @memcpy(out_stats.?.url[0..copy_len], stats.url[0..copy_len]);
    out_stats.?.successes = stats.successes;
    out_stats.?.failures = stats.failures;
    out_stats.?.banned = stats.banned;
    return 0;
}

pub export fn proxy_pool_get_active_leases(handle: ?*const ProxyPoolHandle, slot_index: usize) callconv(.c) u32 {
    const h = validatePoolHandle(handle) orelse return 0;
    return h.pool.getActiveLeases(slot_index);
}


pub export fn proxy_format_connect_request(
    endpoint: ?*const ProxyEndpointInfo,
    target_host: ?[*:0]const u8,
    target_port: u16,
    out_buf: ?[*]u8,
    out_len: usize,
    out_written: ?*usize,
) callconv(.c) i32 {
    if (endpoint == null or target_host == null or out_buf == null or out_written == null) {
        setLastError(.InvalidArgument, "Null arguments in proxy_format_connect_request");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    const ep_info = endpoint.?;
    const host_slice = std.mem.span(target_host.?);

    const auth_str = if (ep_info.has_auth) std.mem.sliceTo(&ep_info.auth_header, 0) else null;
    const auth = if (auth_str != null and auth_str.?.len > 0) auth_str.? else null;

    const dummy_ep = ProxyEndpoint{
        .scheme = .http,
        .host = "",
        .port = 80,
        .username = null,
        .password = null,
        .auth_header = auth,
    };

    const formatted = tunnel.formatConnectRequest(&dummy_ep, host_slice, target_port, out_buf.?[0..out_len]) catch |err| {
        switch (err) {
            error.NoSpaceLeft => {
                setLastError(.BufferTooSmall, "Output buffer too small for CONNECT request");
                return ProxyErrorCode.BufferTooSmall.toI32();
            },
        }
    };

    out_written.?.* = formatted.len;
    return 0;
}

pub export fn proxy_parse_connect_response(
    response: ?[*]const u8,
    response_len: usize,
) callconv(.c) i32 {
    if (response == null or response_len == 0) {
        setLastError(.InvalidArgument, "Empty or null response buffer");
        return ProxyErrorCode.InvalidArgument.toI32();
    }

    tunnel.parseConnectResponse(response.?[0..response_len]) catch |err| {
        switch (err) {
            error.ProxyAuthenticationRequired => {
                setLastError(.InvalidArgument, "Proxy authentication required (HTTP 407)");
                return -407;
            },
            error.ProxyForbidden => {
                setLastError(.InvalidArgument, "Proxy connection forbidden (HTTP 403)");
                return -403;
            },
            error.ProxyConnectionRefused => {
                setLastError(.IoError, "Proxy connection refused / gateway error");
                return -502;
            },
            else => {
                setLastError(.IoError, "Proxy tunnel failed");
                return -500;
            },
        }
    };

    return 0;
}

pub export fn proxy_get_last_error(out_info: ?*ProxyErrorInfo) callconv(.c) i32 {
    if (out_info == null) {
        return last_error_code;
    }
    out_info.?.code = last_error_code;
    @memcpy(&out_info.?.message, &last_error_message);
    return last_error_code;
}

pub export fn proxy_clear_last_error() callconv(.c) void {
    clearLastError();
}
