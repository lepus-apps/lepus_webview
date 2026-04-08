///|
/// Window state mapped from native window manager.
pub(all) enum WindowState {
  Unknown = 0
  Created = 1
  Running = 2
  Hidden = 3
  Closing = 4
  Closed = 5
} derive(Eq)

///|
pub fn WindowState::int(self : WindowState) -> Int = "%identity"

///|
test {
  inspect(WindowState::Created.int(), content="1")
}

///|
/// Process type returned by native window manager.
pub(all) enum ProcessType {
  Main = 0
  Child = 1
  Unknown = 2
} derive(Eq)

///|
/// IPC message kind.
pub(all) enum IpcMessageType {
  Data = 0
  Command = 1
  Event = 2
  Request = 3
  Response = 4
} derive(Eq)

///|
pub fn IpcMessageType::int(self : IpcMessageType) -> Int = "%identity"

///|
/// Thin high-level wrapper over native window manager (stub.c wm_* APIs).
pub struct WindowManager {
  process_type : ProcessType
  mut window_ids : Array[Int]
}

///|
/// Snapshot of one IPC message copied out of the native queue.
pub struct IpcMessage {
  source_window_id : Int
  target_window_id : Int
  message_type : IpcMessageType
  message_id : Int
  subtype : String
  data : String
}

///|
/// Initialize WM runtime for current process.
///
/// - main process: pass `true`
/// - child process: pass `false`
pub fn WindowManager::init(is_main? : Bool = true) -> WindowManager {
  let ok = wm_init(if is_main { 1 } else { 0 })
  guard ok == 0 else { abort("WindowManager::init failed") }
  let process_type = match wm_get_process_type() {
    0 => ProcessType::Main
    1 => ProcessType::Child
    _ => ProcessType::Unknown
  }
  WindowManager::{ process_type, window_ids: [] }
}

///|
/// Cleanup native WM runtime.
pub fn WindowManager::destroy(self : WindowManager) -> Unit {
  wm_cleanup()
  self.window_ids = []
}

///|
/// Create a native window in current process.
pub fn WindowManager::create_window(
  self : WindowManager,
  title : String,
  url : String,
  width? : Int = 800,
  height? : Int = 600,
) -> Int {
  let id = wm_create_window(
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
  guard id > 0 else { abort("WindowManager::create_window failed") }
  self.window_ids.push(id)
  id
}

///|
/// Spawn a child process window. Returns child process pid.
pub fn WindowManager::create_child_window(
  _self : WindowManager,
  title : String,
  url : String,
  width? : Int = 800,
  height? : Int = 600,
  parent_id? : Int = -1,
) -> Int {
  wm_create_child_window(
    @encoding/utf8.encode(title),
    @encoding/utf8.encode(url),
    width,
    height,
    parent_id,
  )
}

///|
/// Fork the current process. The parent receives the child pid, the child receives `0`.
pub fn WindowManager::fork_process(_self : WindowManager) -> Int {
  wm_fork_process()
}

///|
/// Spawn a fresh child process by exec-ing the given program path with one extra argument.
pub fn WindowManager::spawn_process(
  _self : WindowManager,
  program : String,
  arg1 : String,
) -> Int {
  wm_spawn_process(@encoding/utf8.encode(program), @encoding/utf8.encode(arg1))
}

///|
/// Connect current process to the main-process IPC server and switch into child mode.
pub fn WindowManager::connect_child_process() -> Int {
  wm_connect_child_process()
}

///|
/// Return true when running in main process.
pub fn WindowManager::is_main_process(self : WindowManager) -> Bool {
  self.process_type == ProcessType::Main
}

///|
/// Return true when running in child process.
pub fn WindowManager::is_child_process(self : WindowManager) -> Bool {
  self.process_type == ProcessType::Child
}

///|
/// Run a window event loop.
pub fn WindowManager::run_window(_self : WindowManager, window_id : Int) -> Int {
  wm_run_window(window_id)
}

///|
/// Destroy a window.
pub fn WindowManager::destroy_window(
  _self : WindowManager,
  window_id : Int,
) -> Int {
  wm_destroy_window(window_id)
}

///|
/// Send an IPC message.
pub fn WindowManager::send_message(
  _self : WindowManager,
  source_window_id : Int,
  target_window_id : Int,
  message_type : IpcMessageType,
  subtype : String,
  data : String,
) -> Int {
  wm_ipc_send(
    source_window_id,
    target_window_id,
    message_type.int(),
    @encoding/utf8.encode(subtype),
    @encoding/utf8.encode(data),
  )
}

///|
/// Broadcast an event message.
pub fn WindowManager::broadcast(
  self : WindowManager,
  source_window_id : Int,
  subtype : String,
  data : String,
) -> Int {
  self.send_message(source_window_id, 0, IpcMessageType::Event, subtype, data)
}

///|
/// Send an IPC request and wait for the response body.
pub fn WindowManager::request(
  _self : WindowManager,
  source_window_id : Int,
  target_window_id : Int,
  subtype : String,
  data : String,
  timeout_ms? : Int = 0,
) -> String {
  @encoding/utf8.decode(
    wm_ipc_request_bytes(
      source_window_id,
      target_window_id,
      @encoding/utf8.encode(subtype),
      @encoding/utf8.encode(data),
      timeout_ms,
    ),
  ) catch {
    _ => ""
  }
}

///|
/// Send an IPC response for a previously received request.
pub fn WindowManager::respond(
  _self : WindowManager,
  source_window_id : Int,
  target_window_id : Int,
  request_id : Int,
  data : String,
) -> Int {
  wm_ipc_respond(
    source_window_id,
    target_window_id,
    request_id,
    @encoding/utf8.encode(data),
  )
}

///|
/// Try to pop one queued IPC message for the given queue id.
pub fn WindowManager::try_pop_message(
  _self : WindowManager,
  queue_id : Int,
) -> IpcMessage? {
  let handle = wm_ipc_pop_message(queue_id)
  let source_window_id = ipc_message_source_window_id(handle)
  let target_window_id = ipc_message_target_window_id(handle)
  let message_id = ipc_message_id(handle)
  let message_type = match ipc_message_type(handle) {
    0 => IpcMessageType::Data
    1 => IpcMessageType::Command
    2 => IpcMessageType::Event
    3 => IpcMessageType::Request
    4 => IpcMessageType::Response
    _ => IpcMessageType::Data
  }
  let subtype = @encoding/utf8.decode(ipc_message_subtype(handle)) catch {
    _ => ""
  }
  let data = @encoding/utf8.decode(ipc_message_data(handle)) catch { _ => "" }
  ipc_message_free(handle)
  Some(IpcMessage::{
    source_window_id,
    target_window_id,
    message_type,
    message_id,
    subtype,
    data,
  })
}

///|
/// Non-blocking child process status check.
pub fn WindowManager::wait_child_noblock(
  _self : WindowManager,
  pid : Int,
) -> Int {
  wm_wait_child_noblock(pid)
}
