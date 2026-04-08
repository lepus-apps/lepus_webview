///|
/// A plugin definition that can be installed into a `PluginHost`.
///
/// A plugin is typically exposed from a MoonBit module:
///
/// ```moonbit nocheck
/// pub fn plugin() -> @webview.Plugin {
///   @webview.Plugin::new("math", fn(plugin) {
///     plugin.command("sum", fn(payload : SumPayload) {
///       SumReply::{ total: payload.left + payload.right }
///     })
///   })
/// }
/// ```
///
/// `on_install` runs after the plugin has finished registering commands and
/// JS helpers on the host. `on_destroy` runs when the owning plugin host
/// is destroyed.
struct PluginInternal[X] {
  name : String
  register : (PluginContext[X]) -> Unit
  on_install : (PluginContext[X]) -> Unit
  on_destroy : (PluginContext[X]) -> Unit
}

///|
/// Plugin host built on top of `CommandBridge`.
///
/// On the JavaScript side this exposes:
/// - `window[global_name]["@@call"](plugin_name, api_name, payload)`
/// - `window[global_name][plugin_name][api_name](payload)`
/// - `window[global_name][plugin_name]["@@on"](listener)`
/// - `window[global_name][plugin_name]["@@onEvent"](name, listener)`
struct PluginHost[X] {
  webview : WebView[X]
  bridge : CommandBridge[X]
  global_name : String
  plugins : Map[String, Bool]
  apis : Map[String, Bool]
}

///|
/// Registration context handed to a plugin while it installs its public APIs.
struct PluginContext[X] {
  host : PluginHost[X]
  plugin_name : String
}

///|
/// A plugin-scoped event sent from MoonBit to JavaScript.
pub struct PluginEvent {
  plugin : String
  name : String
  payload : Json
} derive(ToJson, FromJson, Eq)

///|
/// Builds a plugin value that can later be installed on a `PluginHost`.
pub fn[X] PluginInternal::new(
  name : String,
  register : (PluginContext[X]) -> Unit,
  on_install? : (PluginContext[X]) -> Unit = fn(_context) {  },
  on_destroy? : (PluginContext[X]) -> Unit = fn(_context) {  },
) -> PluginInternal[X] {
  PluginInternal::{ name, register, on_install, on_destroy }
}

///|
/// Creates a plugin host backed by a `CommandBridge`.
///
/// `global_name` controls the JavaScript namespace used for plugin APIs
/// (defaults to `window.MoonBitPlugins`).
pub fn[X] PluginHost::new(
  webview : WebView[X],
  global_name? : String = "MoonBitPlugins",
) -> PluginHost[X] {
  let bridge = CommandBridge::new(webview, global_name="MoonBitBridge")
  let host = PluginHost::{ webview, bridge, global_name, plugins: {}, apis: {} }
  host.install_script(make_plugin_host_script(global_name, "MoonBitBridge"))
  host
}

///|
/// Installs a plugin into the host.
///
/// This aborts if another plugin with the same name has already been
/// installed on this host.
pub fn[X] PluginHost::install(
  self : PluginHost[X],
  plugin : PluginInternal[X],
) -> Unit {
  guard !is_reserved_plugin_name(plugin.name) else {
    abort("PluginHost::install: reserved plugin name: " + plugin.name)
  }
  guard self.plugins.get(plugin.name) is None else {
    abort("PluginHost::install: plugin already installed: " + plugin.name)
  }
  let context = PluginContext::{ host: self, plugin_name: plugin.name }
  self.plugins.set(plugin.name, true)
  self.install_script(
    make_plugin_namespace_script(self.global_name, plugin.name),
  )
  (plugin.register)(context)
  (plugin.on_install)(context)
}

///|
/// Destroys the plugin host and all installed plugins.
pub fn[X] PluginHost::destroy(self : PluginHost[X]) -> Unit {
  self.plugins.clear()
  self.apis.clear()
  self.bridge.destroy()
}

///|
/// Returns the JavaScript global object name used for plugin APIs.
pub fn[X] PluginHost::global_name(self : PluginHost[X]) -> String {
  self.global_name
}

///|
/// Returns the underlying command bridge used by the plugin host.
pub fn[X] PluginHost::command_bridge(self : PluginHost[X]) -> CommandBridge[X] {
  self.bridge
}

///|
/// Emits a plugin-scoped event from the main program to JavaScript.
///
/// JavaScript receives these events through
/// `window.MoonBitPlugins[plugin_name]["@@on"](...)` and
/// `window.MoonBitPlugins[plugin_name]["@@onEvent"](...)`.
fn[X, Payload : ToJson] PluginHost::emit(
  self : PluginHost[X],
  plugin_name : String,
  event_name : String,
  payload : Payload,
) -> Unit {
  guard self.plugins.get(plugin_name) is Some(_) else {
    abort("PluginHost::emit: plugin is not installed: " + plugin_name)
  }
  self.bridge.send(plugin_event_command_name(), PluginEvent::{
    plugin: plugin_name,
    name: event_name,
    payload: payload.to_json(),
  })
}

///|
/// Returns the plugin name currently being installed.
pub fn[X] PluginContext::name(self : PluginContext[X]) -> String {
  self.plugin_name
}

///|
/// Registers a typed plugin command that performs blocking work on a detached
/// native thread and responds asynchronously to JavaScript.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] PluginContext::command_result_bg(
  self : PluginContext[X],
  api_name : String,
  callback : (Payload) -> Reply raise,
) -> Unit {
  self.install_command_api(api_name, command_name => {
    self.host.bridge.handle_result_bg(command_name, callback)
  })
}

///|
/// Registers an async typed plugin command.
///
/// The command becomes callable from JavaScript through:
/// `window.MoonBitPlugins[plugin_name][api_name](payload)`.
/// The callback is spawned as a background task, non-blocking.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] PluginContext::command_async(
  self : PluginContext[X],
  api_name : String,
  callback : async (Payload) -> Reply,
) -> Unit {
  self.install_command_api(api_name, command_name => {
    self.host.bridge.handle_async(command_name, callback)
  })
}

///|
/// Registers an async typed plugin command that can return explicit command errors.
pub fn[X, Payload : @json.FromJson, Reply : ToJson] PluginContext::command_result_async(
  self : PluginContext[X],
  api_name : String,
  callback : async (Payload) -> Reply raise Error,
) -> Unit {
  self.install_command_api(api_name, command_name => {
    self.host.bridge.handle_result_async(command_name, callback)
  })
}

///|
fn[X] PluginContext::register_api(
  self : PluginContext[X],
  api_name : String,
) -> String {
  guard !is_reserved_api_name(api_name) else {
    abort(
      "PluginContext::register_api: reserved API name: " +
      self.plugin_name +
      "." +
      api_name,
    )
  }
  let command_name = plugin_command_name(self.plugin_name, api_name)
  guard self.host.apis.get(command_name) is None else {
    abort(
      "PluginContext::register_api: API already registered: " +
      self.plugin_name +
      "." +
      api_name,
    )
  }
  self.host.apis.set(command_name, true)
  command_name
}

///|
fn[X] PluginContext::install_command_api(
  self : PluginContext[X],
  api_name : String,
  register : (String) -> Unit,
) -> Unit {
  let command_name = self.register_api(api_name)
  log(1, "[plugin] registering command: \{command_name}")
  register(command_name)
  self.host.install_script(
    make_plugin_api_script(
      self.host.global_name,
      self.plugin_name,
      api_name,
      command_name,
    ),
  )
}

///|
fn[X] PluginHost::install_script(self : PluginHost[X], script : String) -> Unit {
  self.webview.init(script)
  self.webview.eval(script)
}

///|
fn string_literal(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn plugin_command_name(plugin_name : String, api_name : String) -> String {
  "plugin:\{string_literal(plugin_name)}:\{string_literal(api_name)}"
}

///|
fn plugin_event_command_name() -> String {
  "@@plugin:event"
}

///|
fn is_disallowed_js_property_name(name : String) -> Bool {
  name is (['@', '@', ..] | "__proto__" | "prototype" | "constructor")
}

///|
fn is_reserved_plugin_name(plugin_name : String) -> Bool {
  is_reserved_js_name(plugin_name)
}

///|
fn is_reserved_api_name(api_name : String) -> Bool {
  is_reserved_js_name(api_name)
}

///|
fn is_reserved_js_name(name : String) -> Bool {
  is_disallowed_js_property_name(name)
}

///|
fn make_plugin_host_script(
  global_name : String,
  bridge_global_name : String,
) -> String {
  let global_name_js = string_literal(global_name)
  let bridge_global_name_js = string_literal(bridge_global_name)
  (
    $|!function(){const n=\{global_name_js},e=window[n],t=e&&"object"==typeof e?e:Object.create(null);function r(){const n=window[\{bridge_global_name_js}];return n&&"function"==typeof n.send?n:null}function i(n){return Array.isArray(n["@@listeners"])||(n["@@listeners"]=[]),"function"!=typeof n["@@on"]&&(n["@@on"]=function(e){if(t["@@ensureBridgeListener"](),"function"!=typeof e)throw new TypeError("MoonBit plugin listener must be a function");return n["@@listeners"].push(e),function(){n["@@listeners"]=n["@@listeners"].filter(function(n){return n!==e})}}),"function"!=typeof n["@@onEvent"]&&(n["@@onEvent"]=function(e,t){if("function"!=typeof t)throw new TypeError("MoonBit plugin listener must be a function");return n["@@on"](function(n){n.name===e&&t(n)})}),n}t["@@call"]=function(n,e,i){t["@@ensureBridgeListener"]();const o=r();return o?o.send("plugin:"+JSON.stringify(n)+":"+JSON.stringify(e),i):Promise.reject(new Error("MoonBit command bridge is not available"))},t["@@ensurePlugin"]=function(n){const e=t[n];if(e&&"object"==typeof e)return i(e);const r=Object.create(null);return t[n]=r,i(r)},t["@@emit"]=function(n,e,r){const i={plugin:n,name:e,payload:void 0===r?null:r},o=t["@@ensurePlugin"](n)["@@listeners"].slice();for(const n of o)n(i);return i},t["@@ensureBridgeListener"]=function(){if(t["@@bridgeListenerInstalled"])return!0;const n=r();return!(!n||"function"!=typeof n.onCommand)&&(n.onCommand(function(n){if(!Array.isArray(n)||"@@plugin:event"!==n[0])return;const e=n[1];e&&"object"==typeof e&&t["@@emit"](e.plugin,e.name,e.payload)}),t["@@bridgeListenerInstalled"]=!0,!0)},t["@@defineApi"]=function(n,e,i){const o=t["@@ensurePlugin"](n);return t["@@ensureBridgeListener"](),o[e]=function(n){const e=r();return e?e.send(i,n):Promise.reject(new Error("MoonBit command bridge is not available"))},o[e]},t["@@has"]=function(n,e){const r=t[n];return!(!r||"function"!=typeof r[e])},t["@@ensureBridgeListener"](),window[n]=t}();
  )
}

///|
fn make_plugin_namespace_script(
  global_name : String,
  plugin_name : String,
) -> String {
  let global_name_js = string_literal(global_name)
  let plugin_name_js = string_literal(plugin_name)
  (
    $|!function(){const e=\{global_name_js},n=\{plugin_name_js},o=window[e]&&"object"==typeof window[e]?window[e]:window[e]=Object.create(null);"function"!=typeof o["@@ensurePlugin"]?o[n]&&"object"==typeof o[n]||(o[n]=Object.create(null)):o["@@ensurePlugin"](n)}();
  )
}

///|
fn make_plugin_api_script(
  global_name : String,
  plugin_name : String,
  api_name : String,
  command_name : String,
) -> String {
  let global_name_js = string_literal(global_name)
  let plugin_name_js = string_literal(plugin_name)
  let api_name_js = string_literal(api_name)
  let command_name_js = string_literal(command_name)
  (
    $|!function(){const n=\{global_name_js},e=\{plugin_name_js},o=\{api_name_js},t=\{command_name_js},i=window[n]&&"object"==typeof window[n]?window[n]:window[n]=Object.create(null);if("function"==typeof i["@@defineApi"])return void i["@@defineApi"](e,o,t);(i[e]&&"object"==typeof i[e]?i[e]:i[e]=Object.create(null))[o]=function(n){const e=window[n];return e&&"function"==typeof e.send?e.send(t,n):Promise.reject(new Error("MoonBit command bridge is not available"))}}();
  )
}

///|
test "reserved plugin and api names share JS property guard" {
  assert_true(is_reserved_plugin_name("@@call"))
  assert_true(is_reserved_plugin_name("__proto__"))
  assert_true(is_reserved_api_name("constructor"))
  assert_false(is_reserved_plugin_name("math"))
  assert_false(is_reserved_api_name("sum"))
}

///|
test "plugin command names remain JSON quoted for stable JS dispatch" {
  assert_eq(plugin_command_name("math", "sum"), "plugin:\"math\":\"sum\"")
  assert_eq(plugin_command_name("a:b", "c"), "plugin:\"a:b\":\"c\"")
  assert_eq(
    plugin_command_name("quote\"plugin", "slash\\api"),
    "plugin:\"quote\\\"plugin\":\"slash\\\\api\"",
  )
}
