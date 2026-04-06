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
struct WebView {
  handle : WebView_t
  bindings : Map[String, BindingHandle]
  destroy_hooks : Map[String, () -> Unit]
}

///|
/// Creates a new webview instance.
///
/// Parameters:
/// - `debug` - If set to 1, enables debugging mode.
pub fn WebView::new(debug? : Int = 0) -> WebView {
  WebView::{
    handle: webview_create(debug, 0L),
    bindings: {},
    destroy_hooks: {},
  }
}

///|
/// Destroys the webview and closes the window.
/// Safe to call from a background thread.
pub fn WebView::destroy(self : WebView) -> Unit {
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
  webview_destroy(self.handle)
}

///|
/// Schedules a function to be invoked on the thread with the run/event loop.
///
/// Since library functions generally do not have thread safety guarantees,
/// this function can be used to schedule code to execute on the main/GUI
/// thread and thereby make that execution safe in multi-threaded applications.
pub fn WebView::dispatch(self : WebView, callback : () -> Unit) -> Unit {
  webview_dispatch(self.handle, fn(_, f) { f() }, callback)
}

///|
/// Stops the main event loop.
/// Safe to call from a background thread.
pub fn WebView::terminate(self : WebView) -> Unit {
  webview_terminate(self.handle)
}

///|
/// Binds a MoonBit function as a named global JavaScript function.
///
/// The injected JS glue creates `window[name]` as an async function. When
/// called from JavaScript, `callback` receives the call id and a JSON-encoded
/// argument array. Call `WebView::response` with the id to resolve the promise.
///
/// Returns silently if a binding with the same name already exists.
pub fn WebView::bind(
  self : WebView,
  name : String,
  callback : (String, String) -> Unit,
) -> Unit {
  let binding = webview_bind(
    self.handle,
    @encoding/utf8.encode(name),
    fn(raw_id, raw_req, f) { f(raw_id, raw_req) },
    fn(raw_id, raw_req) {
      let id = webview_copy_cstr(raw_id)
      let req = webview_copy_cstr(raw_req)
      callback(@encoding/utf8.decode(id), @encoding/utf8.decode(req)) catch {
        Malformed(err) => println("Error in binding callback: \{err}")
      }
    },
  )
  if !webview_binding_is_null(binding) {
    self.bindings.set(name, binding)
  }
}

///|
/// Removes a binding created with `WebView::bind`.
pub fn WebView::unbind(self : WebView, name : String) -> Unit {
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
pub fn WebView::set_title(self : WebView, title : String) -> Unit {
  webview_set_title(self.handle, @encoding/utf8.encode(title))
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
pub fn WebView::set_html(self : WebView, html : String) -> Unit {
  webview_set_html(self.handle, @encoding/utf8.encode(html))
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
pub fn WebView::navigate(self : WebView, url : String) -> Unit {
  webview_navigate(self.handle, @encoding/utf8.encode(url))
}

///|
/// Returns the native window handle (`GtkWindow*`, `NSWindow*`, or `HWND`).
pub fn WebView::get_window(self : WebView) -> Int64 {
  webview_get_window(self.handle)
}

///|
/// Returns a native handle of the given kind.
pub fn WebView::get_native_handle(
  self : WebView,
  kind : NativeHandleKind,
) -> Int64 {
  webview_get_native_handle(self.handle, kind)
}

///|
/// Returns the raw `WebView_t` handle.
pub fn WebView::get_handle(self : WebView) -> WebView_t {
  self.handle
}

///|
/// Evaluates arbitrary JavaScript code.
/// Use bindings if you need to receive a result.
pub fn WebView::eval(self : WebView, js : String) -> Unit {
  webview_eval(self.handle, @encoding/utf8.encode(js))
}

///|
/// Injects JavaScript code executed immediately on every page load,
/// before `window.onload`.
pub fn WebView::init(self : WebView, js : String) -> Unit {
  webview_init(self.handle, @encoding/utf8.encode(js))
}

///|
/// Responds to a binding call from JavaScript.
///
/// Parameters:
/// - `id`     - The call identifier received in the binding callback.
/// - `status` - 0 for success; any other value signals an error to JS.
/// - `result` - A JSON value or empty string (resolves to `undefined`).
pub fn WebView::response(
  self : WebView,
  id : String,
  status : Int,
  result : String,
) -> Unit {
  webview_return(
    self.handle,
    @encoding/utf8.encode(id),
    status,
    @encoding/utf8.encode(result),
  )
}

///|
/// Updates the size of the native window.
///
/// Remarks:
/// - `SizeHint::Max` is not supported with GTK 4.
/// - GTK 4 can only set a default size early in the window lifecycle.
pub fn WebView::set_size(
  self : WebView,
  width : Int,
  height : Int,
  hints : SizeHint,
) -> Unit {
  webview_set_size(self.handle, width, height, hints)
}

///|
/// Runs the main event loop until terminated, then destroys the webview.
pub fn WebView::run(self : WebView) -> Unit {
  webview_run(self.handle)
  self.destroy()
}

// ── Internal helpers ─────────────────────────────────────────────────────────

///|
fn WebView::identity(self : WebView) -> Int64 {
  webview_identity(self.handle)
}

///|
fn WebView::register_destroy_hook(
  self : WebView,
  hook_name : String,
  hook : () -> Unit,
) -> Unit {
  guard self.destroy_hooks.get(hook_name) is None else {
    abort("WebView::register_destroy_hook: hook already registered: " + hook_name)
  }
  self.destroy_hooks.set(hook_name, hook)
}

///|
fn WebView::unregister_destroy_hook(self : WebView, hook_name : String) -> Unit {
  self.destroy_hooks.remove(hook_name)
}