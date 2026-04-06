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
async fn main {
  @async.with_task_group(task_group => {
    task_group.spawn_bg(() => {
      @webview.WebView::new(task_group)
      ..set_title("title")
      ..set_size(800, 600, @webview.SizeHint::None)
      ..install_plugin(
        @webview.Plugin::new("math", plugin => {
          plugin.command("sum", (payload : SumPayload) => SumReply::{
            total: payload.left + payload.right,
          })
          plugin.command_async("sumAsync", (payload : SumPayload) => {
            @async.sleep(1000)
            SumReply::{ total: payload.left + payload.right }
          })
        }),
      )
      ..set_html(
        (
          #|<p>Hello Lepus</p>
          #|<button id="sum-btn">Sum 2 + 3</button>
          #|<button id="sum-async-btn">Sum 2 + 3 Async</button>
          #|<p id="sum-result">Result: </p>
          #|<script>
          #|  document.getElementById("sum-btn").addEventListener("click", async () => {
          #|    try {
          #|      document.getElementById("sum-result").textContent = "Calculating..."
          #|      const result = await window.MoonBitPlugins.math.sum({ left: 2, right: 3 });
          #|      console.log("[example] sum result:", JSON.stringify(result));
          #|      document.getElementById("sum-result").textContent = "Result: " + result.total;
          #|    } catch(e) {
          #|      console.error("[example] sum error:", e);
          #|      document.getElementById("sum-result").textContent = "Error: " + e.message;
          #|    }
          #|  });
          #|  document.getElementById("sum-async-btn").addEventListener("click", async () => {
          #|    try {
          #|      document.getElementById("sum-result").textContent = "Calculating..."
          #|      const result = await window.MoonBitPlugins.math.sumAsync({ left: 2, right: 3 });
          #|      console.log("[example] sumAsync result:", JSON.stringify(result));
          #|      document.getElementById("sum-result").textContent = "Result: " + result.total;
          #|    } catch(e) {
          #|      console.error("[example] sumAsync error:", e);
          #|      document.getElementById("sum-result").textContent = "Error: " + e.message;
          #|    }
          #|  });
          #|</script>
        ),
      )
      .run()
    })
  })
}
