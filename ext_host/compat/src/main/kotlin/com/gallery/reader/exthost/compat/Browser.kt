package com.gallery.reader.exthost.compat

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * The browser engine behind android.webkit.WebView on the JVM: the app's
 * WKWebView on iOS and macOS, reached through [link] (the jvm module's
 * BrowserRelay). Commands and events are JSON objects carrying the number of
 * the view they belong to under "view".
 */
object Browser {
    fun interface Link {
        /** Queues [command] for the engine; false when no engine is attached. */
        fun send(command: JsonObject): Boolean
    }

    @Volatile
    @JvmStatic
    var link: Link? = null

    private val ids = AtomicInteger()
    private val views = ConcurrentHashMap<Int, (JsonObject) -> Unit>()

    fun register(sink: (JsonObject) -> Unit): Int = ids.incrementAndGet().also { views[it] = sink }

    fun unregister(id: Int) {
        views.remove(id)
    }

    /** Hands an event from the engine to the view it names. */
    fun dispatch(event: JsonObject) {
        val id = (event["view"] as? JsonPrimitive)?.intOrNull ?: return
        views[id]?.invoke(event)
    }
}
