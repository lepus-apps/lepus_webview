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
struct CommandBridge[X] {
  webview : WebView[X]
  global_name : String
  binding_name : String
  event_name : String
  // Sync handlers: called in-line, must return immediately.
  handlers : Map[String, (Json) -> CommandResponse]
  // Async handlers: run inline via async_run_inline.
  // Stored as (id_bytes, payload) -> Unit closures that call respond_raw themselves.
  async_handlers : Map[String, async (Bytes, Json) -> Unit]
}

///|
/// Creates and installs a command bridge for the given webview.
pub fn[X] CommandBridge::new(
  webview : WebView[X],
  global_name? : String = "MoonBitBridge",
  binding_name? : String = "__moonbit_command",
  event_name? : String = "moonbit:command",
) -> CommandBridge[X] {
  guard webview.bindings.get(binding_name) is None else {
    abort("CommandBridge::new: binding name already in use: " + binding_name)
  }
  let bridge = CommandBridge::{
    webview,
    global_name,
    binding_name,
    event_name,
    handlers: {},
    async_handlers: {},
  }
  bridge.webview.bind_raw(binding_name, (raw_id, raw_req) => {
    // NOTE: WebView::bind_raw already copies C strings into MoonBit Bytes.
    log(1, "[bridge:new] received callback")
    webview.task_group.spawn_bg(() => bridge.dispatch(raw_id, raw_req))
  })
  bridge.webview.init(make_bridge_script(global_name, binding_name, event_name))
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
  self.async_handlers.clear()
  self.webview.unbind(self.binding_name)
}

///|
/// Registers a synchronous typed command handler.
///
/// The callback is called directly on the webview thread during dispatch.
/// For IO-bound or slow work use `handle_async` / `handle_result_async`.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle(
  self : CommandBridge[X],
  name : String,
  callback : (Payload) -> Reply,
) -> Unit {
  self.handlers.set(name, fn(json) {
    CommandResponse::ok(callback(@json.from_json(json))) catch {
      err => CommandResponse::error(err.to_string())
    }
  })
}

///|
/// Registers a synchronous typed command handler that can raise errors.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_result(
  self : CommandBridge[X],
  name : String,
  callback : (Payload) -> Reply raise Error,
) -> Unit {
  self.handlers.set(name, json => {
    CommandResponse::ok(callback(@json.from_json(json))) catch {
      msg => CommandResponse::error("\{msg}")
    }
  })
}

///|
/// Registers an **async** typed command handler.
///
/// The callback is spawned as a `moonbitlang/async` coroutine, so it can
/// freely `await` IO operations (timers, file reads, HTTP requests, …).
/// The JS-side Promise stays pending until the coroutine completes.
///
/// Example:
/// ```moonbit nocheck
/// bridge.handle_async("fetch_file", async fn(req : FileRequest) -> String {
///   let data = @fs.read_to_string(req.path)   // awaits IO
///   data
/// })
/// ```
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_async(
  self : CommandBridge[X],
  name : String,
  callback : async (Payload) -> Reply,
) -> Unit {
  self.async_handlers.set(name, async fn(id_bytes, json) {
    let resp : CommandResponse = match
      (try? @json.from_json(json) : Result[Payload, _]) {
      Ok(p) => CommandResponse::ok(callback(p))
      Err(err) => CommandResponse::error(err.to_string())
    }
    let wire = resp.to_wire()
    let status = match resp {
      Ok(_) => 0
      Error(_) => 1
    }
    log(1, "[bridge:async] responding status=\{status}")
    self.webview.respond_raw(id_bytes, status, wire)
  })
}

///|
/// Registers an **async** typed command handler that can raise errors.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] CommandBridge::handle_result_async(
  self : CommandBridge[X],
  name : String,
  callback : async (Payload) -> Reply raise Error,
) -> Unit {
  self.async_handlers.set(name, (id_bytes, json) => {
    self.webview.task_group.spawn_bg(() => {
      let resp : CommandResponse = CommandResponse::ok(
        callback(@json.from_json(json)),
      ) catch {
        msg => CommandResponse::error("\{msg}")
      }
      let wire = resp.to_wire()
      let status = match resp {
        Ok(_) => 0
        Error(_) => 1
      }
      log(1, "[bridge:async] responding status=\{status}")
      self.webview.respond_raw(id_bytes, status, wire)
    })
  })
}

///|
/// Pushes a fire-and-forget event to JavaScript.
/// JS listener receives `[name, payload]`.
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
  self.webview.dispatch(() => self.webview.eval(script))
}

// ── Internal ──────────────────────────────────────────────────────────────────

///|
/// Pure core: parse a JSON request string and route to a registered handler.
///
/// Returns `CommandResponse` without touching any FFI — fully testable.
/// Input format: `'["<name>", <payload>]'`
fn[X] CommandBridge::dispatch_req(
  self : CommandBridge[X],
  req_str : String,
) -> CommandResponse {
  log(
    1,
    "[bridge:dispatch_req] req=\{req_str} handlers=\{self.handlers.length()}",
  )
  try {
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
}

///|
/// Hot path: decode raw bytes, route to handler, send wire response.
///
/// Sync handlers are called in-line and their response sent immediately.
/// Async handlers are spawned as a coroutine; when the coroutine resolves
/// the response is delivered via `webview.dispatch` back to the webview
/// thread and sent with `respond_raw`.
async fn[X] CommandBridge::dispatch(
  self : CommandBridge[X],
  id_bytes : Bytes,
  req_bytes : Bytes,
) -> Unit noraise {
  log(1, "[bridge:dispatch] invoked")
  let req_str = @encoding/utf8.decode(req_bytes) catch {
    Malformed(e) => {
      log(1, "[bridge:dispatch] utf8 decode error: \{e}")
      let err_wire = CommandResponse::error("req decode failed").to_wire()
      self.webview.respond_raw(id_bytes, 1, err_wire)
      return
    }
  }

  // Check async handlers first so they can be defined alongside sync ones
  // without conflict.  (A name must only appear in one map.)
  try {
    match (@json.parse(req_str) : Json) {
      [String(name), payload] if self.async_handlers.get(name) is Some(h) => {
        log(1, "[bridge:dispatch] running async handler inline: \{name}")
        h(id_bytes, payload)
      }
      _ => {
        // Sync path — dispatch_req handles both lookup and error cases.
        let resp = self.dispatch_req(req_str)
        let wire = resp.to_wire()
        let status = match resp {
          Ok(_) => 0
          Error(_) => 1
        }
        log(1, "[bridge:dispatch] responding status=\{status}")
        self.webview.respond_raw(id_bytes, status, wire)
      }
    }
  } catch {
    _ => {
      // Sync path fallback on parse error.
      let resp = self.dispatch_req(req_str)
      let wire = resp.to_wire()
      let status = match resp {
        Ok(_) => 0
        Error(_) => 1
      }
      self.webview.respond_raw(id_bytes, status, wire)
    }
  }
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
fn[X] make_test_bridge(task_group : @async.TaskGroup[X]) -> CommandBridge[X] {
  CommandBridge::{
    webview: WebView::new(task_group),
    global_name: "MoonBitBridge",
    binding_name: "__moonbit_command",
    event_name: "moonbit:command",
    handlers: {},
    async_handlers: {},
  }
}

///|
async test "dispatch_req: ok response roundtrip" {
  @async.with_task_group(task_group => {
    let bridge = make_test_bridge(task_group)
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
  })
}

///|
async test "dispatch_req: unknown command returns error" {
  @async.with_task_group(task_group => {
    let bridge = make_test_bridge(task_group)

    let resp = bridge.dispatch_req("[\"no-such-cmd\",null]")

    assert_true(resp is Error(_))
    assert_true(wire_str(resp).has_prefix("[1,"))
  })
}

///|
async test "dispatch_req: malformed JSON returns error" {
  @async.with_task_group(task_group => {
    let bridge = make_test_bridge(task_group)

    let resp = bridge.dispatch_req("not json at all")

    assert_true(resp is Error(_))
    assert_true(wire_str(resp).has_prefix("[1,"))
  })
}

///|
async test "dispatch_req: wrong shape returns error" {
  @async.with_task_group(task_group => {
    let bridge = make_test_bridge(task_group)

    let resp = bridge.dispatch_req("{\"name\":\"foo\",\"payload\":null}")

    assert_true(resp is Error(_))
  })
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
