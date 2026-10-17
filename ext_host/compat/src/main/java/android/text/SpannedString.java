package android.text;

public final class SpannedString implements Spanned {
    private final String text;

    public SpannedString(CharSequence text) {
        this.text = text.toString();
    }

    @Override public int length() { return text.length(); }
    @Override public char charAt(int index) { return text.charAt(index); }
    @Override public CharSequence subSequence(int start, int end) { return text.subSequence(start, end); }
    @Override public String toString() { return text; }
}
