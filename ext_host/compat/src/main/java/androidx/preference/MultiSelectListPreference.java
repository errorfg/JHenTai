package androidx.preference;

import android.content.Context;

import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Set;

public class MultiSelectListPreference extends DialogPreference {
    private CharSequence[] entries = new CharSequence[0];
    private CharSequence[] entryValues = new CharSequence[0];
    private final Set<String> values = new LinkedHashSet<>();

    public MultiSelectListPreference(Context context) {
        super(context);
    }

    public CharSequence[] getEntries() { return entries; }
    public void setEntries(CharSequence[] entries) { this.entries = entries; }
    public CharSequence[] getEntryValues() { return entryValues; }
    public void setEntryValues(CharSequence[] entryValues) { this.entryValues = entryValues; }

    public Set<String> getValues() { return values; }

    public void setValues(Set<String> values) {
        this.values.clear();
        if (values != null) this.values.addAll(values);
        persistStringSet(new HashSet<>(this.values));
    }

    public int findIndexOfValue(String value) {
        if (value != null && entryValues != null) {
            for (int i = entryValues.length - 1; i >= 0; i--) if (entryValues[i].toString().equals(value)) return i;
        }
        return -1;
    }

    @Override
    @SuppressWarnings("unchecked")
    protected void onSetInitialValue(Object defaultValue) {
        setValues(getPersistedStringSet(defaultValue instanceof Set ? (Set<String>) defaultValue : new HashSet<>()));
    }
}
