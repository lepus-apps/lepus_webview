///|
struct SumPayload {
  left : Int
  right : Int
} derive(ToJson, FromJson)

///|
struct SumReply {
  total : Int
} derive(ToJson, FromJson)

///|
async fn sum_async_handler(payload : SumPayload) -> SumReply {
  @async.sleep(100) // Simulate async work
  SumReply::{ total: payload.left + payload.right }
}

///|
async fn main {
  @async.with_task_group(task_group => {
    task_group.spawn_bg(() => {
      let webview = @webview.WebView::new_managed(
        task_group,
        title="title",
        width=800,
        height=600,
        debug=1,
      )
      let host = @webview.PluginHost::new(webview)
      host.install(
        @webview.Plugin::new("math", plugin => {
          // Synchronous handler
          plugin.command("sum", (payload : SumPayload) => SumReply::{
            total: payload.left + payload.right,
          })
          // Async handler with delay to test non-blocking behavior
          plugin.command_async("sum_async", sum_async_handler)
        }),
      )
      host.install(
        @webview.Plugin::new("console", plugin => {
          plugin.command("log", (payload : String) => payload)
          plugin.command("error", (payload : String) => payload)
        }),
      )
      webview.set_html(
        (
          #|<p>Hello Lepus</p>
          #|<button id="sum-btn">Sum 2 + 3</button>
          #|<p id="sum-result">Result: </p>
          #|<script>
          #|  window.MoonBitPlugins.math.sum({ left: 1, right: 1 });
          #|  window.MoonBitPlugins.math.sum_async({ left: 10, right: 20 });
          #|  document.getElementById("sum-btn").addEventListener("click", async () => {
          #|    try {
          #|      document.getElementById("sum-result").textContent = "Calculating..."
          #|      const result = await window.MoonBitPlugins.math.sum({ left: 2, right: 3 });
          #|      window.MoonBitPlugins.console.log("[example] sum result:", JSON.stringify(result));
          #|      document.getElementById("sum-result").textContent = "Result: " + result.total;
          #|    } catch(e) {
          #|      window.MoonBitPlugins.console.error("[example] sum error:", e);
          #|      document.getElementById("sum-result").textContent = "Error: " + e.message;
          #|    }
          #|  });
          #|</script>
        ),
      )
      webview.run()
    })
  })
}
