package android.webkit;

import android.graphics.Bitmap;

public class WebViewClient {
    public static final int ERROR_UNKNOWN = -1;
    public static final int ERROR_HOST_LOOKUP = -2;
    public static final int ERROR_CONNECT = -6;
    public static final int ERROR_IO = -7;
    public static final int ERROR_TIMEOUT = -8;
    public static final int ERROR_REDIRECT_LOOP = -9;
    public static final int ERROR_UNSUPPORTED_SCHEME = -10;
    public static final int ERROR_FAILED_SSL_HANDSHAKE = -11;
    public static final int ERROR_BAD_URL = -12;

    public boolean shouldOverrideUrlLoading(WebView view, String url) { return false; }
    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) { return shouldOverrideUrlLoading(view, request.getUrl().toString()); }
    public void onPageStarted(WebView view, String url, Bitmap favicon) { }
    public void onPageFinished(WebView view, String url) { }
    public void onLoadResource(WebView view, String url) { }
    public WebResourceResponse shouldInterceptRequest(WebView view, String url) { return null; }
    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) { return shouldInterceptRequest(view, request.getUrl().toString()); }
    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) { }

    /** As on Android: errors of the main frame also reach the older callback. */
    public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
        if (request.isForMainFrame()) {
            onReceivedError(view, error.getErrorCode(), String.valueOf(error.getDescription()), request.getUrl().toString());
        }
    }

    public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse errorResponse) { }
}
