package android.util;

import java.nio.charset.StandardCharsets;

/** android.util.Base64 on top of java.util.Base64, honouring Android's flags. */
public class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    public static byte[] decode(String str, int flags) {
        return decode(str.getBytes(StandardCharsets.US_ASCII), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        // Android accepts both alphabets' extra characters only for the chosen one, and ignores whitespace.
        StringBuilder clean = new StringBuilder(len);
        for (int i = offset; i < offset + len; i++) {
            char c = (char) (input[i] & 0xff);
            if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
            if ((flags & URL_SAFE) != 0) {
                if (c == '-') c = '+';
                else if (c == '_') c = '/';
            }
            clean.append(c);
        }
        while (clean.length() % 4 != 0) clean.append('=');
        try {
            return java.util.Base64.getDecoder().decode(clean.toString());
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64", e);
        }
    }

    public static String encodeToString(byte[] input, int flags) {
        return new String(encode(input, flags), StandardCharsets.US_ASCII);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        byte[] slice = new byte[len];
        System.arraycopy(input, offset, slice, 0, len);
        java.util.Base64.Encoder encoder = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) encoder = encoder.withoutPadding();
        String encoded = encoder.encodeToString(slice);
        if ((flags & NO_WRAP) == 0) {
            String newline = (flags & CRLF) != 0 ? "\r\n" : "\n";
            StringBuilder wrapped = new StringBuilder(encoded.length() + encoded.length() / 76 + 2);
            for (int i = 0; i < encoded.length(); i += 76) {
                wrapped.append(encoded, i, Math.min(encoded.length(), i + 76)).append(newline);
            }
            encoded = wrapped.toString();
        }
        return encoded.getBytes(StandardCharsets.US_ASCII);
    }
}
