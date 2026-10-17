package androidx.preference;

import android.content.Context;

import java.util.ArrayList;
import java.util.List;

public abstract class PreferenceGroup extends Preference {
    private final List<Preference> preferences = new ArrayList<>();

    public PreferenceGroup(Context context) {
        super(context);
    }

    public boolean addPreference(Preference preference) {
        preferences.add(preference);
        preference.attach(getSharedPreferences());
        return true;
    }

    @Override
    void attach(android.content.SharedPreferences sharedPreferences) {
        super.attach(sharedPreferences);
        for (Preference preference : preferences) preference.attach(sharedPreferences);
    }

    public boolean removePreference(Preference preference) {
        return preferences.remove(preference);
    }

    public void removeAll() {
        preferences.clear();
    }

    public int getPreferenceCount() {
        return preferences.size();
    }

    public Preference getPreference(int index) {
        return preferences.get(index);
    }

    @SuppressWarnings("unchecked")
    public <T extends Preference> T findPreference(CharSequence key) {
        for (Preference preference : preferences) {
            if (key.toString().equals(preference.getKey())) return (T) preference;
            if (preference instanceof PreferenceGroup) {
                T found = ((PreferenceGroup) preference).findPreference(key);
                if (found != null) return found;
            }
        }
        return null;
    }
}
