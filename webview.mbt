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
}

///|
/// An instance of a webview window (managed via IPC).
///
/// Example:
///
/// ```moonbit nocheck
/// let webview = @webview.WebView::new_managed(task_group)
/// webview.set_title("My WebView")
/// webview.set_size(800, 600, @webview.SizeHint::None)
/// webview.set_html("<html><body><h1>Hello, World!</h1></body></html>")
/// webview.terminate()
/// ```
struct WebView[X] {
  handle : WebView_t
  window_id : Int
  task_group : @async.TaskGroup[X]
}

// ── Internal logging ──────────────────────────────────────────────────────────
//
// log_level controls verbosity of internal [bridge] / [plugin] traces:
//   0  silent  (default)
//   1  info    key lifecycle events (command registered, dispatch invoked,
//              response sent)
//   2  verbose full payloads and handler results
//
// Set automatically by WebView::new_managed(debug=1).  Can also be adjusted at
// runtime via set_log_level().

///|
let webview_log_level : Ref[Int] = { val: 0 }

///|
/// Set the internal log verbosity.
///
/// - `0` — silent (default)
/// - `1` — info: lifecycle events (registered commands, invocations, responses)
/// - `2` — verbose: full request/response payloads
fn set_log_level(level : Int) -> Unit {
  webview_log_level.val = level
}

///|
/// Emit a log line if `level` ≤ the current log level.
/// The prefix is always included so grep filtering works without extra tooling.
fn log(level : Int, msg : String) -> Unit {
  if level <= webview_log_level.val {
    println(msg)
  }
}

///|
/// Creates a managed webview window via native WindowManager (IPC-capable).
///
/// Window lifecycle operations (`terminate/set_title/set_size/`
/// `navigate/set_html/eval/init`) will be routed through `wm_*` APIs.
fn[X] WebView::new_managed(
  task_group : @async.TaskGroup[X],
  title? : String = "MoonBit WebView",
  url? : String = "",
  width? : Int = 800,
  height? : Int = 600,
  debug? : Int = 0,
) -> WebView[X] {
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
  WebView::{ handle, window_id, task_group }
}

///|
/// Destroys the webview and closes the window.
/// Safe to call from a background thread.
pub fn[X] WebView::destroy(self : WebView[X]) -> Unit {
  ignore(wm_destroy_window(self.window_id))
}

///|
/// Stops the main event loop.
/// Safe to call from a background thread.
pub fn[X] WebView::terminate(self : WebView[X]) -> Unit {
  ignore(wm_terminate_window(self.window_id))
}

///|
/// Updates the title of the native window.
pub fn[X] WebView::set_title(self : WebView[X], title : String) -> Unit {
  ignore(wm_set_title(self.window_id, @encoding/utf8.encode(title)))
}

///|
/// Loads HTML content into the webview.
///
/// Example:
/// ```moonbit nocheck
/// let webview = @webview.WebView::new_managed(task_group)
/// webview.set_html("<html><body><h1>Hello, World!</h1></body></html>")
/// webview.terminate()
/// ```
pub fn[X] WebView::set_html(self : WebView[X], html : String) -> Unit {
  ignore(wm_set_html(self.window_id, @encoding/utf8.encode(html)))
}

///|
/// Navigates the webview to the given URL. URL may be a data URI.
///
/// Example:
/// ```moonbit nocheck
/// let webview = @webview.WebView::new_managed(task_group)
/// webview.navigate("https://www.example.com")
/// webview.navigate("data:text/html,<h1>Hello</h1>")
/// webview.terminate()
/// ```
pub fn[X] WebView::navigate(self : WebView[X], url : String) -> Unit {
  ignore(wm_navigate(self.window_id, @encoding/utf8.encode(url)))
}

///|
/// Navigates one step back in browser history.
pub fn[X] WebView::back(self : WebView[X]) -> Unit {
  self.eval("history.back();")
}

///|
/// Navigates one step forward in browser history.
pub fn[X] WebView::forward(self : WebView[X]) -> Unit {
  self.eval("history.forward();")
}

///|
/// Navigates to a specific entry in browser history.
///
/// - `delta < 0`: backward
/// - `delta > 0`: forward
/// - `delta = 0`: reload current entry
pub fn[X] WebView::go(self : WebView[X], delta : Int) -> Unit {
  self.eval("history.go(\{delta});")
}

///|
/// Reloads the current page using standard browser cache policy.
pub fn[X] WebView::reload(self : WebView[X]) -> Unit {
  self.eval("window.location.reload();")
}

///|
/// Reloads the current page and requests a revalidation from server.
pub fn[X] WebView::reload_force(self : WebView[X]) -> Unit {
  self.eval("window.location.reload(true);")
}

///|
/// Returns the raw `WebView_t` handle.
pub fn[X] WebView::get_handle(self : WebView[X]) -> WebView_t {
  self.handle
}

///|
/// Returns the managed window id.
fn[X] WebView::window_id(self : WebView[X]) -> Int {
  self.window_id
}

///|
/// Evaluates arbitrary JavaScript code.
fn[X] WebView::eval(self : WebView[X], js : String) -> Unit {
  ignore(wm_eval_js(self.window_id, @encoding/utf8.encode(js)))
}

///|
/// Injects JavaScript code executed immediately on every page load,
/// before `window.onload`.
fn[X] WebView::init(self : WebView[X], js : String) -> Unit {
  ignore(wm_init_js(self.window_id, @encoding/utf8.encode(js)))
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
  ignore(wm_set_size(self.window_id, width, height, hints))
}

///|
/// Runs the main event loop until terminated, then destroys the webview.
fn[X] WebView::run(self : WebView[X]) -> Unit {
  ignore(wm_run_window(self.window_id))
  self.destroy()
}
