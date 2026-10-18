package android.content;

import java.io.File;

/** The part of android.content.Context that extensions use. */
public abstract class Context {
    public static final int MODE_PRIVATE = 0;

    public abstract SharedPreferences getSharedPreferences(String name, int mode);

    public abstract File getFilesDir();

    public abstract File getCacheDir();

    public abstract String getPackageName();

    public Context getApplicationContext() {
        return this;
    }
}
