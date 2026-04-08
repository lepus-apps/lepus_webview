///|
/// High-level managed plugin definition that automatically wires parent-process
/// handlers and child-process proxies.
pub struct ManagedPlugin {
  name : String
  parent_installers : Array[(ProcessPluginRouter) -> Unit]
  child_installers : Array[(PluginContext[Unit], ProcessCommandProxy) -> Unit]
}

///|
/// Registration context used while building a `ManagedPlugin`.
pub struct ManagedPluginBuilder {
  plugin_name : String
  parent_installers : Array[(ProcessPluginRouter) -> Unit]
  child_installers : Array[(PluginContext[Unit], ProcessCommandProxy) -> Unit]
}

///|
/// High-level managed app that owns the parent dispatcher and child webview
/// process lifecycle.
pub struct ManagedApp {
  title : String
  url : String
  width : Int
  height : Int
  debug : Int
  child_arg : String
  mut html : String
  plugins : Array[ManagedPlugin]
}

///|
/// Creates a managed plugin whose commands are available from JavaScript
/// without exposing IPC details to user code.
pub fn ManagedPlugin::new(
  name : String,
  register : (ManagedPluginBuilder) -> Unit,
) -> ManagedPlugin {
  let builder = ManagedPluginBuilder::{
    plugin_name: name,
    parent_installers: [],
    child_installers: [],
  }
  register(builder)
  {
    name,
    parent_installers: builder.parent_installers,
    child_installers: builder.child_installers,
  }
}

///|
/// Registers a typed synchronous plugin command.
pub fn[
  Payload : @json.FromJson + ToJson,
  Reply : @json.FromJson + ToJson,
] ManagedPluginBuilder::command(
  self : ManagedPluginBuilder,
  api_name : String,
  callback : (Payload) -> Reply,
) -> Unit {
  let plugin_name = self.plugin_name
  self.parent_installers.push(router => router.command(api_name, callback))
  self.child_installers.push((plugin, proxy) => {
    let handler : (Payload) -> Reply raise = proxy.plugin_handler(
      plugin_name,
      api_name,
    )
    plugin.command_result_bg(api_name, handler)
  })
}

///|
/// Registers a typed synchronous plugin command that can raise explicit
/// command errors.
pub fn[
  Payload : @json.FromJson + ToJson,
  Reply : @json.FromJson + ToJson,
] ManagedPluginBuilder::command_result(
  self : ManagedPluginBuilder,
  api_name : String,
  callback : (Payload) -> Reply raise Error,
) -> Unit {
  let plugin_name = self.plugin_name
  self.parent_installers.push(router => router.command_result(api_name, callback))
  self.child_installers.push((plugin, proxy) => {
    let handler : (Payload) -> Reply raise = proxy.plugin_handler(
      plugin_name,
      api_name,
    )
    plugin.command_result_bg(api_name, handler)
  })
}

///|
/// Registers a typed async plugin command.
pub fn[
  Payload : @json.FromJson + ToJson,
  Reply : @json.FromJson + ToJson,
] ManagedPluginBuilder::command_async(
  self : ManagedPluginBuilder,
  api_name : String,
  callback : async (Payload) -> Reply,
) -> Unit {
  let plugin_name = self.plugin_name
  self.parent_installers.push(router => router.command_async(api_name, callback))
  self.child_installers.push((plugin, proxy) => {
    let handler : (Payload) -> Reply raise = proxy.plugin_handler(
      plugin_name,
      api_name,
    )
    plugin.command_result_bg(api_name, handler)
  })
}

///|
/// Registers a typed async plugin command that can raise explicit command
/// errors.
pub fn[
  Payload : @json.FromJson + ToJson,
  Reply : @json.FromJson + ToJson,
] ManagedPluginBuilder::command_result_async(
  self : ManagedPluginBuilder,
  api_name : String,
  callback : async (Payload) -> Reply raise Error,
) -> Unit {
  let plugin_name = self.plugin_name
  self.parent_installers.push(
    router => router.command_result_async(api_name, callback),
  )
  self.child_installers.push((plugin, proxy) => {
    let handler : (Payload) -> Reply raise = proxy.plugin_handler(
      plugin_name,
      api_name,
    )
    plugin.command_result_bg(api_name, handler)
  })
}

///|
/// Creates a managed app. The library handles the parent dispatcher and child
/// webview process automatically.
pub fn ManagedApp::new(
  title? : String = "MoonBit WebView",
  url? : String = "",
  width? : Int = 800,
  height? : Int = 600,
  debug? : Int = 0,
  child_arg? : String = "--moonbit-webview-child",
) -> ManagedApp {
  {
    title,
    url,
    width,
    height,
    debug,
    child_arg,
    html: "",
    plugins: [],
  }
}

///|
/// Installs a managed plugin into the app.
pub fn ManagedApp::install(self : ManagedApp, plugin : ManagedPlugin) -> Unit {
  self.plugins.push(plugin)
}

///|
/// Sets inline HTML content for the child webview.
pub fn ManagedApp::set_html(self : ManagedApp, html : String) -> Unit {
  self.html = html
}

///|
/// Runs the managed app end-to-end.
pub fn ManagedApp::run(self : ManagedApp) -> Unit {
  let args = @sys.get_cli_args()
  if args.length() > 1 && args[1] == self.child_arg {
    guard WindowManager::connect_child_process() == 0 else {
      abort("ManagedApp::run: connect child process failed")
    }
    @async.run_async_main(() => self.run_child_async())
    return
  }
  let wm = WindowManager::init()
  guard args.length() > 0 else { abort("ManagedApp::run: missing argv[0]") }
  let child_pid = wm.spawn_process(args[0], self.child_arg)
  guard child_pid > 0 else {
    abort("ManagedApp::run: spawn webview process failed")
  }
  @async.run_async_main(() => self.build_router().serve(wm, child_pid))
}

///|
async fn ManagedApp::run_child_async(self : ManagedApp) -> Unit {
  @async.with_task_group(task_group => {
    let wm = WindowManager::init(is_main=false)
    let webview = WebView::new_managed(
      task_group,
      title=self.title,
      url=self.url,
      width=self.width,
      height=self.height,
      debug=self.debug,
    )
    self.install_child_plugins(webview, wm)
    if self.html != "" {
      webview.set_html(self.html)
    }
    webview.run()
  })
}

///|
fn ManagedApp::build_router(self : ManagedApp) -> ProcessCommandRouter {
  let router = ProcessCommandRouter::new()
  for plugin in self.plugins {
    router.plugin(plugin.name, plugin_router => {
      for install in plugin.parent_installers {
        install(plugin_router)
      }
    })
  }
  router
}

///|
fn ManagedApp::install_child_plugins(
  self : ManagedApp,
  webview : WebView[Unit],
  wm : WindowManager,
) -> Unit {
  let proxy = ProcessCommandProxy::new(wm, webview.window_id())
  let host = PluginHost::new(webview)
  for plugin in self.plugins {
    let child_installers = plugin.child_installers
    host.install(
      Plugin::new(plugin.name, plugin_context => {
        for install in child_installers {
          install(plugin_context, proxy)
        }
      }),
    )
  }
}
