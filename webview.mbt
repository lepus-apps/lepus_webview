///|
/// Native handle kind. The actual type depends on the backend.
pub(all) enum NativeHandleKind {
  /// Top-level window. `GtkWindow` pointer (GTK), `NSWindow` pointer (Cocoa) or `HWND` (Win32).
  Window = 0
  /// Browser widget. `GtkWidget` pointer (GTK), `NSView` pointer (Cocoa) or `HWND` (Win32).
  Widget = 1
  /// Browser controller. `WebKitWebView` pointer (WebKitGTK), `WKWebView`
  /// pointer (Cocoa/WebKit) or `ICoreWebView2Controller` pointer (Win32/WebView2).
  Browser = 2
} derive(Show)

///|
/// Window size hints
pub(all) enum SizeHint {
  /// Width and height are default size.
  None = 0
  /// Width and height are minimum bounds.
  Min = 1
  /// Width and height are maximum bounds.
  Max = 2
  /// Window size can not be changed by a user.
  Fixed = 3
} derive(Show)

///|
/// An instance of a webview window.
///
/// Example:
///
/// ```moonbit nocheck
/// let webview = @webview.WebView::new(debug=1)
/// webview.set_title("My WebView")
/// webview.set_size(800, 600, @webview.SizeHint::None)
/// webview.set_html("<html><body><h1>Hello, World!</h1></body></html>")
/// webview.dispatch(fn() { webview.terminate() })
/// webview.run()
/// ```
struct WebView[X] {
  handle : WebView_t
  window_id : Int
  bindings : Map[String, BindingHandle]
  destroy_hooks : Map[String, () -> Unit]
  task_group : @async.TaskGroup[X]
  mut default_plugin_host : PluginHost[X]?
}

// ── Internal logging ──────────────────────────────────────────────────────────
//
// log_level controls verbosity of internal [bridge] / [plugin] traces:
//   0  silent  (default)
//   1  info    key lifecycle events (command registered, dispatch invoked,
//              response sent)
//   2  verbose full payloads and handler results
//
// Set automatically by WebView::new(debug=1).  Can also be adjusted at
// runtime via set_log_level().

///|
let webview_log_level : Ref[Int] = { val: 0 }

///|
/// Set the internal log verbosity.
///
/// - `0` — silent (default)
/// - `1` — info: lifecycle events (registered commands, invocations, responses)
/// - `2` — verbose: full request/response payloads
pub fn set_log_level(level : Int) -> Unit {
  webview_log_level.val = level
}

///|
/// Emit a log line if `level` ≤ the current log level.
/// The prefix is always included so grep filtering works without extra tooling.
pub fn log(level : Int, msg : String) -> Unit {
  if level <= webview_log_level.val {
    println(msg)
  }
}

///|
/// Creates a new webview instance.
///
/// Parameters:
/// - `debug` - If set to 1, enables debugging mode and internal logging.
pub fn[X] WebView::new(
  task_group : @async.TaskGroup[X],
  debug? : Int = 0,
) -> WebView[X] {
  if debug > 0 {
    set_log_level(debug)
  }
  WebView::{
    handle: webview_create(debug, 0L),
    window_id: -1,
    bindings: {},
    destroy_hooks: {},
    task_group,
    default_plugin_host: None,
  }
}

///|
/// Creates a managed webview window via native WindowManager (IPC-capable).
///
/// Window lifecycle operations (`run/destroy/terminate/set_title/set_size/`
/// `navigate/set_html/eval/init`) will be routed through `wm_*` APIs.
pub fn[X] WebView::new_managed(
  task_group : @async.TaskGroup[X],
  title? : String = "MoonBit WebView",
  url? : String = "",
  width? : Int = 800,
  height? : Int = 600,
  debug? : Int = 0,
) -> WebView[X] {
  ignore(wm_init(1))
  let window_id = wm_create_window(
    @encoding/utf8.encode(title),
    @encoding/utf8.encode(url),
    width,
    height,
    -1,
    -1,
    0,
    0,
    -1,
  )
  guard window_id > 0 else {
    abort("WebView::new_managed failed: wm_create_window")
  }
  let handle = wm_get_handle(window_id)
  if debug > 0 {
    set_log_level(debug)
  }
  WebView::{
    handle,
    window_id,
    bindings: {},
    destroy_hooks: {},
    task_group,
    default_plugin_host: None,
  }
}

///|
/// Destroys the webview and closes the window.
/// Safe to call from a background thread.
pub fn[X] WebView::destroy(self : WebView[X]) -> Unit {
  let hooks : Array[() -> Unit] = []
  for _, hook in self.destroy_hooks {
    hooks.push(hook)
  }
  self.destroy_hooks.clear()
  for hook in hooks {
    hook()
  }
  for name, binding in self.bindings {
    webview_unbind(self.handle, @encoding/utf8.encode(name), binding)
  }
  if self.window_id > 0 {
    ignore(wm_destroy_window(self.window_id))
  } else {
    webview_destroy(self.handle)
  }
}

///|
/// Schedules a function to be invoked on the thread with the run/event loop.
///
/// Since library functions generally do not have thread safety guarantees,
/// this function can be used to schedule code to execute on the main/GUI
/// thread and thereby make that execution safe in multi-threaded applications.
pub fn[X] WebView::dispatch(self : WebView[X], callback : () -> Unit) -> Unit {
  webview_dispatch(self.handle, fn(_, f) { f() }, callback)
}

///|
/// Stops the main event loop.
/// Safe to call from a background thread.
pub fn[X] WebView::terminate(self : WebView[X]) -> Unit {
  if self.window_id > 0 {
    ignore(wm_terminate_window(self.window_id))
  } else {
    webview_terminate(self.handle) // moonbit_webview_terminate — also sets terminated flag
  }
}

///|
/// Binds a MoonBit function as a named global JavaScript function.
///
/// The injected JS glue creates `window[name]` as an async function. When
/// called from JavaScript, `callback` receives the call id and a JSON-encoded
/// argument array. Call `WebView::response` with the id to resolve the promise.
///
/// Returns silently if a binding with the same name already exists.
pub fn[X] WebView::bind(
  self : WebView[X],
  name : String,
  callback : (String, String) -> Unit,
) -> Unit {
  self.bind_raw(name, fn(raw_id, raw_req) {
    let req = webview_copy_cstr(raw_req)
    let id = webview_copy_cstr(raw_id)
    callback(@encoding/utf8.decode(id), @encoding/utf8.decode(req)) catch {
      Malformed(err) => println("Error in binding callback: \{err}")
    }
  })
}

///|
/// Low-level bind variant that hands raw borrowed Bytes directly to the
/// callback.
///
/// `raw_id` and `raw_req` are valid only for the duration of the callback.
/// Use `WebView::respond_raw` to reply without copying the id into a String.
fn[X] WebView::bind_raw(
  self : WebView[X],
  name : String,
  callback : (Bytes, Bytes) -> Unit,
) -> Unit {
  let binding = webview_bind(
    self.handle,
    @encoding/utf8.encode(name),
    fn(raw_id, raw_req, f) { f(raw_id, raw_req) },
    callback,
  )
  if !webview_binding_is_null(binding) {
    self.bindings.set(name, binding)
  }
}

///|
/// Removes a binding created with `WebView::bind`.
pub fn[X] WebView::unbind(self : WebView[X], name : String) -> Unit {
  match self.bindings.get(name) {
    Some(binding) => {
      self.bindings.remove(name)
      webview_unbind(self.handle, @encoding/utf8.encode(name), binding)
    }
    None => ()
  }
}

///|
/// Updates the title of the native window.
pub fn[X] WebView::set_title(self : WebView[X], title : String) -> Unit {
  if self.window_id > 0 {
    ignore(wm_set_title(self.window_id, @encoding/utf8.encode(title)))
  } else {
    webview_set_title(self.handle, @encoding/utf8.encode(title))
  }
}

///|
/// Loads HTML content into the webview.
///
/// Example:
/// ```moonbit nocheck
/// let webview = @webview.WebView::new()
/// webview.set_html("<html><body><h1>Hello, World!</h1></body></html>")
/// webview.dispatch(fn() { webview.terminate() })
/// webview.run()
/// ```
pub fn[X] WebView::set_html(self : WebView[X], html : String) -> Unit {
  if self.window_id > 0 {
    ignore(wm_set_html(self.window_id, @encoding/utf8.encode(html)))
  } else {
    webview_set_html(self.handle, @encoding/utf8.encode(html))
  }
}

///|
/// Navigates the webview to the given URL. URL may be a data URI.
///
/// Example:
/// ```moonbit nocheck
/// let webview = @webview.WebView::new()
/// webview.navigate("https://www.example.com")
/// webview.navigate("data:text/html,<h1>Hello</h1>")
/// webview.dispatch(fn() { webview.terminate() })
/// webview.run()
/// ```
pub fn[X] WebView::navigate(self : WebView[X], url : String) -> Unit {
  if self.window_id > 0 {
    ignore(wm_navigate(self.window_id, @encoding/utf8.encode(url)))
  } else {
    webview_navigate(self.handle, @encoding/utf8.encode(url))
  }
}

///|
/// Returns the native window handle (`GtkWindow*`, `NSWindow*`, or `HWND`).
pub fn[X] WebView::get_window(self : WebView[X]) -> Int64 {
  webview_get_window(self.handle)
}

///|
/// Returns a native handle of the given kind.
pub fn[X] WebView::get_native_handle(
  self : WebView[X],
  kind : NativeHandleKind,
) -> Int64 {
  webview_get_native_handle(self.handle, kind)
}

///|
/// Returns the raw `WebView_t` handle.
pub fn[X] WebView::get_handle(self : WebView[X]) -> WebView_t {
  self.handle
}

///|
/// Evaluates arbitrary JavaScript code.
/// Use bindings if you need to receive a result.
pub fn[X] WebView::eval(self : WebView[X], js : String) -> Unit {
  if self.window_id > 0 {
    ignore(wm_eval_js(self.window_id, @encoding/utf8.encode(js)))
  } else {
    webview_eval(self.handle, @encoding/utf8.encode(js))
  }
}

///|
/// Injects JavaScript code executed immediately on every page load,
/// before `window.onload`.
pub fn[X] WebView::init(self : WebView[X], js : String) -> Unit {
  if self.window_id > 0 {
    ignore(wm_init_js(self.window_id, @encoding/utf8.encode(js)))
  } else {
    webview_init(self.handle, @encoding/utf8.encode(js))
  }
}

///|
/// Responds to a binding call from JavaScript.
///
/// Prefer `respond_raw` in hot paths (e.g. CommandBridge) to avoid
/// encoding the id back to Bytes when it was already a C string.
///
/// Parameters:
/// - `id`     - The call identifier received in the binding callback.
/// - `status` - 0 for success; any other value signals an error to JS.
/// - `result` - A JSON value or empty string (resolves to `undefined`).
pub fn[X] WebView::response(
  self : WebView[X],
  id : String,
  status : Int,
  result : String,
) -> Unit {
  webview_return_raw(
    self.handle,
    @encoding/utf8.encode(id),
    status,
    @encoding/utf8.encode(result),
  )
}

///|
/// Zero-copy response variant.
///
/// `raw_id` is the borrowed Bytes pointer received in a `bind_raw` callback;
/// it must not be stored beyond the callback. `result` is a UTF-8 encoded
/// wire frame (`[0,<json>]` or `[1,"<msg>"]`) produced by
/// `CommandResponse::to_wire`; it is passed directly to C without copying.
///
/// `status` must match the wire frame: 0 for success, 1 for error.
/// JS only inspects `result` — `status` tells the webview engine whether to
/// resolve or reject the Promise before `result` is even parsed.
fn[X] WebView::respond_raw(
  self : WebView[X],
  raw_id : Bytes,
  status : Int,
  result : Bytes,
) -> Unit {
  webview_return_raw(self.handle, raw_id, status, result)
}

///|
/// Updates the size of the native window.
///
/// Remarks:
/// - `SizeHint::Max` is not supported with GTK 4.
/// - GTK 4 can only set a default size early in the window lifecycle.
pub fn[X] WebView::set_size(
  self : WebView[X],
  width : Int,
  height : Int,
  hints : SizeHint,
) -> Unit {
  if self.window_id > 0 {
    ignore(wm_set_size(self.window_id, width, height, 0))
  } else {
    webview_set_size(self.handle, width, height, hints)
  }
}

///|
/// Runs the main event loop until terminated, then destroys the webview.
///
/// In a plain `fn main` context, use this synchronous overload.
/// In an `async fn main` context, prefer `run_async` which integrates with
/// `moonbitlang/async` and automatically drives any registered async handlers.
pub fn[X] WebView::run(self : WebView[X]) -> Unit {
  self.task_group.spawn_bg(() => {
    if self.window_id > 0 {
      ignore(wm_run_window(self.window_id))
    } else {
      webview_run(self.handle)
    }
    self.destroy()
  })
}

// ── Internal helpers ─────────────────────────────────────────────────────────

///|
fn[X] WebView::register_destroy_hook(
  self : WebView[X],
  hook_name : String,
  hook : () -> Unit,
) -> Unit {
  guard self.destroy_hooks.get(hook_name) is None else {
    abort(
      "WebView::register_destroy_hook: hook already registered: " + hook_name,
    )
  }
  self.destroy_hooks.set(hook_name, hook)
}

///|
fn[X] WebView::unregister_destroy_hook(
  self : WebView[X],
  hook_name : String,
) -> Unit {
  self.destroy_hooks.remove(hook_name)
}
