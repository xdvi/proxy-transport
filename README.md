# proxy-transport

A lightweight, zero-dependency, cross-platform proxy pooling library written in Zig 0.16 with a C-ABI FFI interface. Designed specifically for high-throughput scrapers and web crawlers that require sticky session affinity, intelligent circuit-breaking, and fail-open resilience.

---

## Features

- **Session Affinity (Sticky Leases)**: Acquire a `ProxyLease` that stays pinned to a specific proxy across multi-step transactions (such as ASP.NET WebForms ViewState flows, multi-page logins, or session tokens), then report success or failure upon transaction completion.
- **Circuit Breaker & Automatic Cooldown**: Proxies exceeding the configurable failure threshold (default: 3) are automatically benched for a cooldown period (default: 60s). Expired bans recover automatically on the next rotation attempt.
- **Fail-Open Resilience**: If all proxies in the pool are temporarily benched, the pool automatically falls back to round-robin rotation rather than dropping traffic (*"any proxy beats no egress"*).
- **Credential Redaction**: Passwords and usernames in proxy URLs (`http://user:secret@host:port`) are automatically stripped in metrics and diagnostic stats to prevent credential leakage.
- **Robust C-ABI & Handle Safety**: Exported C functions use 64-bit canary guards (`0x50525859...`) and thread-local error info to detect invalid handles, double-free, and use-after-free conditions before memory corruption occurs.
- **Pure Zig & libc**: Zero third-party dependencies. Cross-compiles out of the box to Linux, Windows (with `ws2_32`), and macOS.

---

## Architecture Overview

```
                        ┌────────────────────────┐
                        │   Proxy List Config    │
                        │ (file, text, or slice) │
                        └───────────┬────────────┘
                                    │
                                    ▼
                        ┌────────────────────────┐
                        │       ProxyPool        │
                        │  (Atomic Round-Robin)  │
                        └───────────┬────────────┘
                                    │
                       acquireLease() [skips banned]
                                    │ (or fail-open)
                                    ▼
                        ┌────────────────────────┐
                        │       ProxyLease       │
                        │  (Sticky Slot Affinity)│
                        └───────────┬────────────┘
                                    │
                 ┌──────────────────┴──────────────────┐
                 ▼                                     ▼
      register_success()                      register_failure()
   (resets consecutive fails,              (increments fails,
     clears ban deadline)                    sets ban cooldown)
```

---

## C-ABI Interface

The C header is located at `include/proxy_transport.h` and installed into `zig-out/include/`.

### Error Codes

```c
typedef enum ProxyErrorCode {
    PROXY_SUCCESS = 0,
    PROXY_INVALID_ARGUMENT = -1,
    PROXY_OUT_OF_MEMORY = -2,
    PROXY_BUFFER_TOO_SMALL = -3,
    PROXY_IO_ERROR = -4,
    PROXY_POOL_EMPTY = -5,
    PROXY_INVALID_HANDLE = -6,
    PROXY_USE_AFTER_FREE = -7,
} ProxyErrorCode;
```

### Core API

| Function | Description |
| :--- | :--- |
| `proxy_pool_new(urls, count, threshold, cooldown_ms)` | Creates a new pool from a C string array. |
| `proxy_pool_from_text(text, threshold, cooldown_ms)` | Creates a pool from line-delimited text (`#` comments and blanks ignored). |
| `proxy_pool_from_file(file_path, threshold, cooldown_ms)` | Loads and parses proxies from a file on disk. |
| `proxy_pool_free(handle)` | Destroys pool and frees all resources safely. |
| `proxy_pool_acquire_lease(handle)` | Acquires a sticky lease (or `NULL` if pool is empty / direct egress). |
| `proxy_lease_free(lease)` | Releases the lease handle. |
| `proxy_lease_get_url(lease, buf, len, written)` | Copies the raw proxy URL into destination buffer. |
| `proxy_lease_get_index(lease)` | Returns slot index in the pool. |
| `proxy_lease_register_success(lease)` | Marks transaction successful, resetting consecutive errors. |
| `proxy_lease_register_failure(lease)` | Increments consecutive errors, benching proxy if threshold is reached. |
| `proxy_pool_get_stats(handle, slot, out_stats)` | Inspects slot metrics (redacted URL, successes, failures, banned status). |
| `proxy_get_last_error(out_info)` | Fetches thread-local error code and descriptive message. |

---

## Integration Examples

### 1. Native Zig

```zig
const std = @import("std");
const proxy = @import("proxy_transport");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const config =
        \\http://proxy1.internal:8080
        \\socks5://proxy2.internal:1080
    ;

    var pool = try proxy.pool.ProxyPool.fromText(allocator, config, 3, 60_000);
    defer pool.deinit();

    if (pool.acquireLease()) |lease| {
        // Use proxy for multi-step request
        const url = lease.getUrl();
        std.debug.print("Using proxy: {s}\n", .{url});

        // Report outcome
        lease.registerSuccess();
    }
}
```

### 2. Python (`ctypes`)

```python
import ctypes

lib = ctypes.CDLL("./zig-out/lib/libproxy_transport.so")
lib.proxy_pool_from_text.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint64]
lib.proxy_pool_from_text.restype = ctypes.c_void_p

proxies = b"http://user:pass@proxy1:8080\nhttp://proxy2:8080\n"
pool = lib.proxy_pool_from_text(proxies, 3, 60000)

lease = lib.proxy_pool_acquire_lease(pool)
if lease:
    buf = ctypes.create_string_buffer(256)
    written = ctypes.c_size_t(0)
    lib.proxy_lease_get_url(lease, buf, len(buf), ctypes.byref(written))
    url = buf.raw[:written.value].decode("utf-8")
    print(f"Proxy URL: {url}")
    lib.proxy_lease_register_success(lease)
    lib.proxy_lease_free(lease)

lib.proxy_pool_free(pool)
```

### 3. Go (`cgo`)

```go
package main

/*
#cgo CFLAGS: -I../../include
#cgo LDFLAGS: -L../../zig-out/lib -lproxy_transport -Wl,-rpath,../../zig-out/lib
#include "proxy_transport.h"
#include <stdlib.h>
*/
import "C"
import (
	"fmt"
	"unsafe"
)

func main() {
	config := C.CString("http://proxy-node.internal:8080\n")
	defer C.free(unsafe.Pointer(config))

	pool := C.proxy_pool_from_text(config, 3, 60000)
	defer C.proxy_pool_free(pool)

	lease := C.proxy_pool_acquire_lease(pool)
	if lease != nil {
		defer C.proxy_lease_free(lease)
		var buf [256]C.char
		var written C.size_t
		if C.proxy_lease_get_url(lease, &buf[0], C.size_t(len(buf)), &written) == 0 {
			url := C.GoStringN(&buf[0], C.int(written))
			fmt.Printf("Using proxy: %s\n", url)
			C.proxy_lease_register_success(lease)
		}
	}
}
```

---

## Build & Test

### Run Test Suite
```bash
zig build test
```

### Build Dynamic and Static Libraries
```bash
zig build -Doptimize=ReleaseFast
```

Artifacts are produced in `zig-out/`:
- `zig-out/lib/libproxy_transport.so` (or `.dll` / `.dylib`)
- `zig-out/include/proxy_transport.h`

### Run Examples
```bash
# Zig example
zig build example

# Python example
python3 examples/python/main.py

# Go example
LD_LIBRARY_PATH=./zig-out/lib go run examples/go/main.go
```

### Cross-Compilation

```bash
# Windows x86_64
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

# Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast

# macOS Intel
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
```

---

## License

MIT License.
