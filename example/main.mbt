///|
fn main {
  let webview = @webview.WebView::new()
  webview.set_title("title")
  webview.set_size(800, 600, @webview.SizeHint::None)
  webview.set_html("Hello Lepus")
  webview.run()
}
