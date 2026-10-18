package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;

public final class PreferenceScreen extends PreferenceGroup {
    /** A screen whose preferences are stored in {@code sharedPreferences}. */
    public PreferenceScreen(Context context, SharedPreferences sharedPreferences) {
        super(context);
        attach(sharedPreferences);
    }
}
