///|
/// High-level managed app that owns the parent dispatcher and child webview
/// process lifecycle.
pub struct Window {
  title : String
  width : Int
  height : Int
  size_hint : SizeHint
  debug : Int
  child_arg : String
  mut customization : WindowCustomization
  mut url : String
  mut html : String
  mut runtime_window_id : Int
  plugins : Array[Plugin]
}

///|
/// Creates a managed app. The library handles the parent dispatcher and child
/// webview process automatically.
pub fn Window::new(
  title? : String = "MoonBit WebView",
  url? : String = "",
  width? : Int = 800,
  height? : Int = 600,
  size_hint? : SizeHint = SizeHint::None,
  debug? : Int = 0,
  child_arg? : String = "--moonbit-webview-child",
  customization? : WindowCustomization = WindowCustomization::default(),
) -> Window {
  {
    title,
    url,
    width,
    height,
    debug,
    child_arg,
    customization,
    html: "",
    runtime_window_id: -1,
    plugins: [],
    size_hint,
  }
}

///|
/// Applies native custom-window style flags.
pub fn Window::set_window_customization(
  self : Window,
  customization : WindowCustomization,
) -> Unit {
  self.customization = customization
  if self.runtime_window_id > 0 {
    ignore(
      wm_set_window_customization(
        self.runtime_window_id,
        if customization.frameless {
          1
        } else {
          0
        },
        if customization.resizable {
          1
        } else {
          0
        },
        if customization.always_on_top {
          1
        } else {
          0
        },
      ),
    )
  }
}

///|
/// Installs a managed plugin into the app.
pub fn Window::install(self : Window, plugin : Plugin) -> Unit {
  self.plugins.push(plugin)
}

///|
/// Sets inline HTML content for the child webview.
pub fn Window::set_html(self : Window, html : String) -> Unit {
  self.html = html
  if self.runtime_window_id > 0 {
    ignore(wm_set_html(self.runtime_window_id, @encoding/utf8.encode(html)))
  }
}

///|
pub fn Window::navigate(self : Window, url : String) -> Unit {
  self.url = url
  if self.runtime_window_id > 0 {
    ignore(wm_navigate(self.runtime_window_id, @encoding/utf8.encode(url)))
  }
}

///|
/// Runs the managed app end-to-end.
pub fn Window::run(self : Window) -> Unit {
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
async fn Window::run_child_async(self : Window) -> Unit {
  @async.with_task_group(task_group => {
    let wm = WindowManager::init(is_main=false)
    let webview = WebView::new_managed(
      task_group,
      title=self.title,
      url=self.url,
      width=self.width,
      height=self.height,
      debug=self.debug,
      customization=self.customization,
    )
    self.runtime_window_id = webview.window_id()
    if self.customization.frameless {
      webview.enable_custom_titlebar_support()
    }
    self.install_child_plugins(webview, wm)
    if self.html != "" {
      webview.set_html(self.html)
    }
    webview.run()
  })
}

///|
/// Minimize native window.
pub fn Window::minimize(self : Window) -> Unit {
  let window_id = self.require_runtime_window_id()
  ignore(wm_minimize_window(window_id))
}

///|
/// Toggle native maximize state.
pub fn Window::toggle_maximize(self : Window) -> Unit {
  let window_id = self.require_runtime_window_id()
  ignore(wm_toggle_maximize_window(window_id))
}

///|
/// Close native window.
pub fn Window::close(self : Window) -> Unit {
  let window_id = self.require_runtime_window_id()
  ignore(wm_close_window(window_id))
}

///|
fn Window::build_router(self : Window) -> ProcessCommandRouter {
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
fn Window::install_child_plugins(
  self : Window,
  webview : WebView[Unit],
  wm : WindowManager,
) -> Unit {
  let proxy = ProcessCommandProxy::new(wm, webview.window_id())
  let host = PluginHost::new(webview)
  for plugin in self.plugins {
    host.install(plugin, proxy=Some(proxy))
  }
}

///|
pub fn Window::eval(self : Window, js : String) -> Unit {
  let window_id = self.require_runtime_window_id()
  ignore(wm_eval_js(window_id, @encoding/utf8.encode(js)))
}

///|
fn Window::require_runtime_window_id(self : Window) -> Int {
  guard self.runtime_window_id > 0 else {
    abort("Window API requires a running child webview process")
  }
  self.runtime_window_id
}
