package android.view;

import android.content.Context;

public class View {
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;

    private final Context context;
    private int visibility = VISIBLE;

    public View(Context context) {
        this.context = context;
    }

    public Context getContext() { return context; }
    public void setVisibility(int visibility) { this.visibility = visibility; }
    public int getVisibility() { return visibility; }
    public void setEnabled(boolean enabled) { }
    public boolean post(Runnable action) { return new android.os.Handler().post(action); }
}
