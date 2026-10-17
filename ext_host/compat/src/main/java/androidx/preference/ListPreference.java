package androidx.preference;

import android.content.Context;

public class ListPreference extends DialogPreference {
    private CharSequence[] entries = new CharSequence[0];
    private CharSequence[] entryValues = new CharSequence[0];
    private String value;

    public ListPreference(Context context) {
        super(context);
    }

    public CharSequence[] getEntries() { return entries; }
    public void setEntries(CharSequence[] entries) { this.entries = entries; }
    public void setEntries(int entriesResId) { }
    public CharSequence[] getEntryValues() { return entryValues; }
    public void setEntryValues(CharSequence[] entryValues) { this.entryValues = entryValues; }
    public void setEntryValues(int entryValuesResId) { }

    public String getValue() { return value; }

    public void setValue(String value) {
        this.value = value;
        persistString(value);
    }

    public void setValueIndex(int index) {
        if (entryValues != null && index >= 0 && index < entryValues.length) setValue(entryValues[index].toString());
    }

    public int findIndexOfValue(String value) {
        if (value != null && entryValues != null) {
            for (int i = entryValues.length - 1; i >= 0; i--) if (entryValues[i].toString().equals(value)) return i;
        }
        return -1;
    }

    public CharSequence getEntry() {
        int index = findIndexOfValue(value);
        return index >= 0 && entries != null && index < entries.length ? entries[index] : null;
    }

    @Override
    public CharSequence getSummary() {
        CharSequence summary = super.getSummary();
        if (summary == null || getSummaryProvider() != null) return summary;
        CharSequence entry = getEntry();
        String formatted = summary.toString().contains("%s") ? String.format(summary.toString(), entry == null ? "" : entry) : summary.toString();
        return formatted;
    }

    @Override
    protected void onSetInitialValue(Object defaultValue) {
        setValue(getPersistedString(defaultValue != null ? defaultValue.toString() : null));
    }
}
