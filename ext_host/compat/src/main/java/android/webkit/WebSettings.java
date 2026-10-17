package android.webkit;

public class WebSettings {
    public static final int LOAD_DEFAULT = -1;
    public static final int LOAD_NO_CACHE = 2;

    private boolean javaScriptEnabled;
    private String userAgent = "Mozilla/5.0 (Linux; Android 11; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";

    public static String getDefaultUserAgent(android.content.Context context) {
        return new WebSettings().getUserAgentString();
    }

    public void setJavaScriptEnabled(boolean flag) { javaScriptEnabled = flag; }
    public boolean getJavaScriptEnabled() { return javaScriptEnabled; }
    public void setDomStorageEnabled(boolean flag) { }
    public void setDatabaseEnabled(boolean flag) { }
    public void setLoadsImagesAutomatically(boolean flag) { }
    public void setBlockNetworkImage(boolean flag) { }
    public void setBlockNetworkLoads(boolean flag) { }
    public void setCacheMode(int mode) { }
    public void setUseWideViewPort(boolean use) { }
    public void setLoadWithOverviewMode(boolean overview) { }
    public void setJavaScriptCanOpenWindowsAutomatically(boolean flag) { }
    public void setUserAgentString(String ua) { if (ua != null) userAgent = ua; }
    public String getUserAgentString() { return userAgent; }
}
