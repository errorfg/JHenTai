package android.webkit;

import com.gallery.reader.exthost.compat.Bridges;

/** Backed by the host's cookie store, the same one OkHttp uses. */
public class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();
    private volatile boolean accept = true;

    public static CookieManager getInstance() {
        return INSTANCE;
    }

    public void setAcceptCookie(boolean accept) {
        this.accept = accept;
    }

    public boolean acceptCookie() {
        return accept;
    }

    public void setAcceptThirdPartyCookies(WebView webview, boolean accept) {
    }

    public boolean acceptThirdPartyCookies(WebView webview) {
        return true;
    }

    public String getCookie(String url) {
        return Bridges.cookies.get(url);
    }

    public void setCookie(String url, String value) {
        if (accept) Bridges.cookies.set(url, value);
    }

    public void setCookie(String url, String value, ValueCallback<Boolean> callback) {
        setCookie(url, value);
        if (callback != null) callback.onReceiveValue(accept);
    }

    public void removeAllCookies(ValueCallback<Boolean> callback) {
        Bridges.cookies.removeAll();
        if (callback != null) callback.onReceiveValue(true);
    }

    public void removeAllCookie() {
        Bridges.cookies.removeAll();
    }

    public void removeSessionCookies(ValueCallback<Boolean> callback) {
        if (callback != null) callback.onReceiveValue(true);
    }

    public boolean hasCookies() {
        return true;
    }

    public void flush() {
    }
}
