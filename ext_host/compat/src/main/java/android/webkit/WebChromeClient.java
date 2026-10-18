package android.webkit;

public class WebChromeClient {
    public void onProgressChanged(WebView view, int newProgress) { }
    public void onReceivedTitle(WebView view, String title) { }
    public boolean onConsoleMessage(ConsoleMessage consoleMessage) { return false; }
}
