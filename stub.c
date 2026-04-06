#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include "moonbit.h"

typedef void *webview_t;

/* ── webview_bind trampoline ─────────────────────────────────────────────── */

/*
 * MoonBit passes closures as (trampoline FuncRef, closure data) pairs.
 * webview_bind expects a plain C callback with a single void* user-data arg.
 * This struct bundles both so the trampoline can reconstruct the call.
 */
typedef void (*moonbit_webview_bind_callback_t)(void *seq, void *req, void *arg);

struct moonbit_webview_binding {
  moonbit_webview_bind_callback_t callback;
  void *arg; /* owned MoonBit closure; must moonbit_decref on free */
};

/* Forward declarations from webview.h — only the symbols we need. */
int webview_bind(
  webview_t w,
  const char *name,
  void (*fn)(const char *seq, const char *req, void *arg),
  void *arg
);
int webview_unbind(webview_t w, const char *name);
int webview_return(webview_t w, const char *seq, int status, const char *result);

static void moonbit_webview_free_binding(struct moonbit_webview_binding *binding) {
  if (binding == NULL) return;
  if (binding->arg != NULL) moonbit_decref(binding->arg);
  free(binding);
}

static void moonbit_webview_bind_trampoline(
  const char *seq,
  const char *req,
  void *arg
) {
  struct moonbit_webview_binding *binding = arg;
  /* Pass raw C-string pointers directly — zero copy.
   * The MoonBit closure (webview.mbt::bind) copies them via
   * webview_copy_cstr before the callback returns, so the pointers
   * are valid for the duration of this call. */
  binding->callback((void *)seq, (void *)req, binding->arg);
}

MOONBIT_FFI_EXPORT
void *moonbit_webview_bind(
  webview_t w,
  const char *name,
  moonbit_webview_bind_callback_t fn,
  void *arg  /* #owned: MoonBit transferred ownership to us */
) {
  struct moonbit_webview_binding *binding =
    (struct moonbit_webview_binding *)malloc(sizeof(struct moonbit_webview_binding));
  if (binding == NULL) {
    /* Allocation failed — decref the transferred closure to avoid a leak. */
    if (arg != NULL) moonbit_decref(arg);
    return NULL;
  }
  binding->callback = fn;
  binding->arg = arg;

  if (webview_bind(w, name, moonbit_webview_bind_trampoline, binding) != 0) {
    moonbit_webview_free_binding(binding);
    return NULL;
  }
  return binding;
}

MOONBIT_FFI_EXPORT
void moonbit_webview_unbind(webview_t w, const char *name, void *raw_binding) {
  webview_unbind(w, name);
  moonbit_webview_free_binding((struct moonbit_webview_binding *)raw_binding);
}

/* ── webview_return zero-copy variant ───────────────────────────────────── */

/*
 * Respond to a binding call using the raw seq pointer received in the
 * trampoline callback.  seq is valid for the duration of the callback; we
 * pass it straight to webview_return without copying it into MoonBit's heap.
 * result is a MoonBit Bytes value (null-terminated by the runtime), so it can
 * be cast directly to const char*.
 *
 * This saves 2 moonbit_webview_copy_cstr allocations + 2 UTF-8 decode/encode
 * roundtrips compared to routing seq through the MoonBit string system.
 */
MOONBIT_FFI_EXPORT
void moonbit_webview_return_raw(
  webview_t w,
  const char *seq,   /* #borrow: raw C pointer, not a MoonBit object */
  int32_t status,
  const char *result /* #borrow: MoonBit Bytes, null-terminated by runtime */
) {
  webview_return(w, seq, (int)status, result);
}

/* ── Misc helpers ────────────────────────────────────────────────────────── */

// MOONBIT_FFI_EXPORT
// int64_t moonbit_webview_identity(webview_t w) {
//   return (int64_t)(intptr_t)w;
// }

/*
 * Copy a null-terminated C string into a MoonBit Bytes value.
 *
 * This copy is unavoidable: the seq/req pointers passed by webview are only
 * valid for the duration of the C callback.  Once control returns to webview,
 * the memory may be reused.  We allocate a fresh GC-managed Bytes so that
 * the MoonBit closure can safely decode them after the callback returns.
 *
 * The bytes do NOT include a null terminator — MoonBit Bytes are length-
 * prefixed and the null is added by the runtime when passing back to C.
 */
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_webview_copy_cstr(const char *cstr) {
  if (cstr == NULL) return moonbit_make_bytes_raw(0);
  size_t len = strlen(cstr);
  if (len > INT32_MAX) abort();
  moonbit_bytes_t bytes = moonbit_make_bytes_raw((int32_t)len);
  memcpy(bytes, cstr, len);
  return bytes;
}