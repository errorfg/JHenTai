package android.os;

public final class SystemClock {
    private SystemClock() {
    }

    public static long elapsedRealtime() {
        return System.nanoTime() / 1_000_000;
    }

    public static long uptimeMillis() {
        return elapsedRealtime();
    }

    public static long currentThreadTimeMillis() {
        return elapsedRealtime();
    }

    public static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
