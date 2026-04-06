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
fn main {
  @webview.WebView::new()
  ..set_title("title")
  ..set_size(800, 600, @webview.SizeHint::None)
  ..install_plugin(
    @webview.Plugin::new("math", plugin => {
      plugin.command("sum", (payload : SumPayload) => SumReply::{
        total: payload.left + payload.right,
      })
    }),
  )
  ..set_html(
    (
      #|<p>Hello Lepus</p>
      #|<button id="sum-btn">Sum 2 + 3</button>
      #|<p id="sum-result">Result: </p>
      #|<script>
      #|  document.getElementById("sum-btn").addEventListener("click", async () => {
      #|    const { payload } = await window.MoonBitPlugins.math.sum({ left: 2, right: 3 });
      #|    document.getElementById("sum-result").textContent = "Result: " + payload.total;
      #|  });
      #|</script>
    ),
  )
  .run()
}
