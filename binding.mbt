/// FFI declarations for the webview C library.
///
/// All extern functions are package-private. Public-facing wrappers live in
/// webview.mbt, command.mbt and plugin.mbt.
///
/// Ownership rules (moonbit-c-binding skill):
///   #borrow(param) — C only reads the value during the call, does not store it.
///   #owned(param)  — ownership transfers to C; C must moonbit_decref when done.
/// Primitives (Int, Int64, Bool, …) are passed by value — no annotation needed.
///
/// see: https://github.com/webview/webview/blob/master/webview.h

///|
/// Opaque handle returned by webview_create. C manages the underlying object.
#external
pub type WebView_t

///|
/// Opaque binding record returned by moonbit_webview_bind.
/// C allocates and owns it; MoonBit holds it only as a cookie for unbind.
#external
pub type BindingHandle

///|
/// Opaque IPC message snapshot returned by the native queue pop API.
#external
pub type IpcMessageHandle

// ── Lifecycle ────────────────────────────────────────────────────────────────

///|
extern "C" fn webview_create(debug : Int, window : Int64) -> WebView_t = "webview_create"

///|
extern "C" fn webview_destroy(w : WebView_t) -> Unit = "webview_destroy"

///|
extern "C" fn webview_run(w : WebView_t) -> Unit = "webview_run"

///|
/// Wraps webview_terminate and also sets the internal terminated flag so
/// `webview_is_terminated()` returns true.  Use this instead of the bare
/// `webview_terminate` so that the async run-loop can observe termination.
extern "C" fn webview_terminate(w : WebView_t) -> Unit = "moonbit_webview_terminate"

// ── Window ───────────────────────────────────────────────────────────────────

///|
#borrow(title)
extern "C" fn webview_set_title(w : WebView_t, title : Bytes) -> Unit = "webview_set_title"

///|
extern "C" fn webview_set_size(
  w : WebView_t,
  width : Int,
  height : Int,
  hint : SizeHint,
) -> Unit = "webview_set_size"

// ── Navigation ───────────────────────────────────────────────────────────────

///|
#borrow(url)
extern "C" fn webview_navigate(w : WebView_t, url : Bytes) -> Unit = "webview_navigate"

///|
#borrow(html)
extern "C" fn webview_set_html(w : WebView_t, html : Bytes) -> Unit = "webview_set_html"

// ── JavaScript ───────────────────────────────────────────────────────────────

///|
#borrow(js)
extern "C" fn webview_init(w : WebView_t, js : Bytes) -> Unit = "webview_init"

///|
#borrow(js)
extern "C" fn webview_eval(w : WebView_t, js : Bytes) -> Unit = "webview_eval"

// ── Dispatch ─────────────────────────────────────────────────────────────────

///|
/// Schedule `closure` on the webview UI thread.
/// `call_closure` is a closed FuncRef trampoline; `closure` is the MoonBit
/// callback whose ownership transfers to C until it is invoked once.
#owned(closure)
extern "C" fn webview_dispatch(
  w : WebView_t,
  call_closure : FuncRef[(WebView_t, () -> Unit) -> Unit],
  closure : () -> Unit,
) -> Unit = "webview_dispatch"

// ── Bindings ─────────────────────────────────────────────────────────────────

///|
/// Bind a MoonBit closure as a named JavaScript function.
/// `name` is borrowed (used only during the call).
/// `closure` ownership transfers to the returned BindingHandle.
#borrow(name)
#owned(closure)
extern "C" fn webview_bind(
  w : WebView_t,
  name : Bytes,
  call_closure : FuncRef[(Bytes, Bytes, (Bytes, Bytes) -> Unit) -> Unit],
  closure : (Bytes, Bytes) -> Unit,
) -> BindingHandle = "moonbit_webview_bind"

///|
/// Unbind and free the native binding record.
/// `name` is borrowed; the binding handle is consumed (freed) by C.
#borrow(name)
extern "C" fn webview_unbind(
  w : WebView_t,
  name : Bytes,
  binding : BindingHandle,
) -> Unit = "moonbit_webview_unbind"

///|
/// Respond to a binding call using raw borrowed C-string pointers.
/// `seq` is the pointer received in the bind trampoline — it is valid only
/// during the callback invocation and must not be stored.
/// `result` is a MoonBit Bytes value (null-terminated by the runtime).
#borrow(seq, result)
extern "C" fn webview_return_raw(
  w : WebView_t,
  seq : Bytes,
  status : Int,
  result : Bytes,
) -> Unit = "moonbit_webview_return_raw"

///|
/// Returns true when a BindingHandle is null (webview_bind failed).
extern "C" fn webview_binding_is_null(binding : BindingHandle) -> Bool = "moonbit_is_null"

// ── Helpers ──────────────────────────────────────────────────────────────────

///|
/// Copy a raw C string (seq/req pointer) into MoonBit-managed Bytes.
/// This copy is necessary because the C string is only valid for the duration
/// of the webview callback invocation.
#borrow(cstr)
extern "C" fn webview_copy_cstr(cstr : Bytes) -> Bytes = "moonbit_webview_copy_cstr"

///|
/// Run a MoonBit closure on a detached native thread.
#owned(closure)
extern "C" fn run_in_background_thread(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> Int = "moonbit_run_in_background_thread"

///|
/// Initialize native window manager runtime.
pub extern "C" fn wm_init(is_main_process : Int) -> Int = "moonbit_wm_init"

///|
/// Cleanup native window manager runtime.
pub extern "C" fn wm_cleanup() -> Unit = "moonbit_wm_cleanup"

///|
/// Create a managed native window and register it in WM.
#borrow(title, url)
pub extern "C" fn wm_create_window(
  title : Bytes,
  url : Bytes,
  width : Int,
  height : Int,
  x : Int,
  y : Int,
  has_x : Int,
  has_y : Int,
  parent_window_id : Int,
) -> Int = "moonbit_wm_create_window"

///|
/// Destroy managed window.
pub extern "C" fn wm_destroy_window(window_id : Int) -> Int = "moonbit_wm_destroy_window"

///|
/// Run managed window event loop.
pub extern "C" fn wm_run_window(window_id : Int) -> Int = "moonbit_wm_run_window"

///|
/// Start managed window event loop on a detached native thread.
pub extern "C" fn wm_run_window_async(window_id : Int) -> Int = "moonbit_wm_run_window_async"

///|
/// Request window termination.
pub extern "C" fn wm_terminate_window(window_id : Int) -> Int = "moonbit_wm_terminate_window"

///|
/// Set managed window title.
#borrow(title)
pub extern "C" fn wm_set_title(window_id : Int, title : Bytes) -> Int = "moonbit_wm_set_title"

///|
/// Set managed window size.
pub extern "C" fn wm_set_size(window_id : Int, width : Int, height : Int, hints : Int) -> Int = "moonbit_wm_set_size"

///|
/// Navigate managed window to URL.
#borrow(url)
pub extern "C" fn wm_navigate(window_id : Int, url : Bytes) -> Int = "moonbit_wm_navigate"

///|
/// Set managed window HTML.
#borrow(html)
pub extern "C" fn wm_set_html(window_id : Int, html : Bytes) -> Int = "moonbit_wm_set_html"

///|
/// Eval JS in managed window.
#borrow(js)
pub extern "C" fn wm_eval_js(window_id : Int, js : Bytes) -> Int = "moonbit_wm_eval_js"

///|
/// Init JS in managed window.
#borrow(js)
pub extern "C" fn wm_init_js(window_id : Int, js : Bytes) -> Int = "moonbit_wm_init_js"

///|
/// Set managed window visibility.
pub extern "C" fn wm_set_visibility(window_id : Int, visible : Int) -> Int = "moonbit_webview_set_window_visibility"

///|
/// Get managed window visibility.
pub extern "C" fn wm_get_visibility(window_id : Int) -> Int = "moonbit_webview_get_window_visibility"

///|
/// Query managed window count.
pub extern "C" fn wm_get_window_count() -> Int = "moonbit_wm_get_window_count"

///|
/// Query managed window id at index.
pub extern "C" fn wm_get_window_id_at(index : Int) -> Int = "moonbit_wm_get_window_id_at"

///|
/// Query managed window state.
pub extern "C" fn wm_get_window_state(window_id : Int) -> Int = "moonbit_wm_get_window_state"

///|
/// Query parent window id.
pub extern "C" fn wm_get_parent_window_id(window_id : Int) -> Int = "moonbit_wm_get_parent_window_id"

///|
/// Get native handle by managed window id.
pub extern "C" fn wm_get_handle(window_id : Int) -> WebView_t = "moonbit_wm_get_handle"

///|
/// Respond to a JS binding call on the managed window UI thread.
#borrow(seq, result)
pub extern "C" fn wm_return_raw(
  window_id : Int,
  seq : Bytes,
  status : Int,
  result : Bytes,
) -> Int = "moonbit_wm_return_raw"

///|
/// Create child-process window.
#borrow(title, url)
pub extern "C" fn wm_create_child_window(
  title : Bytes,
  url : Bytes,
  width : Int,
  height : Int,
  parent_window_id : Int,
) -> Int = "moonbit_wm_create_child_window"

///|
/// Fork the current process into a child that is already connected to the IPC server.
/// Returns child pid in the parent process, `0` in the child process, and `-1` on error.
pub extern "C" fn wm_fork_process() -> Int = "moonbit_wm_fork_process"

///|
/// Spawn a fresh child process by executing the given program path with one extra argument.
#borrow(program, arg1)
pub extern "C" fn wm_spawn_process(
  program : Bytes,
  arg1 : Bytes,
) -> Int = "moonbit_wm_spawn_process"

///|
/// Connect the current process to the parent's IPC server and switch WM into child mode.
pub extern "C" fn wm_connect_child_process() -> Int = "moonbit_wm_connect_child_process"

///|
/// Get process type: 0 main, 1 child.
pub extern "C" fn wm_get_process_type() -> Int = "moonbit_wm_get_process_type"

///|
/// Get current process id.
pub extern "C" fn wm_get_process_id() -> Int = "moonbit_wm_get_process_id"

///|
/// Kill child process.
pub extern "C" fn wm_kill_child(pid : Int) -> Int = "moonbit_wm_kill_child"

///|
/// Non-blocking child wait. Returns child pid when exited, `0` when still running.
pub extern "C" fn wm_wait_child_noblock(pid : Int) -> Int = "moonbit_wm_wait_child_noblock_no_status"

///|
/// Send asynchronous IPC message.
#borrow(subtype, data)
pub extern "C" fn wm_ipc_send(
  source_window_id : Int,
  target_window_id : Int,
  message_type : Int,
  subtype : Bytes,
  data : Bytes,
) -> Int = "moonbit_wm_ipc_send"

///|
/// Send an IPC request and wait for the raw response bytes.
#borrow(subtype, data)
pub extern "C" fn wm_ipc_request_bytes(
  source_window_id : Int,
  target_window_id : Int,
  subtype : Bytes,
  data : Bytes,
  timeout_ms : Int,
) -> Bytes = "moonbit_wm_ipc_request_bytes"

///|
/// Send an IPC response that matches a previous request id.
#borrow(data)
pub extern "C" fn wm_ipc_respond(
  source_window_id : Int,
  target_window_id : Int,
  request_id : Int,
  data : Bytes,
) -> Int = "moonbit_wm_ipc_respond"

///|
/// Receive an IPC message (non-blocking).
/// Returns the number of bytes in the received message, or 0 if no message.
/// The message is stored in a static buffer; copy it before calling again.
pub extern "C" fn wm_ipc_recv(window_id : Int) -> Int = "moonbit_wm_ipc_recv"

///|
/// Get the last received IPC message data.
/// Returns (message_type, subtype, data) as (Int, Bytes, Bytes).
pub extern "C" fn wm_ipc_get_message(
  window_id : Int,
) -> (Int, Bytes, Bytes) = "moonbit_wm_ipc_get_message"

///|
/// Pop the next queued IPC message snapshot for the given queue id.
pub extern "C" fn wm_ipc_pop_message(window_id : Int) -> IpcMessageHandle = "moonbit_wm_ipc_pop_message"

///|
extern "C" fn ipc_message_is_null(message : IpcMessageHandle) -> Bool = "moonbit_is_null"

///|
extern "C" fn ipc_message_free(message : IpcMessageHandle) -> Unit = "moonbit_wm_ipc_message_free"

///|
extern "C" fn ipc_message_source_window_id(message : IpcMessageHandle) -> Int = "moonbit_wm_ipc_message_source_window_id"

///|
extern "C" fn ipc_message_target_window_id(message : IpcMessageHandle) -> Int = "moonbit_wm_ipc_message_target_window_id"

///|
extern "C" fn ipc_message_type(message : IpcMessageHandle) -> Int = "moonbit_wm_ipc_message_type"

///|
extern "C" fn ipc_message_id(message : IpcMessageHandle) -> Int = "moonbit_wm_ipc_message_id"

///|
extern "C" fn ipc_message_subtype(message : IpcMessageHandle) -> Bytes = "moonbit_wm_ipc_message_subtype"

///|
extern "C" fn ipc_message_data(message : IpcMessageHandle) -> Bytes = "moonbit_wm_ipc_message_data"
