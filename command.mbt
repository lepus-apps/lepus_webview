// ── Wire protocol ────────────────────────────────────────────────────────────
//
// JS → MoonBit  (request)
//   window.__moonbit_command(name, payload)
//   webview delivers: seq="<id>", req='["<name>", <payload>]'
//
// MoonBit → JS  (response)
//   success:  [0, <result_json>]
//   error:    [1, "<message>"]
//
// MoonBit → JS  (push event)
//   CustomEvent("moonbit:command", { detail: [name, payload] })
//
// Optimisations vs the old design:
//   • Request: flat 2-tuple [name, payload] instead of {name, payload} object
//     — one fewer JSON object allocation + one fewer key lookup per call.
//   • Response: compact 2-tuple [status, data] instead of
//     {status, payload, error} — ~30 bytes saved per roundtrip.
//   • seq (call-id) is borrowed directly back to webview_return_raw,
//     never copied into MoonBit's heap — saves 2 allocs + 2 UTF-8
//     encode/decode roundtrips on every call.

///|
/// Structured response returned from JS → MoonBit commands.
///
/// Wire encoding:
///   success  →  `[0, <payload_json>]`
///   error    →  `[1, "<message>"]`
pub(all) enum CommandResponse {
  Ok(Json)
  Error(String)
} derive(Show, Eq)

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
  let s : Json = match self {
    Ok(payload) => [0, payload]
    Error(msg) => [1, msg]
  }
  @encoding/utf8.encode(s.stringify())
}

// ── CommandBridge ─────────────────────────────────────────────────────────────

///|
/// High-level JSON command bridge built on top of `webview.bind()`.
///
/// JS API:
/// - `window[global_name].send(name, payload)` → `Promise<[0,result]|[1,msg]>`
/// - `window[global_name].onCommand(listener)` for MoonBit → JS push events
struct CommandBridge {
  webview : WebView
  global_name : String
  binding_name : String
  event_name : String
  handlers : Map[String, (Json) -> CommandResponse]
}

///|
/// Creates and installs a command bridge for the given webview.
pub fn CommandBridge::new(
  webview : WebView,
  global_name? : String = "MoonBitBridge",
  binding_name? : String = "__moonbit_command",
  event_name? : String = "moonbit:command",
) -> CommandBridge {
  guard webview.bindings.get(binding_name) is None else {
    abort("CommandBridge::new: binding name already in use: " + binding_name)
  }
  let bridge = CommandBridge::{
    webview,
    global_name,
    binding_name,
    event_name,
    handlers: {},
  }
  // bind_raw: seq arrives as borrowed Bytes and is passed straight to
  // webview_return_raw — no copy, no UTF-8 decode/encode of the call-id.
  bridge.webview.bind_raw(binding_name, fn(raw_id, raw_req) {
    bridge.dispatch(raw_id, raw_req)
  })
  bridge.webview.init(make_bridge_script(global_name, binding_name, event_name))
  bridge
}

///|
pub fn CommandBridge::global_name(self : CommandBridge) -> String {
  self.global_name
}

///|
pub fn CommandBridge::event_name(self : CommandBridge) -> String {
  self.event_name
}

///|
pub fn CommandBridge::destroy(self : CommandBridge) -> Unit {
  self.handlers.clear()
  self.webview.unbind(self.binding_name)
}

///|
/// Registers a typed command handler.
pub fn[Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle(
  self : CommandBridge,
  name : String,
  callback : (Payload) -> Reply,
) -> Unit {
  self.handlers.set(name, fn(json) {
    match (try? @json.from_json(json) : Result[Payload, _]) {
      Ok(p) => CommandResponse::ok(callback(p))
      Err(err) => CommandResponse::error(err.to_string())
    }
  })
}

///|
/// Registers a typed command handler that can raise errors.
pub fn[Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_result(
  self : CommandBridge,
  name : String,
  callback : (Payload) -> Reply raise Error,
) -> Unit {
  self.handlers.set(name, fn(json) {
    CommandResponse::ok(callback(@json.from_json(json))) catch {
      msg => CommandResponse::error("\{msg}")
    }
  })
}

///|
/// Pushes a fire-and-forget event to JavaScript.
/// JS listener receives `[name, payload]`.
pub fn[Payload : ToJson] CommandBridge::send(
  self : CommandBridge,
  name : String,
  payload : Payload,
) -> Unit {
  let script = make_push_script(
    self.global_name,
    self.event_name,
    Json::string(name).stringify(),
    ToJson::to_json(payload).stringify(),
  )
  self.webview.dispatch(fn() { self.webview.eval(script) })
}

// ── Internal ──────────────────────────────────────────────────────────────────

///|
/// Pure core: parse a JSON request string and route to a registered handler.
///
/// Returns `CommandResponse` without touching any FFI — fully testable.
/// Input format: `'["<name>", <payload>]'`
fn CommandBridge::dispatch_req(
  self : CommandBridge,
  req_str : String,
) -> CommandResponse {
  log(
    1,
    "[bridge:dispatch_req] req=\{req_str} handlers=\{self.handlers.length()}",
  )
  let resp = try {
    match (@json.parse(req_str) : Json) {
      [String(name), payload] => {
        log(1, "[bridge:dispatch_req] name=\{name}")
        match self.handlers.get(name) {
          Some(h) => {
            let r = h(payload)
            log(2, "[bridge:dispatch_req] handler ok, resp=\{r}")
            r
          }
          None => {
            log(1, "[bridge:dispatch_req] unknown command: \{name}")
            CommandResponse::error("Unknown command: " + name)
          }
        }
      }
      other => {
        log(1, "[bridge:dispatch_req] bad shape: \{other}")
        CommandResponse::error("Expected [name, payload], got: \{other}")
      }
    }
  } catch {
    e => {
      log(1, "[bridge:dispatch_req] parse error: \{e}")
      CommandResponse::error("JSON parse error: \{e}")
    }
  }
  resp
}

///|
/// Hot path: decode raw bytes, call `dispatch_req`, send wire response.
///
/// raw_id is borrowed for the lifetime of this call; it goes straight to
/// webview_return_raw without ever entering MoonBit's string/UTF-8 system.
fn CommandBridge::dispatch(
  self : CommandBridge,
  raw_id : Bytes,
  raw_req : Bytes,
) -> Unit {
  log(1, "[bridge:dispatch] invoked")
  let req_bytes = webview_copy_cstr(raw_req)
  let resp = self.dispatch_req(@encoding/utf8.decode(req_bytes)) catch {
    Malformed(e) => {
      log(1, "[bridge:dispatch] utf8 decode error: \{e}")
      CommandResponse::error("req decode failed")
    }
  }
  let wire = resp.to_wire()
  let status = match resp {
    Ok(_) => 0
    Error(_) => 1
  }
  log(1, "[bridge:dispatch] responding status=\{status}")
  self.webview.respond_raw(raw_id, status, wire)
}

// ── JS scripts ────────────────────────────────────────────────────────────────

///|
fn make_bridge_script(
  global_name : String,
  binding_name : String,
  event_name : String,
) -> String {
  // Readable form:
  //   !function() {
  //     const G=<global_name>, B=<binding_name>, E=<event_name>;
  //     window[G] = {
  //       // send resolves to the raw wire tuple [status, data].
  //       // status 0 = ok, 1 = error. Callers that want a structured result
  //       // should use sendCmd which unwraps the tuple.
  //       send: (name, payload) => window[B](name, payload ?? null),
  //       // sendCmd resolves to { ok: true, payload } or throws on error.
  //       sendCmd: (name, payload) =>
  //         window[B](name, payload ?? null).then(r =>
  //           r[0] === 0 ? r[1] : Promise.reject(new Error(r[1]))
  //         ),
  //       onCommand: (listener) => {
  //         const h = e => listener(e.detail);
  //         window.addEventListener(E, h);
  //         return () => window.removeEventListener(E, h);
  //       },
  //       __dispatch: d => window.dispatchEvent(new CustomEvent(E, {detail:d})),
  //     };
  //   }();
  let g = Json::string(global_name).stringify()
  let b = Json::string(binding_name).stringify()
  let e = Json::string(event_name).stringify()
  (
    $|!function(){const G=\{g},B=\{b},E=\{e};window[G]={send:(n,p)=>window[B](n,p??null),sendCmd:(n,p)=>window[B](n,p??null).then(r=>r[0]===0?r[1]:Promise.reject(new Error(r[1]))),onCommand:l=>{const h=e=>l(e.detail);window.addEventListener(E,h);return()=>window.removeEventListener(E,h)},__dispatch:d=>window.dispatchEvent(new CustomEvent(E,{detail:d}))};}();
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
/// Decode `to_wire()` bytes back to a string for assertions.
/// All wire output is valid UTF-8 ASCII, so this never fails in practice.
fn wire_str(resp : CommandResponse) -> String {
  @encoding/utf8.decode(resp.to_wire()) catch {
    _ => "<decode error>"
  }
}

///|
/// Build a bare CommandBridge (no real webview binding) for unit-testing the
/// pure `dispatch_req` path.  `WebView::new()` allocates an off-screen handle
/// on macOS without opening a visible window.
fn make_test_bridge() -> CommandBridge {
  CommandBridge::{
    webview: WebView::new(),
    global_name: "MoonBitBridge",
    binding_name: "__moonbit_command",
    event_name: "moonbit:command",
    handlers: {},
  }
}

///|
test "dispatch_req: ok response roundtrip" {
  let bridge = make_test_bridge()
  bridge.handlers.set("math:add", fn(json) {
    match json {
      { "left": Number(l, ..), "right": Number(r, ..), .. } =>
        CommandResponse::ok({ "total": Json::number(l + r) })
      _ => CommandResponse::error("bad payload")
    }
  })

  let resp = bridge.dispatch_req("[\"math:add\",{\"left\":2,\"right\":3}]")

  assert_eq(resp, CommandResponse::Ok({ "total": Json::number(5) }))
  assert_eq(wire_str(resp), "[0,{\"total\":5}]")
}

///|
test "dispatch_req: unknown command returns error" {
  let bridge = make_test_bridge()

  let resp = bridge.dispatch_req("[\"no-such-cmd\",null]")

  assert_true(resp is Error(_))
  assert_true(wire_str(resp).has_prefix("[1,"))
}

///|
test "dispatch_req: malformed JSON returns error" {
  let bridge = make_test_bridge()

  let resp = bridge.dispatch_req("not json at all")

  assert_true(resp is Error(_))
  assert_true(wire_str(resp).has_prefix("[1,"))
}

///|
test "dispatch_req: wrong shape returns error" {
  let bridge = make_test_bridge()

  let resp = bridge.dispatch_req("{\"name\":\"foo\",\"payload\":null}")

  assert_true(resp is Error(_))
}

///|
test "to_wire: ok encodes as [0,<json>]" {
  let r = CommandResponse::ok({ "x": Json::number(1) })
  assert_eq(wire_str(r), "[0,{\"x\":1}]")
}

///|
test "to_wire: error encodes as [1,\"<msg>\"]" {
  let r = CommandResponse::error("oops")
  assert_eq(wire_str(r), "[1,\"oops\"]")
}

///|
test "status bit matches CommandResponse variant" {
  let status = fn(r : CommandResponse) -> Int {
    match r {
      Ok(_) => 0
      Error(_) => 1
    }
  }
  assert_eq(status(CommandResponse::ok(Json::null())), 0)
  assert_eq(status(CommandResponse::error("e")), 1)
}
