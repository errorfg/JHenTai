package android.os;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

public class Handler {
    private final Looper looper;
    private final Map<Runnable, ScheduledFuture<?>> pending = new ConcurrentHashMap<>();

    public Handler() {
        this(Looper.getMainLooper());
    }

    public Handler(Looper looper) {
        this.looper = looper;
    }

    public final Looper getLooper() {
        return looper;
    }

    public final boolean post(Runnable r) {
        return postDelayed(r, 0);
    }

    public final boolean postDelayed(Runnable r, long delayMillis) {
        ScheduledFuture<?> future = looper.executor.schedule(() -> {
            pending.remove(r);
            try {
                r.run();
            } catch (Throwable t) {
                System.err.println("Handler: task failed: " + t);
                t.printStackTrace();
            }
        }, Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
        pending.put(r, future);
        return true;
    }

    public final void removeCallbacks(Runnable r) {
        ScheduledFuture<?> future = pending.remove(r);
        if (future != null) future.cancel(false);
    }

    public final void removeCallbacksAndMessages(Object token) {
        for (ScheduledFuture<?> future : pending.values()) future.cancel(false);
        pending.clear();
    }
}
