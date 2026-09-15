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
	config := C.CString("# Proxies\nhttp://go-proxy-1.internal:8080\nhttp://go-proxy-2.internal:8080\n")
	defer C.free(unsafe.Pointer(config))

	pool := C.proxy_pool_from_text(config, 3, 60000)
	if pool == nil {
		fmt.Println("Failed to create proxy pool")
		return
	}
	defer C.proxy_pool_free(pool)

	fmt.Printf("Go: Initialized proxy pool with %d proxies\n", C.proxy_pool_len(pool))

	lease := C.proxy_pool_acquire_lease(pool)
	if lease != nil {
		defer C.proxy_lease_free(lease)
		var buf [256]C.char
		var written C.size_t
		rc := C.proxy_lease_get_url(lease, &buf[0], C.size_t(len(buf)), &written)
		if rc == 0 {
			url := C.GoStringN(&buf[0], C.int(written))
			fmt.Printf("Go: Acquired lease for URL: %s\n", url)
			C.proxy_lease_register_success(lease)
		}
	}
}
