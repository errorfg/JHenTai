package android.app;

import android.content.Context;
import android.content.SharedPreferences;
import com.gallery.reader.exthost.compat.JsonSharedPreferences;

import java.io.File;
import java.util.HashMap;
import java.util.Map;

/**
 * The application context handed to extensions. Preferences are kept as one
 * JSON file per name under {@code <dataDir>/prefs}.
 */
public class Application extends Context {
    private final File dataDir;
    private final Map<String, JsonSharedPreferences> preferences = new HashMap<>();

    public Application(File dataDir) {
        this.dataDir = dataDir;
    }

    @Override
    public synchronized SharedPreferences getSharedPreferences(String name, int mode) {
        return preferences.computeIfAbsent(name, n -> new JsonSharedPreferences(new File(new File(dataDir, "prefs"), n + ".json")));
    }

    @Override
    public File getFilesDir() {
        File dir = new File(dataDir, "files");
        dir.mkdirs();
        return dir;
    }

    @Override
    public File getCacheDir() {
        File dir = new File(dataDir, "cache");
        dir.mkdirs();
        return dir;
    }

    @Override
    public String getPackageName() {
        return "com.gallery.reader";
    }
}
