package android.webkit;

/** What the engine takes from these: the user agent and whether JavaScript runs; the rest is kept or ignored. */
public class WebSettings {
    public static final int LOAD_DEFAULT = -1;
    public static final int LOAD_CACHE_ELSE_NETWORK = 1;
    public static final int LOAD_NO_CACHE = 2;
    public static final int LOAD_CACHE_ONLY = 3;
    public static final int MIXED_CONTENT_ALWAYS_ALLOW = 0;
    public static final int MIXED_CONTENT_NEVER_ALLOW = 1;
    public static final int MIXED_CONTENT_COMPATIBILITY_MODE = 2;

    private boolean javaScriptEnabled;
    private boolean domStorageEnabled;
    private int cacheMode = LOAD_DEFAULT;
    private static final String DEFAULT_USER_AGENT = "Mozilla/5.0 (Linux; Android 11; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";
    private String userAgent = DEFAULT_USER_AGENT;

    public static String getDefaultUserAgent(android.content.Context context) {
        return DEFAULT_USER_AGENT;
    }

    public void setJavaScriptEnabled(boolean flag) { javaScriptEnabled = flag; }
    public boolean getJavaScriptEnabled() { return javaScriptEnabled; }
    public void setDomStorageEnabled(boolean flag) { domStorageEnabled = flag; }
    public boolean getDomStorageEnabled() { return domStorageEnabled; }
    public void setDatabaseEnabled(boolean flag) { }
    public void setLoadsImagesAutomatically(boolean flag) { }
    public void setBlockNetworkImage(boolean flag) { }
    public void setBlockNetworkLoads(boolean flag) { }
    public void setCacheMode(int mode) { cacheMode = mode; }
    public int getCacheMode() { return cacheMode; }
    public void setUseWideViewPort(boolean use) { }
    public void setLoadWithOverviewMode(boolean overview) { }
    public void setJavaScriptCanOpenWindowsAutomatically(boolean flag) { }
    public void setSupportMultipleWindows(boolean support) { }
    public void setMixedContentMode(int mode) { }
    public void setMediaPlaybackRequiresUserGesture(boolean require) { }
    public void setAllowFileAccess(boolean allow) { }
    public void setAllowContentAccess(boolean allow) { }
    public void setSupportZoom(boolean support) { }
    public void setBuiltInZoomControls(boolean enabled) { }
    public void setDisplayZoomControls(boolean enabled) { }
    public void setUserAgentString(String ua) { userAgent = ua == null || ua.isEmpty() ? DEFAULT_USER_AGENT : ua; }
    public String getUserAgentString() { return userAgent; }
}
