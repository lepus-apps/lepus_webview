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
  @async.sleep(1000)
  SumReply::{ total: payload.left + payload.right }
}

///|
async test {
  let payload = SumPayload::{ left: 2, right: 3 }
  json_inspect(sum_async_handler(payload), content={ "total": 5 })
}

///|
fn main {
  let window = @webview.Window::new(title="title", width=800, height=600)
  window.install(
    @webview.Plugin::new("math", plugin => {
      plugin.command("sum", (payload : SumPayload) => SumReply::{
        total: payload.left + payload.right,
      })
      plugin.command_async("sum_async", sum_async_handler)
    }),
  )
  window.install(
    @webview.Plugin::new("console", plugin => {
      plugin.command("log", (payload : String) => {
        println("[child-console:log] \{payload}")
        payload
      })
      plugin.command("error", (payload : String) => {
        println("[child-console:error] \{payload}")
        payload
      })
    }),
  )
  window.set_html(
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
      #|      const result = await window.MoonBitPlugins.math.sum_async({ left: 2, right: 3 });
      #|      window.MoonBitPlugins.console.log("[example] sum result: " + JSON.stringify(result));
      #|      document.getElementById("sum-result").textContent = "Result: " + result.Ok.total;
      #|    } catch(e) {
      #|      window.MoonBitPlugins.console.error("[example] sum error: " + e.message);
      #|      document.getElementById("sum-result").textContent = "Error: " + e.message;
      #|    }
      #|  });
      #|</script>
    ),
  )
  window.run()
}
