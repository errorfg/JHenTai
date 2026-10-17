package android.webkit;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;

import java.util.Collections;
import java.util.Map;

/**
 * There is no browser engine in this host yet. Loading a page reports an error
 * to the WebViewClient right away, so an extension waiting on the page fails
 * instead of waiting for its own timeout.
 */
public class WebView extends ViewGroup {
    private final WebSettings settings = new WebSettings();
    private WebViewClient client = new WebViewClient();
    private WebChromeClient chromeClient;
    private String url;

    public WebView(Context context) {
        super(context);
    }

    public WebSettings getSettings() { return settings; }
    public void setWebViewClient(WebViewClient client) { this.client = client; }
    public WebViewClient getWebViewClient() { return client; }
    public void setWebChromeClient(WebChromeClient client) { this.chromeClient = client; }
    public void addJavascriptInterface(Object object, String name) { }
    public void removeJavascriptInterface(String name) { }
    public String getUrl() { return url; }
    public String getOriginalUrl() { return url; }

    public void loadUrl(String url) {
        loadUrl(url, Collections.emptyMap());
    }

    public void loadUrl(String url, Map<String, String> additionalHttpHeaders) {
        this.url = url;
        System.err.println("WebView: no browser engine in this host; failing " + url);
        WebView view = this;
        new Handler(Looper.getMainLooper()).post(() -> client.onReceivedError(view, new Request(url), new Error()));
    }

    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType, String encoding, String historyUrl) {
        loadUrl(baseUrl != null ? baseUrl : "about:blank");
    }

    public void loadData(String data, String mimeType, String encoding) {
        loadUrl("about:blank");
    }

    public void evaluateJavascript(String script, ValueCallback<String> resultCallback) {
        if (resultCallback != null) new Handler(Looper.getMainLooper()).post(() -> resultCallback.onReceiveValue(null));
    }

    public void stopLoading() { }
    public void reload() { }
    public void destroy() { }
    public void onPause() { }
    public void onResume() { }
    public void clearCache(boolean includeDiskFiles) { }
    public void clearHistory() { }

    private static final class Request implements WebResourceRequest {
        private final String url;

        Request(String url) { this.url = url; }

        @Override public Uri getUrl() { return Uri.parse(url); }
        @Override public boolean isForMainFrame() { return true; }
        @Override public boolean isRedirect() { return false; }
        @Override public boolean hasGesture() { return false; }
        @Override public String getMethod() { return "GET"; }
        @Override public Map<String, String> getRequestHeaders() { return Collections.emptyMap(); }
    }

    private static final class Error extends WebResourceError {
        @Override public int getErrorCode() { return WebViewClient.ERROR_UNKNOWN; }
        @Override public CharSequence getDescription() { return "WebView is not available in this host"; }
    }
}
