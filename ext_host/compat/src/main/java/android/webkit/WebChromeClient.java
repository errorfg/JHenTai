package android.webkit;

public class WebChromeClient {
    public void onProgressChanged(WebView view, int newProgress) { }
    public boolean onConsoleMessage(ConsoleMessage consoleMessage) { return false; }
}
