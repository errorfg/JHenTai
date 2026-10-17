package android.widget;

import android.content.Context;
import com.gallery.reader.exthost.compat.Bridges;

/** Shown in the app as a notice. */
public class Toast {
    public static final int LENGTH_SHORT = 0;
    public static final int LENGTH_LONG = 1;

    private CharSequence text;

    public static Toast makeText(Context context, CharSequence text, int duration) {
        Toast toast = new Toast();
        toast.text = text;
        return toast;
    }

    public static Toast makeText(Context context, int resId, int duration) {
        return makeText(context, "", duration);
    }

    public void setText(CharSequence text) {
        this.text = text;
    }

    public void show() {
        if (text != null && text.length() > 0) Bridges.notices.toast(text.toString());
    }

    public void cancel() {
    }
}
