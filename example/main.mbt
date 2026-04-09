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
fn main {
  let window = @webview.Window::new(
    title="title",
    width=800,
    height=600,
    frameless=true,
    title_bar_style=Hidden,
    title_bar_overlay=true,
    devtools=true,
    debug=1,
  )
  window.install(
    @webview.Plugin::new("math", plugin => {
      plugin.command("sum", (payload : SumPayload) => SumReply::{
        total: payload.left + payload.right,
      })
      plugin.command("sum_async", sum_async_handler)
    }),
  )
  window.install(
    @webview.Plugin::new("console", plugin => {
      plugin.command("log", (payload : Json) => {
        println("[child-console:log] \{payload.stringify()}")
        payload
      })
      plugin.command("error", (payload : Json) => {
        println("[child-console:error] \{payload.stringify()}")
        payload
      })
    }),
  )
  // window.navigate("https://www.example.com")

  window.set_html(
    (
      #|<style>
      #|  body { margin: 0; font-family: sans-serif; background: #f5f6fb; }
      #|  .titlebar {
      #|    height: 40px;
      #|    display: flex;
      #|    align-items: center;
      #|    justify-content: space-between;
      #|    padding: 0 0 0 96px;
      #|    color: #1f2937;
      #|    border-bottom: 1px solid #d1d5db;
      #|    -webkit-app-region: drag;
      #|    user-select: none;
      #|    --webkit-user-select: none;
      #|  }
      #|  .content { padding: 16px; }
      #|</style>
      #|<div class="titlebar lepus-titlebar">
      #|  <div>Custom Title Bar</div>
      #|  <button class="lepus-no-drag" onclick="window.close()">Close</button>
      #|</div>
      #|<div class="content">
      #|  <p>Hello Lepus</p>
      #|  <button id="sum-btn">Sum 2 + 3</button>
      #|  <p id="sum-result">Result: </p>
      #|</div>
      #|<script>
      #|  window.lepusApi.math.sum({ left: 1, right: 1 });
      #|  window.lepusApi.math.sum_async({ left: 10, right: 20 });
      #|  document.getElementById("sum-btn").addEventListener("click", async () => {
      #|    try {
      #|      document.getElementById("sum-result").textContent = "Calculating..."
      #|      const result = await window.lepusApi.math.sum_async({ left: 2, right: 3 });
      #|      window.lepusApi.console.log("[example] sum result: ", JSON.stringify(result));
      #|      document.getElementById("sum-result").textContent = "Result: " + result.total;
      #|    } catch(e) {
      #|      window.lepusApi.console.error("[example] sum error: ", e.message);
      #|      document.getElementById("sum-result").textContent = "Error: " + e.message;
      #|    }
      #|  });
      #|</script>
    ),
  )
  window.run()
}

///|
async test {
  let payload = SumPayload::{ left: 2, right: 3 }
  json_inspect(sum_async_handler(payload), content={ "total": 5 })
}
