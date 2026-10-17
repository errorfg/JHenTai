package android.net;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** android.net.Uri for hierarchical URIs, with Android's encode/decode rules. */
public abstract class Uri implements Comparable<Uri> {
    public static final Uri EMPTY = new StringUri("");

    private static final String ALLOWED = "_-!.~'()*";

    public static Uri parse(String uriString) {
        return new StringUri(uriString);
    }

    public static String encode(String s) {
        return encode(s, null);
    }

    /** Percent-encodes everything except letters, digits, {@code _-!.~'()*} and {@code allow}. */
    public static String encode(String s, String allow) {
        if (s == null) return null;
        StringBuilder out = new StringBuilder(s.length());
        for (byte b : s.getBytes(StandardCharsets.UTF_8)) {
            char c = (char) (b & 0xff);
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                    || ALLOWED.indexOf(c) >= 0 || (allow != null && c < 0x80 && allow.indexOf(c) >= 0)) {
                out.append(c);
            } else {
                out.append('%').append(Character.toUpperCase(Character.forDigit((b >> 4) & 0xf, 16)))
                        .append(Character.toUpperCase(Character.forDigit(b & 0xf, 16)));
            }
        }
        return out.toString();
    }

    /** Decodes %XX sequences as UTF-8; unlike URLDecoder, '+' stays '+'. */
    public static String decode(String s) {
        if (s == null || s.indexOf('%') < 0) return s;
        StringBuilder out = new StringBuilder(s.length());
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int i = 0;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == '%' && i + 2 < s.length()) {
                int hi = Character.digit(s.charAt(i + 1), 16);
                int lo = Character.digit(s.charAt(i + 2), 16);
                if (hi >= 0 && lo >= 0) {
                    bytes.write((hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
            if (bytes.size() > 0) {
                out.append(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
                bytes.reset();
            }
            out.append(c);
            i++;
        }
        if (bytes.size() > 0) out.append(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
        return out.toString();
    }

    public abstract String getScheme();

    public abstract String getHost();

    public abstract int getPort();

    public abstract String getPath();

    public abstract String getEncodedPath();

    public abstract String getQuery();

    public abstract String getEncodedQuery();

    public abstract String getFragment();

    public abstract List<String> getPathSegments();

    public String getLastPathSegment() {
        List<String> segments = getPathSegments();
        return segments.isEmpty() ? null : segments.get(segments.size() - 1);
    }

    public String getQueryParameter(String key) {
        String query = getEncodedQuery();
        if (query == null) return null;
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            String name = decode(eq >= 0 ? pair.substring(0, eq) : pair);
            if (name.equals(key)) return eq >= 0 ? decode(pair.substring(eq + 1).replace('+', ' ')) : "";
        }
        return null;
    }

    public Builder buildUpon() {
        return new Builder(toString());
    }

    @Override
    public int compareTo(Uri other) {
        return toString().compareTo(other.toString());
    }

    @Override
    public boolean equals(Object o) {
        return o instanceof Uri && toString().equals(o.toString());
    }

    @Override
    public int hashCode() {
        return toString().hashCode();
    }

    private static final class StringUri extends Uri {
        private final String value;
        private URI parsed;

        StringUri(String value) {
            this.value = value;
        }

        private URI uri() {
            if (parsed == null) {
                try {
                    parsed = new URI(value);
                } catch (URISyntaxException e) {
                    try {
                        parsed = new URI(value.replace(" ", "%20"));
                    } catch (URISyntaxException ignored) {
                        parsed = URI.create("");
                    }
                }
            }
            return parsed;
        }

        @Override public String getScheme() { return uri().getScheme(); }
        @Override public String getHost() { return uri().getHost(); }
        @Override public int getPort() { return uri().getPort(); }
        @Override public String getPath() { return uri().getPath(); }
        @Override public String getEncodedPath() { return uri().getRawPath(); }
        @Override public String getQuery() { return uri().getQuery(); }
        @Override public String getEncodedQuery() { return uri().getRawQuery(); }
        @Override public String getFragment() { return uri().getFragment(); }

        @Override
        public List<String> getPathSegments() {
            String path = uri().getRawPath();
            if (path == null || path.isEmpty()) return Collections.emptyList();
            List<String> segments = new ArrayList<>();
            for (String s : path.split("/")) if (!s.isEmpty()) segments.add(decode(s));
            return segments;
        }

        @Override
        public String toString() {
            return value;
        }
    }

    /** Appends path segments and query parameters to an existing URI string. */
    public static final class Builder {
        private String base;
        private final StringBuilder query = new StringBuilder();

        public Builder() {
            this("");
        }

        Builder(String base) {
            int q = base.indexOf('?');
            if (q >= 0) {
                query.append(base.substring(q + 1));
                base = base.substring(0, q);
            }
            this.base = base;
        }

        public Builder scheme(String scheme) {
            base = scheme + ":" + base.replaceFirst("^[a-zA-Z][a-zA-Z0-9+.-]*:", "");
            return this;
        }

        public Builder authority(String authority) {
            String scheme = base.contains(":") ? base.substring(0, base.indexOf(':') + 1) : "";
            base = scheme + "//" + authority;
            return this;
        }

        public Builder appendPath(String segment) {
            return appendEncodedPath(encode(segment));
        }

        public Builder appendEncodedPath(String segment) {
            base = (base.endsWith("/") ? base : base + "/") + segment;
            return this;
        }

        public Builder path(String path) {
            return encodedPath(encode(path, "/"));
        }

        public Builder encodedPath(String path) {
            URI uri = URI.create(base);
            base = (uri.getScheme() != null ? uri.getScheme() + ":" : "") + (uri.getRawAuthority() != null ? "//" + uri.getRawAuthority() : "") + path;
            return this;
        }

        public Builder appendQueryParameter(String key, String value) {
            if (query.length() > 0) query.append('&');
            query.append(encode(key)).append('=').append(encode(value));
            return this;
        }

        public Builder clearQuery() {
            query.setLength(0);
            return this;
        }

        public Uri build() {
            return new StringUri(query.length() > 0 ? base + "?" + query : base);
        }
    }
}
