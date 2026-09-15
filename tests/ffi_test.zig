const std = @import("std");
const proxy = @import("proxy_transport");
const testing = std.testing;

test "ffi: lifecycle new, lease acquire, get_url, feedback, and free" {
    const urls = [_][*:0]const u8{
        "http://proxy1.local:8080",
        "http://proxy2.local:8080",
    };

    const pool = proxy.ffi.proxy_pool_new(&urls, urls.len, 3, 60_000);
    try testing.expect(pool != null);
    defer proxy.ffi.proxy_pool_free(pool);

    try testing.expectEqual(@as(usize, 2), proxy.ffi.proxy_pool_len(pool));
    try testing.expect(proxy.ffi.proxy_pool_uses_proxy(pool));
    try testing.expect(proxy.ffi.proxy_pool_is_rotating(pool));

    const lease = proxy.ffi.proxy_pool_acquire_lease(pool);
    try testing.expect(lease != null);
    defer proxy.ffi.proxy_lease_free(lease);

    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const rc = proxy.ffi.proxy_lease_get_url(lease, &buf, buf.len, &written);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqualStrings("http://proxy1.local:8080", buf[0..written]);

    proxy.ffi.proxy_lease_register_success(lease);

    var stats: proxy.ffi.ProxyStats = undefined;
    const stats_rc = proxy.ffi.proxy_pool_get_stats(pool, 0, &stats);
    try testing.expectEqual(@as(i32, 0), stats_rc);
    try testing.expectEqual(@as(u64, 1), stats.successes);
    try testing.expectEqual(@as(u64, 0), stats.failures);
}

test "ffi: active lease tracking and decrement on proxy_lease_free" {
    const urls = [_][*:0]const u8{
        "http://proxy1.local:8080",
    };

    const pool = proxy.ffi.proxy_pool_new(&urls, urls.len, 3, 60_000);
    try testing.expect(pool != null);
    defer proxy.ffi.proxy_pool_free(pool);

    try testing.expectEqual(@as(u32, 0), proxy.ffi.proxy_pool_get_active_leases(pool, 0));

    const lease = proxy.ffi.proxy_pool_acquire_lease(pool);
    try testing.expect(lease != null);
    try testing.expectEqual(@as(u32, 1), proxy.ffi.proxy_pool_get_active_leases(pool, 0));

    proxy.ffi.proxy_lease_free(lease);
    try testing.expectEqual(@as(u32, 0), proxy.ffi.proxy_pool_get_active_leases(pool, 0));
}


test "ffi: from_text parses string pool" {
    const text: [:0]const u8 =
        \\# comment
        \\http://single-proxy.internal:3128
        \\
    ;

    const pool = proxy.ffi.proxy_pool_from_text(text.ptr, 3, 60_000);
    try testing.expect(pool != null);
    defer proxy.ffi.proxy_pool_free(pool);

    try testing.expectEqual(@as(usize, 1), proxy.ffi.proxy_pool_len(pool));
    try testing.expect(proxy.ffi.proxy_pool_uses_proxy(pool));
    try testing.expect(!proxy.ffi.proxy_pool_is_rotating(pool));
}

test "ffi: invalid handle returns PROXY_INVALID_HANDLE" {
    var dummy: u64 = 0x12345678;
    const invalid_handle: *proxy.ffi.ProxyPoolHandle = @ptrCast(&dummy);

    try testing.expectEqual(@as(usize, 0), proxy.ffi.proxy_pool_len(invalid_handle));

    var err_info: proxy.ffi.ProxyErrorInfo = undefined;
    const has_err = proxy.ffi.proxy_get_last_error(&err_info);
    try testing.expectEqual(@as(i32, -6), has_err);
    try testing.expectEqual(@as(i32, -6), err_info.code);
}

test "ffi: buffer too small returns error" {
    const urls = [_][*:0]const u8{
        "http://proxy1.local:8080",
    };
    const pool = proxy.ffi.proxy_pool_new(&urls, 1, 3, 60_000);
    defer proxy.ffi.proxy_pool_free(pool);

    const lease = proxy.ffi.proxy_pool_acquire_lease(pool);
    defer proxy.ffi.proxy_lease_free(lease);

    var small_buf: [5]u8 = undefined;
    var written: usize = 0;
    const rc = proxy.ffi.proxy_lease_get_url(lease, &small_buf, small_buf.len, &written);
    try testing.expectEqual(@as(i32, -3), rc);
}

const c_file = struct {
    extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fclose(stream: *anyopaque) c_int;
    extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
    extern "c" fn remove(pathname: [*:0]const u8) c_int;
};

test "ffi: from_file reads lines from disk" {
    const file_path: [:0]const u8 = "tests/test_proxies.txt";
    const f = c_file.fopen(file_path.ptr, "wb") orelse return error.TestUnexpectedResult;
    const sample = "# sample\nhttp://file-proxy.test:8080\n";
    _ = c_file.fwrite(sample.ptr, 1, sample.len, f);
    _ = c_file.fclose(f);
    defer _ = c_file.remove(file_path.ptr);

    const pool = proxy.ffi.proxy_pool_from_file(file_path.ptr, 3, 60_000);
    try testing.expect(pool != null);
    defer proxy.ffi.proxy_pool_free(pool);

    try testing.expectEqual(@as(usize, 1), proxy.ffi.proxy_pool_len(pool));
}

test "ffi: use after free canary returns PROXY_USE_AFTER_FREE" {
    var poisoned = proxy.ffi.ProxyPoolHandle{
        .canary = 0x50525859_44454144,
        .pool = undefined,
    };
    try testing.expectEqual(@as(usize, 0), proxy.ffi.proxy_pool_len(&poisoned));

    var err_info: proxy.ffi.ProxyErrorInfo = undefined;
    const code = proxy.ffi.proxy_get_last_error(&err_info);
    try testing.expectEqual(@as(i32, -7), code);
}

test "ffi: lease returns structured endpoint info" {
    const urls = [_][*:0]const u8{
        "http://bot:secret@127.0.0.1:8888",
    };
    const pool = proxy.ffi.proxy_pool_new(&urls, 1, 3, 60_000);
    defer proxy.ffi.proxy_pool_free(pool);

    const lease = proxy.ffi.proxy_pool_acquire_lease(pool);
    defer proxy.ffi.proxy_lease_free(lease);

    var ep: proxy.ffi.ProxyEndpointInfo = undefined;
    const rc = proxy.ffi.proxy_lease_get_endpoint(lease, &ep);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqual(@as(i32, 0), ep.scheme);
    try testing.expectEqualStrings("127.0.0.1", std.mem.sliceTo(&ep.host, 0));
    try testing.expectEqual(@as(u16, 8888), ep.port);
    try testing.expect(ep.has_auth);
    try testing.expectEqualStrings("bot", std.mem.sliceTo(&ep.username, 0));
    try testing.expectEqualStrings("secret", std.mem.sliceTo(&ep.password, 0));
    try testing.expectEqualStrings("Basic Ym90OnNlY3JldA==", std.mem.sliceTo(&ep.auth_header, 0));
}

test "ffi: format connect request and parse response via C-ABI" {
    const urls = [_][*:0]const u8{
        "http://bot:secret@127.0.0.1:8888",
    };
    const pool = proxy.ffi.proxy_pool_new(&urls, 1, 3, 60_000);
    defer proxy.ffi.proxy_pool_free(pool);

    const lease = proxy.ffi.proxy_pool_acquire_lease(pool);
    defer proxy.ffi.proxy_lease_free(lease);

    var ep: proxy.ffi.ProxyEndpointInfo = undefined;
    _ = proxy.ffi.proxy_lease_get_endpoint(lease, &ep);

    var buf: [512]u8 = undefined;
    var written: usize = 0;
    const target: [:0]const u8 = "adres.gov.co";
    const rc = proxy.ffi.proxy_format_connect_request(&ep, target.ptr, 443, &buf, buf.len, &written);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expect(std.mem.startsWith(u8, buf[0..written], "CONNECT adres.gov.co:443 HTTP/1.1\r\n"));

    const resp_ok = "HTTP/1.1 200 OK\r\n\r\n";
    const parse_rc = proxy.ffi.proxy_parse_connect_response(resp_ok.ptr, resp_ok.len);
    try testing.expectEqual(@as(i32, 0), parse_rc);

    const resp_auth_err = "HTTP/1.1 407 Proxy Auth\r\n\r\n";
    const auth_err_rc = proxy.ffi.proxy_parse_connect_response(resp_auth_err.ptr, resp_auth_err.len);
    try testing.expect(auth_err_rc < 0);
}
