// ── Wire protocol ────────────────────────────────────────────────────────────
//
// Command bridge using webview_bind for JS→MoonBit calls (non-blocking).
//
// JS → MoonBit:
//   window.__moonbit_command(name, payload) → webview_bind callback → async task
//
// MoonBit → JS:
//   webview.eval(__dispatch([name, payload])) → CustomEvent listener
//
// The bind callback spawns async tasks immediately, so webview_run never blocks.

///|
/// Structured response returned from JS → MoonBit commands.
pub(all) enum CommandResponse {
  Ok(Json)
  Error(String)
} derive(Eq)

///|
pub fn[Payload : ToJson] CommandResponse::ok(
  payload : Payload,
) -> CommandResponse {
  Ok(ToJson::to_json(payload))
}

///|
pub fn CommandResponse::error(message : String) -> CommandResponse {
  Error(message)
}

///|
pub fn CommandResponse::is_ok(self : CommandResponse) -> Bool {
  self is Ok(_)
}

///|
fn CommandResponse::to_wire(self : CommandResponse) -> Bytes {
  match self {
    Ok(payload) => @encoding/utf8.encode(ToJson::to_json(payload).stringify())
    Error(msg) => @encoding/utf8.encode("\{msg}")
  }
}

// ── CommandBridge ─────────────────────────────────────────────────────────────

///|
/// High-level command bridge using webview_bind.
///
/// JS API:
/// - `window[global_name].send(name, payload)` → calls MoonBit command
/// - `window[global_name].onCommand(listener)` receives MoonBit → JS push events
struct CommandBridge[X] {
  webview : WebView[X]
  global_name : String
  event_name : String
  binding_name : String
  handlers : Map[String, (Json, String, CommandBridge[X]) -> Unit]
}

///|
/// Creates and starts a command bridge for the given webview.
pub fn[X] CommandBridge::new(
  webview : WebView[X],
  global_name? : String = "MoonBitBridge",
  event_name? : String = "moonbit:command",
  binding_name? : String = "__moonbit_command",
) -> CommandBridge[X] {
  let bridge = CommandBridge::{
    webview,
    global_name,
    event_name,
    binding_name,
    handlers: {},
  }
  bridge.webview.init(make_bridge_script(global_name, binding_name, event_name))
  bridge.start_dispatch()
  bridge
}

///|
pub fn[X] CommandBridge::global_name(self : CommandBridge[X]) -> String {
  self.global_name
}

///|
pub fn[X] CommandBridge::event_name(self : CommandBridge[X]) -> String {
  self.event_name
}

///|
pub fn[X] CommandBridge::destroy(self : CommandBridge[X]) -> Unit {
  self.handlers.clear()
}

// ── Dispatch via webview_bind ───────────────────────────────────────────────

///|
fn[X] CommandBridge::start_dispatch(self : CommandBridge[X]) -> Unit {
  let binding = webview_bind(
    self.webview.handle,
    @encoding/utf8.encode(self.binding_name),
    fn(raw_id, raw_req, f) { f(raw_id, raw_req) },
    fn(raw_id, raw_req) {
      let id = webview_copy_cstr(raw_id)
      let req = webview_copy_cstr(raw_req)
      let id_str = @encoding/utf8.decode(id) catch {
        Malformed(_) => ""
      }
      let req_str = @encoding/utf8.decode(req) catch {
        Malformed(_) => ""
      }
      log(1, "[bridge:recv] id=\{id_str} req=\{req_str}")
      self.dispatch(id_str, req_str)
    },
  )
  ignore(binding)
}

///|
fn[X] CommandBridge::dispatch(
  self : CommandBridge[X],
  id : String,
  req : String,
) -> Unit {
  let parsed = json_parse(req)
  match parsed {
    [String(name), payload] => {
      log(1, "[bridge:dispatch] name=\{name}")
      match self.handlers.get(name) {
        Some(h) => {
          h(payload, id, self)
        }
        None => {
          let resp = CommandResponse::error("Unknown command: " + name)
          self.send_response(id, resp)
        }
      }
    }
    _ => {
      let resp = CommandResponse::error("Bad request format")
      self.send_response(id, resp)
    }
  }
}

///|
fn json_parse(data : String) -> Json {
  let v = @json.parse(data) catch {
    _ => Json::null()
  }
  v
}

///|
fn[X] CommandBridge::send_response(
  self : CommandBridge[X],
  id : String,
  resp : CommandResponse,
) -> Unit {
  log(1, "[bridge:send] id=\{id}")
  let wire = resp.to_wire()
  let status = match resp {
    Ok(_) => 0
    Error(_) => 1
  }
  ignore(
    wm_return_raw(
      self.webview.window_id,
      @encoding/utf8.encode(id),
      status,
      wire,
    ),
  )
}

// ── Handler registration ──────────────────────────────────────────────────────

///|
/// Registers an async typed command handler.
///
/// The callback is an async function. It will be spawned as a background task
/// so it doesn't block the webview event loop.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_async(
  self : CommandBridge[X],
  name : String,
  callback : async (Payload) -> Reply,
) -> Unit {
  self.handlers.set(name, fn(json, id, bridge) {
    let payload = @json.from_json(json) catch {
      msg => {
        bridge.send_response(id, CommandResponse::error("\{msg}"))
        return
      }
    }
    self.webview.task_group.spawn_bg(
      () => {
        let reply = callback(payload)
        bridge.send_response(id, CommandResponse::ok(reply))
      },
    )
  })
}

///|
/// Registers a typed command handler (synchronous).
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle(
  self : CommandBridge[X],
  name : String,
  callback : (Payload) -> Reply,
) -> Unit {
  self.handlers.set(name, fn(json, id, bridge) {
    let payload = @json.from_json(json) catch {
      msg => {
        bridge.send_response(id, CommandResponse::error("\{msg}"))
        return
      }
    }
    let reply = callback(payload)
    bridge.send_response(id, CommandResponse::ok(reply))
  })
}

///|
/// Registers a typed command handler that can raise errors.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_result(
  self : CommandBridge[X],
  name : String,
  callback : (Payload) -> Reply raise,
) -> Unit {
  self.handlers.set(name, fn(json, id, bridge) {
    let payload = @json.from_json(json) catch {
      msg => {
        bridge.send_response(id, CommandResponse::error("\{msg}"))
        return
      }
    }
    let reply = try? callback(payload)
    bridge.send_response(id, CommandResponse::ok(reply))
  })
}

///|
/// Registers an async typed command handler that can raise errors.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_result_async(
  self : CommandBridge[X],
  name : String,
  callback : async (Payload) -> Reply raise Error,
) -> Unit {
  self.handlers.set(name, fn(json, id, bridge) {
    let payload = @json.from_json(json) catch {
      msg => {
        bridge.send_response(id, CommandResponse::error("\{msg}"))
        return
      }
    }
    self.webview.task_group.spawn_bg(
      () => {
        let reply = try? callback(payload)
        bridge.send_response(id, CommandResponse::ok(reply))
      },
    )
  })
}

///|
/// Pushes a fire-and-forget event to JavaScript.
pub fn[X, Payload : ToJson] CommandBridge::send(
  self : CommandBridge[X],
  name : String,
  payload : Payload,
) -> Unit {
  let script = make_push_script(
    self.global_name,
    self.event_name,
    Json::string(name).stringify(),
    ToJson::to_json(payload).stringify(),
  )
  self.webview.eval(script)
}

// ── JS scripts ────────────────────────────────────────────────────────────────

///|
fn make_bridge_script(
  global_name : String,
  binding_name : String,
  event_name : String,
) -> String {
  let g = Json::string(global_name).stringify()
  let b = Json::string(binding_name).stringify()
  let e = Json::string(event_name).stringify()
  (
    //Readable form:
    // window[G] = {
    //   send: (n, p) => window[B](n, p),
    //   onCommand: listener => { ... event listener ... },
    //   __dispatch: d => window.dispatchEvent(new CustomEvent(E, {detail:d})),
    // }
    $|!function(){const G=\{g},B=\{b},E=\{e};window[G]={send:(n,p)=>window[B](n,p??null),onCommand:l=>{const h=e=>l(e.detail);window.addEventListener(E,h);return()=>window.removeEventListener(E,h)},__dispatch:d=>window.dispatchEvent(new CustomEvent(E,{detail:d}))};}();
  )
}

///|
fn make_push_script(
  global_name : String,
  event_name : String,
  name_js : String,
  payload_js : String,
) -> String {
  let g = Json::string(global_name).stringify()
  let e = Json::string(event_name).stringify()
  (
    $|!function(){const d=[\{name_js},\{payload_js}],b=window[\{g}];b?b.__dispatch(d):window.dispatchEvent(new CustomEvent(\{e},{detail:d}));}();
  )
}

// ── Tests ─────────────────────────────────────────────────────────────────────

///|
test "CommandResponse ok encodes as raw JSON payload" {
  let r = CommandResponse::ok({ "x": Json::number(1) })
  let wire = r.to_wire()
  let decoded = @encoding/utf8.decode(wire)
  assert_true(decoded == "{\"x\":1}")
}

test "CommandResponse error encodes as error message string" {
  let r = CommandResponse::error("oops")
  let wire = r.to_wire()
  let decoded = @encoding/utf8.decode(wire)
  assert_true(decoded == "oops")
}
