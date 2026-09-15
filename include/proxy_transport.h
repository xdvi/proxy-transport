#ifndef PROXY_TRANSPORT_H
#define PROXY_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(__CYGWIN__)
  #ifdef PROXY_BUILD_DLL
    #define PROXY_API __declspec(dllexport)
  #else
    #define PROXY_API __declspec(dllimport)
  #endif
#else
  #define PROXY_API __attribute__((visibility("default")))
#endif

typedef struct ProxyPoolHandle ProxyPoolHandle;
typedef struct ProxyLeaseHandle ProxyLeaseHandle;

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

typedef struct ProxyErrorInfo {
    int32_t code;
    char message[256];
} ProxyErrorInfo;

typedef struct ProxyStats {
    char url[256];
    uint64_t successes;
    uint64_t failures;
    bool banned;
} ProxyStats;

typedef struct ProxyEndpointInfo {
    int32_t scheme;
    char host[128];
    uint16_t port;
    bool has_auth;
    char username[64];
    char password[64];
    char auth_header[128];
} ProxyEndpointInfo;

PROXY_API ProxyPoolHandle* proxy_pool_new(
    const char* const* urls,
    size_t count,
    uint32_t failure_threshold,
    uint64_t cooldown_ms
);

PROXY_API ProxyPoolHandle* proxy_pool_from_file(
    const char* file_path,
    uint32_t failure_threshold,
    uint64_t cooldown_ms
);

PROXY_API ProxyPoolHandle* proxy_pool_from_text(
    const char* proxy_list_text,
    uint32_t failure_threshold,
    uint64_t cooldown_ms
);

PROXY_API void proxy_pool_free(ProxyPoolHandle* handle);

PROXY_API int32_t proxy_pool_reload_urls(
    ProxyPoolHandle* handle,
    const char* const* urls,
    size_t count
);

PROXY_API int32_t proxy_pool_reload_from_text(
    ProxyPoolHandle* handle,
    const char* proxy_list_text
);


PROXY_API ProxyLeaseHandle* proxy_pool_acquire_lease(const ProxyPoolHandle* handle);

PROXY_API void proxy_lease_free(ProxyLeaseHandle* lease);

PROXY_API int32_t proxy_lease_get_url(
    const ProxyLeaseHandle* lease,
    char* out_buf,
    size_t out_len,
    size_t* out_written
);

PROXY_API int32_t proxy_lease_get_endpoint(
    const ProxyLeaseHandle* lease,
    ProxyEndpointInfo* out_endpoint
);

PROXY_API size_t proxy_lease_get_index(const ProxyLeaseHandle* lease);

PROXY_API void proxy_lease_register_success(ProxyLeaseHandle* lease);

PROXY_API void proxy_lease_register_failure(ProxyLeaseHandle* lease);

PROXY_API size_t proxy_pool_len(const ProxyPoolHandle* handle);

PROXY_API bool proxy_pool_uses_proxy(const ProxyPoolHandle* handle);

PROXY_API bool proxy_pool_is_rotating(const ProxyPoolHandle* handle);

PROXY_API int32_t proxy_pool_get_stats(
    const ProxyPoolHandle* handle,
    size_t slot_index,
    ProxyStats* out_stats
);

PROXY_API uint32_t proxy_pool_get_active_leases(
    const ProxyPoolHandle* handle,
    size_t slot_index
);

PROXY_API uint32_t proxy_pool_get_total_active_leases(
    const ProxyPoolHandle* handle
);


PROXY_API int32_t proxy_format_connect_request(
    const ProxyEndpointInfo* endpoint,
    const char* target_host,
    uint16_t target_port,
    char* out_buf,
    size_t out_len,
    size_t* out_written
);

PROXY_API int32_t proxy_parse_connect_response(
    const char* response,
    size_t response_len
);

PROXY_API int32_t proxy_get_last_error(ProxyErrorInfo* out_info);

PROXY_API void proxy_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PROXY_TRANSPORT_H */
