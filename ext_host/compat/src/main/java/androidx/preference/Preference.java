package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * The preference model extensions build in setupPreferenceScreen. The host
 * reads it to show the settings and writes values through the same calls the
 * Android preference screen would make.
 */
public class Preference {
    public interface OnPreferenceChangeListener {
        boolean onPreferenceChange(Preference preference, Object newValue);
    }

    public interface OnPreferenceClickListener {
        boolean onPreferenceClick(Preference preference);
    }

    public interface SummaryProvider<T extends Preference> {
        CharSequence provideSummary(T preference);
    }

    private final Context context;
    private SharedPreferences sharedPreferences;
    private String key;
    private CharSequence title;
    private CharSequence summary;
    private Object defaultValue;
    private boolean visible = true;
    private boolean enabled = true;
    private boolean persistent = true;
    private int order = Integer.MAX_VALUE;
    private OnPreferenceChangeListener changeListener;
    private OnPreferenceClickListener clickListener;
    private SummaryProvider<Preference> summaryProvider;

    public Preference(Context context) {
        this.context = context;
    }

    public Context getContext() { return context; }

    public String getKey() { return key; }
    public void setKey(String key) { this.key = key; }
    public boolean hasKey() { return key != null && !key.isEmpty(); }

    public CharSequence getTitle() { return title; }
    public void setTitle(CharSequence title) { this.title = title; }
    public void setTitle(int titleResId) { }

    @SuppressWarnings("unchecked")
    public CharSequence getSummary() {
        return summaryProvider != null ? summaryProvider.provideSummary(this) : summary;
    }
    public void setSummary(CharSequence summary) { this.summary = summary; }
    public void setSummary(int summaryResId) { }

    @SuppressWarnings("unchecked")
    public final void setSummaryProvider(SummaryProvider<? extends Preference> provider) { this.summaryProvider = (SummaryProvider<Preference>) provider; }
    @SuppressWarnings("unchecked")
    public final <T extends Preference> SummaryProvider<T> getSummaryProvider() { return (SummaryProvider<T>) summaryProvider; }

    public void setDefaultValue(Object defaultValue) { this.defaultValue = defaultValue; }
    public Object getDefaultValue() { return defaultValue; }

    public final boolean isVisible() { return visible; }
    public final void setVisible(boolean visible) { this.visible = visible; }
    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public boolean isPersistent() { return persistent; }
    public void setPersistent(boolean persistent) { this.persistent = persistent; }
    public int getOrder() { return order; }
    public void setOrder(int order) { this.order = order; }
    public void setIconSpaceReserved(boolean reserved) { }
    public void setSingleLineTitle(boolean singleLineTitle) { }
    public void setDependency(String dependencyKey) { }

    public void setOnPreferenceChangeListener(OnPreferenceChangeListener listener) { this.changeListener = listener; }
    public OnPreferenceChangeListener getOnPreferenceChangeListener() { return changeListener; }
    public void setOnPreferenceClickListener(OnPreferenceClickListener listener) { this.clickListener = listener; }
    public OnPreferenceClickListener getOnPreferenceClickListener() { return clickListener; }

    /** Asks the extension whether to accept a value the user entered. */
    public boolean callChangeListener(Object newValue) {
        return changeListener == null || changeListener.onPreferenceChange(this, newValue);
    }

    public SharedPreferences getSharedPreferences() { return sharedPreferences; }

    /** Called when the preference joins a screen: it starts reading and writing that screen's preferences. */
    void attach(SharedPreferences sharedPreferences) {
        this.sharedPreferences = sharedPreferences;
        onSetInitialValue(defaultValue);
    }

    protected void onSetInitialValue(Object defaultValue) { }

    protected boolean shouldPersist() { return sharedPreferences != null && persistent && hasKey(); }

    protected String getPersistedString(String defaultReturnValue) {
        return shouldPersist() ? sharedPreferences.getString(key, defaultReturnValue) : defaultReturnValue;
    }

    protected boolean persistString(String value) {
        if (!shouldPersist()) return false;
        sharedPreferences.edit().putString(key, value).apply();
        return true;
    }

    protected boolean getPersistedBoolean(boolean defaultReturnValue) {
        return shouldPersist() ? sharedPreferences.getBoolean(key, defaultReturnValue) : defaultReturnValue;
    }

    protected boolean persistBoolean(boolean value) {
        if (!shouldPersist()) return false;
        sharedPreferences.edit().putBoolean(key, value).apply();
        return true;
    }

    protected java.util.Set<String> getPersistedStringSet(java.util.Set<String> defaultReturnValue) {
        return shouldPersist() ? sharedPreferences.getStringSet(key, defaultReturnValue) : defaultReturnValue;
    }

    protected boolean persistStringSet(java.util.Set<String> values) {
        if (!shouldPersist()) return false;
        sharedPreferences.edit().putStringSet(key, values).apply();
        return true;
    }

    protected void notifyChanged() { }

    @Override
    public String toString() {
        return getClass().getSimpleName() + "(" + key + ")";
    }
}
