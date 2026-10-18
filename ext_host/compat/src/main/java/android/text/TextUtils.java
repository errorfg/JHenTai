package android.text;

public class TextUtils {
    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }

    public static boolean isDigitsOnly(CharSequence str) {
        for (int i = 0; i < str.length(); i++) if (!Character.isDigit(str.charAt(i))) return false;
        return true;
    }

    public static String join(CharSequence delimiter, Iterable<?> tokens) {
        StringBuilder out = new StringBuilder();
        for (Object token : tokens) {
            if (out.length() > 0) out.append(delimiter);
            out.append(token);
        }
        return out.toString();
    }

    public static String join(CharSequence delimiter, Object[] tokens) {
        return join(delimiter, java.util.Arrays.asList(tokens));
    }

    public static boolean equals(CharSequence a, CharSequence b) {
        return a == b || (a != null && b != null && a.toString().equals(b.toString()));
    }
}
