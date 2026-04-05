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
/// Creates a new webview instance from a webview handle.
/// 
/// Parameters:
/// - `debug` - If set to 1, enables debugging mode which provides additional logging.
pub fn WebView::new(debug? : Int = 0) -> WebView {
  let window : Int64 = 0
  let webview = WebView::{
    handle: webview_create(debug, window),
    bindings: {},
    destroy_hooks: {},
  }
  webview
}

///|
/// Destroys the webview and closes the window. It is safe to call this
/// function from another background thread.
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
    let _ = webview_unbind(self.handle, @encoding/utf8.encode(name), binding)
  }
  let _ = webview_destroy(self.handle)
}

///|
/// Schedules a function to be invoked on the thread with the run/event loop.
/// 
/// Since library functions generally do not have thread safety guarantees,
/// this function can be used to schedule code to execute on the main/GUI
/// thread and thereby make that execution safe in multi-threaded applications.
/// 
/// Parameters:
/// - `callback` - The function to be invoked.
/// - `arg` - An optional argument passed along to the callback function.
pub fn WebView::dispatch(self : WebView, callback : () -> Unit) -> Unit {
  let _ = webview_dispatch(self.handle, fn(w, f) { f(w) }, callback)
}

///|
/// Stops the main event loop. It is safe to call this function from another
/// background thread.
pub fn WebView::terminate(self : WebView) -> Unit {
  let _ = webview_terminate(self.handle)
}

///|
/// Binds a function pointer to a new global JavaScript function.
/// 
/// Internally, JS glue code is injected to create the JS function by the
/// given name. The callback function is passed a request identifier,
/// a request string and a user-provided argument. The request string is
/// a JSON array of the arguments passed to the JS function.
/// 
/// Parameters:
/// - `name` - The name of the JavaScript function to bind.
/// - `callback` - The function to be invoked when the JS function is called.
/// - `arg` - An optional user-provided argument passed to the callback function.
/// 
/// Returns:
/// - `WEBVIEW_ERROR_DUPLICATE` - A binding already exists with the specified name.
pub fn WebView::bind(
  self : WebView,
  name : String,
  callback : (Bytes, Bytes) -> Unit,
) -> Unit {
  let binding = webview_bind(
    self.handle,
    @encoding/utf8.encode(name),
    fn(raw_id, raw_req, f) {
      let id = webview_copy_cstr(raw_id)
      let req = webview_copy_cstr(raw_req)
      f(id, req)
    },
    callback,
  )
  if !webview_binding_is_null(binding) {
    self.bindings.set(name, binding)
  }
}

///|
/// Removes a binding created with `webview.bind()`.
/// 
/// Parameters:
/// - `name` - The name of the JavaScript function to unbind.
/// 
/// Returns:
/// - `WEBVIEW_ERROR_NOT_FOUND` - No binding exists with the specified name.
pub fn WebView::unbind(self : WebView, name : String) -> Unit {
  match self.bindings.get(name) {
    Some(binding) => {
      self.bindings.remove(name)
      let _ = webview_unbind(self.handle, @encoding/utf8.encode(name), binding)
    }
    None => ()
  }
}

///|
/// Updates the title of the native window.
/// 
/// Parameters:
/// - `title` - The new title.
pub fn WebView::set_title(self : WebView, title : String) -> Unit {
  let _ = webview_set_title(self.handle, @encoding/utf8.encode(title))
}

///|
/// Load HTML content into the webview.
/// 
/// Parameters:
/// - `html` - The HTML content to load.
/// 
/// Example:
/// ```moonbit nocheck
/// let webview = @webview.WebView::new()
/// webview.set_html("<html><body><h1>Hello, World!</h1></body></html>")
/// webview.dispatch(fn() { webview.terminate() })
/// webview.run()
/// ```
pub fn WebView::set_html(self : WebView, html : String) -> Unit {
  let _ = webview_set_html(self.handle, @encoding/utf8.encode(html))
}

///|
/// Navigates webview to the given URL. URL may be a properly encoded data URI.
/// 
/// Parameters:
/// - `url` - The URL to navigate to.
/// 
/// Example:
/// ```moonbit nocheck
/// let webview = @webview.WebView::new()
/// webview.navigate("https://www.example.com")
/// webview.navigate("data:text/html,<h1>Hello, World!</h1>")
/// webview.navigate("data:text/html;base64,PGgxPkhlbGxvPC9oMT4=")
/// webview.dispatch(fn() { webview.terminate() })
/// webview.run()
/// ```
pub fn WebView::navigate(self : WebView, url : String) -> Unit {
  let _ = webview_navigate(self.handle, @encoding/utf8.encode(url))
}

///|
/// Returns the native handle of the window associated with the webview instance.
/// The handle can be a `GtkWindow` pointer (GTK), `NSWindow` pointer (Cocoa)
/// or `HWND` (Win32).
pub fn WebView::get_window(self : WebView) -> Int64 {
  webview_get_window(self.handle)
}

///|
/// Get a native handle of choice.
/// 
/// Parameters:
/// - `kind` - The kind of handle to retrieve.
pub fn WebView::get_native_handle(
  self : WebView,
  kind : NativeHandleKind,
) -> Int64 {
  webview_get_native_handle(self.handle, kind)
}

///|
/// Returns the internal webview handle of the webview instance. This handle is
/// the raw pointer used by the underlying webview library.
pub fn WebView::get_handle(self : WebView) -> WebView_t {
  self.handle
}

///|
/// Evaluates arbitrary JavaScript code.
/// 
/// Use bindings if you need to communicate the result of the evaluation.
/// 
/// Parameters:
/// - `js` - The JavaScript code to evaluate.
pub fn WebView::eval(self : WebView, js : String) -> Unit {
  let _ = webview_eval(self.handle, @encoding/utf8.encode(js))
}

///|
/// Injects JavaScript code to be executed immediately upon loading a page.
/// The code will be executed before `window.onload`.
/// 
/// Parameters:
/// - `js` - The JavaScript code to inject.
pub fn WebView::init(self : WebView, js : String) -> Unit {
  let _ = webview_init(self.handle, @encoding/utf8.encode(js))
}

///|
/// Responds to a binding call from the JS side.
/// 
/// This function is safe to call from another thread.
/// 
/// Parameters:
/// - `id` - The identifier of the binding call. Pass along the value received
///    in the binding handler (see `webview.bind()`).
/// - `status` - A status of zero tells the JS side that the binding call was
///    successful; any other value indicates an error.
/// - `result` - The result of the binding call to be returned to the JS side.
///    This must either be a valid JSON value or an empty string for
///    the primitive JS value `undefined`.
pub fn WebView::response(
  self : WebView,
  id : String,
  status : Int,
  result : String,
) -> Unit {
  let _ = webview_return(
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
/// - Using `WEBVIEW_HINT_MAX` for setting the maximum window size is not
///   supported with GTK 4 because X11-specific functions such as
///   `gtk_window_set_geometry_hints` were removed. This option has no effect
///   when using GTK 4.
/// - GTK 4 can set a default/initial window size if done early enough;
///   otherwise, this function has no effect. GTK 4 (unlike 3) can't resize
///   a window after it has been set up.
/// 
/// Parameters:
/// - `width` - The new width of the window.
/// - `height` - The new height of the window.
/// - `hints` - Hints for the window size.
pub fn WebView::set_size(
  self : WebView,
  width : Int,
  height : Int,
  hints : SizeHint,
) -> Unit {
  let _ = webview_set_size(self.handle, width, height, hints)
}

///|
/// Runs the main loop until it's terminated.
pub fn WebView::run(self : WebView) -> Unit {
  let _ = webview_run(self.handle)
  self.destroy()
}

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
    abort(
      "WebView::register_destroy_hook: hook already registered: " + hook_name,
    )
  }
  self.destroy_hooks.set(hook_name, hook)
}

///|
fn WebView::unregister_destroy_hook(self : WebView, hook_name : String) -> Unit {
  self.destroy_hooks.remove(hook_name)
}
