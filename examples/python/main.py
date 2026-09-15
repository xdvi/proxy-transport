import ctypes
import os
import sys

lib_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../zig-out/lib/libproxy_transport.so"))
if not os.path.exists(lib_path):
    print(f"Library not found at {lib_path}")
    sys.exit(1)

lib = ctypes.CDLL(lib_path)

lib.proxy_pool_from_text.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint64]
lib.proxy_pool_from_text.restype = ctypes.c_void_p

lib.proxy_pool_free.argtypes = [ctypes.c_void_p]
lib.proxy_pool_free.restype = None

lib.proxy_pool_acquire_lease.argtypes = [ctypes.c_void_p]
lib.proxy_pool_acquire_lease.restype = ctypes.c_void_p

lib.proxy_lease_free.argtypes = [ctypes.c_void_p]
lib.proxy_lease_free.restype = None

lib.proxy_lease_get_url.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
lib.proxy_lease_get_url.restype = ctypes.c_int32

lib.proxy_lease_register_success.argtypes = [ctypes.c_void_p]
lib.proxy_lease_register_success.restype = None

lib.proxy_pool_len.argtypes = [ctypes.c_void_p]
lib.proxy_pool_len.restype = ctypes.c_size_t

proxies = b"""
# Sample proxies
http://user1:pass1@proxy-node-1.internal:8080
http://proxy-node-2.internal:8080
"""

pool = lib.proxy_pool_from_text(proxies, 3, 60000)
print(f"Loaded pool with {lib.proxy_pool_len(pool)} proxies")

lease = lib.proxy_pool_acquire_lease(pool)
if lease:
    buf = ctypes.create_string_buffer(256)
    written = ctypes.c_size_t(0)
    res = lib.proxy_lease_get_url(lease, buf, len(buf), ctypes.byref(written))
    if res == 0:
        url = buf.raw[:written.value].decode("utf-8")
        print(f"Acquired lease for URL: {url}")
        lib.proxy_lease_register_success(lease)
    lib.proxy_lease_free(lease)

lib.proxy_pool_free(pool)
print("Proxy pool freed cleanly.")
