# Lepus WebView

`lepus-apps/webview` is a MoonBit-native desktop framework built on top of
[`webview`](https://github.com/webview/webview). It provides:

- Native windows (`WebKit` / `WebView2`)
- Typed JS <-> MoonBit bridge
- Plugin-style command routing
- Parent/child process IPC APIs

## Architecture

```mermaid
flowchart LR
    subgraph JS["JavaScript Runtime"]
        JSAPI["window.MoonBitBridge / window.MoonBitPlugins"]
    end

    subgraph MB["MoonBit Runtime"]
        WV["WebView"]
        PL["PluginHost + CommandRouter"]
        WM["WindowManager (IPC)"]
        APP["Managed App (parent/child)"]
    end

    subgraph NATIVE["Native Layer"]
        STUB["stub.c + binding.mbt"]
        LIB["webview C library"]
    end

    JSAPI <-->|"Command request/response"| PL
    PL <-->|"Cross-process command/event"| WM
    APP --> WM
    PL --> WV
    WV --> STUB --> LIB
```

## API List

API list below is aligned with [`pkg.generated.mbti`](/Users/.//pkg.generated.mbti).

### `WebView`

- Lifecycle: `destroy`, `terminate`
- Window/UI: `set_title`, `set_size`, `set_html`, `navigate`
- History: `back`, `forward`, `go`, `reload`, `reload_force`
- Handle: `get_handle`

### `Window` (Managed App)

- Setup: `new`, `install`, `set_html`, `navigate`
- History: `back`, `forward`, `go`, `reload`, `reload_force`
- Run: `run`

### `Plugin` / `PluginHost` / `PluginContext`

- Plugin build/install: `Plugin::new`, `PluginInternal::new`, `PluginHost::new`, `PluginHost::install`, `PluginHost::destroy`
- Context handlers: `command_async`, `command_result_async`, `command_result_bg`
- Bridge access: `PluginHost::command_bridge`, `PluginHost::global_name`

### Process Command IPC

- Request/response model: `ProcessCommandRequest`, `ProcessCommandResponse`
- Router: `ProcessCommandRouter::{new, handle, handle_async, handle_result, handle_result_async, dispatch, serve, plugin}`
- Proxy: `ProcessCommandProxy::{new, call, call_plugin, plugin_handler}`
- Plugin router: `ProcessPluginRouter::{command, command_async, command_result, command_result_async}`

### Window Manager IPC

- Process control: `init`, `fork_process`, `spawn_process`, `connect_child_process`
- Window control: `create_window`, `create_child_window`, `run_window`, `destroy_window`, `destroy`
- Messaging: `send_message`, `broadcast`, `request`, `respond`, `try_pop_message`
- Process-command serving: `serve_process_commands`
- State: `is_main_process`, `is_child_process`, `wait_child_noblock`

## Example

Run the included demo:

```bash
moon build --target native example
moon run --target native example
```

Minimal managed-window example:

```moonbit
fn main {
  let win = @webview.Window::new(title="Lepus WebView", width=960, height=640)
  win.set_html("<html><body><h1>Hello from MoonBit</h1></body></html>")
  win.run()
}
```

## Build & Test

```bash
moon check
moon test --target native
moon build --target native
```

## License

Apache-2.0
