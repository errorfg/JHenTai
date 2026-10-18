package android.webkit;

import android.content.Context;
import android.view.ViewGroup;

import com.gallery.reader.exthost.compat.WebViewSession;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Collections;
import java.util.Map;

/**
 * A WebView drawn from the app's browser engine (WKWebView on iOS and macOS);
 * see WebViewSession. Where the app lends no engine, loading a page reports
 * an error to the WebViewClient right away, so an extension waiting on the
 * page fails instead of waiting for its own timeout.
 */
public class WebView extends ViewGroup {
    private final WebSettings settings = new WebSettings();
    private final WebViewSession session = new WebViewSession(this);
    private WebViewClient client = new WebViewClient();
    private WebChromeClient chromeClient;

    public WebView(Context context) {
        super(context);
    }

    public static void setWebContentsDebuggingEnabled(boolean enabled) { }

    public WebSettings getSettings() { return settings; }
    public void setWebViewClient(WebViewClient client) { this.client = client != null ? client : new WebViewClient(); }
    public WebViewClient getWebViewClient() { return client; }
    public void setWebChromeClient(WebChromeClient client) { this.chromeClient = client; }
    public WebChromeClient getWebChromeClient() { return chromeClient; }
    public void addJavascriptInterface(Object object, String name) { session.addInterface(object, name); }
    public void removeJavascriptInterface(String name) { session.removeInterface(name); }
    public String getUrl() { return session.getUrl(); }
    public String getOriginalUrl() { return session.getUrl(); }
    public String getTitle() { return session.getTitle(); }
    public int getProgress() { return session.getProgress(); }

    public void loadUrl(String url) {
        loadUrl(url, Collections.emptyMap());
    }

    public void loadUrl(String url, Map<String, String> additionalHttpHeaders) {
        session.load(url, additionalHttpHeaders != null ? additionalHttpHeaders : Collections.emptyMap());
    }

    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType, String encoding, String historyUrl) {
        session.loadHtml(data != null ? data : "", baseUrl);
    }

    public void loadData(String data, String mimeType, String encoding) {
        String html = data != null ? data : "";
        if ("base64".equalsIgnoreCase(encoding)) {
            html = new String(Base64.getDecoder().decode(html), StandardCharsets.UTF_8);
        }
        session.loadHtml(html, null);
    }

    public void evaluateJavascript(String script, ValueCallback<String> resultCallback) {
        session.evaluate(script, resultCallback);
    }

    public void reload() {
        String url = session.getUrl();
        if (url != null) loadUrl(url);
    }

    public boolean canGoBack() { return false; }
    public void goBack() { evaluateJavascript("history.back()", null); }
    public void stopLoading() { session.stop(); }
    public void destroy() { session.destroy(); }
    public void onPause() { }
    public void onResume() { }
    public void pauseTimers() { }
    public void resumeTimers() { }
    public void clearCache(boolean includeDiskFiles) { }
    public void clearHistory() { }
    public void clearFormData() { }
}
