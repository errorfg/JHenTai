package android.os;

/** Reported as an Android 11 phone, the level Tachiyomi extensions are tested against. */
public class Build {
    public static final String BRAND = "generic";
    public static final String DEVICE = "generic";
    public static final String MANUFACTURER = "generic";
    public static final String MODEL = "Generic";
    public static final String PRODUCT = "generic";
    public static final String[] SUPPORTED_ABIS = {"arm64-v8a"};

    public static class VERSION {
        public static final int SDK_INT = 30;
        public static final String RELEASE = "11";
        public static final String CODENAME = "REL";
    }

    public static class VERSION_CODES {
        public static final int LOLLIPOP = 21;
        public static final int M = 23;
        public static final int N = 24;
        public static final int O = 26;
        public static final int P = 28;
        public static final int Q = 29;
        public static final int R = 30;
        public static final int S = 31;
        public static final int TIRAMISU = 33;
    }
}
