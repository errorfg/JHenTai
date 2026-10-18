package com.gallery.reader.exthost.compat;

/**
 * Services the compat classes delegate to. The host fills these in at start-up
 * with its own cookie store and notice channel.
 */
public final class Bridges {
    private Bridges() {
    }

    public interface Cookies {
        /** Cookie header value ("a=1; b=2") for the URL, or null. */
        String get(String url);

        /** Stores one Set-Cookie value for the URL. */
        void set(String url, String setCookie);

        void removeAll();
    }

    public interface Notices {
        void toast(String text);
    }

    public static volatile Cookies cookies = new Cookies() {
        @Override public String get(String url) { return null; }
        @Override public void set(String url, String setCookie) { }
        @Override public void removeAll() { }
    };

    public static volatile Notices notices = text -> System.err.println("Toast: " + text);

    /** Cookie names in a header value, for logging without the values. */
    public static String names(String header) {
        if (header == null) return "";
        StringBuilder out = new StringBuilder();
        for (String part : header.split(";")) {
            int eq = part.indexOf('=');
            if (out.length() > 0) out.append(',');
            out.append((eq >= 0 ? part.substring(0, eq) : part).trim());
        }
        return out.toString();
    }
}
