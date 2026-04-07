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
pub fn WindowState::int(self : WindowState) -> Int {
  match self {
    Unknown => 0
    Created => 1
    Running => 2
    Hidden => 3
    Closing => 4
    Closed => 5
  }
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
pub fn IpcMessageType::int(self : IpcMessageType) -> Int {
  match self {
    Data => 0
    Command => 1
    Event => 2
    Request => 3
    Response => 4
  }
}

///|
/// Thin high-level wrapper over native window manager (stub.c wm_* APIs).
pub struct WindowManager {
  process_type : ProcessType
  mut window_ids : Array[Int]
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
