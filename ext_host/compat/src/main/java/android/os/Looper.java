package android.os;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;

/**
 * Extensions post work to the main looper (usually to drive a WebView). The
 * host has no UI thread, so the "main" looper is one daemon thread.
 */
public final class Looper {
    private static final Looper MAIN = new Looper("main");

    final ScheduledExecutorService executor;
    private volatile Thread thread;

    private Looper(String name) {
        executor = Executors.newSingleThreadScheduledExecutor(runnable -> {
            Thread t = new Thread(runnable, name);
            t.setDaemon(true);
            thread = t;
            return t;
        });
    }

    public static Looper getMainLooper() {
        return MAIN;
    }

    public static Looper myLooper() {
        return Thread.currentThread() == MAIN.thread ? MAIN : null;
    }

    public static void prepare() {
    }

    public static void loop() {
    }

    public Thread getThread() {
        return thread;
    }

    public boolean isCurrentThread() {
        return Thread.currentThread() == thread;
    }
}
