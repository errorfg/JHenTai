package com.gallery.reader.exthost.jvm

import com.gallery.reader.exthost.compat.Browser
import com.gallery.reader.exthost.net.CookieCodec
import com.gallery.reader.exthost.server.Request
import com.gallery.reader.exthost.server.Response
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.CookieJar
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Lends the compat WebView the app's browser engine (WKWebView on iOS and
 * macOS). The app asks `GET /browser/poll?wait=<ms>` for commands, which
 * waits until there are some, and posts what the engine reports to
 * `POST /browser/events` as `{"events": [...]}`; see
 * lib/src/network/tachi/tachi_browser.dart and the plugin's TachiBrowser.swift.
 *
 * Cookies go along, so the host's requests and the pages share a login: a
 * page load carries the host's cookies for its URL, and the cookies an event
 * brings back (a page that finished) are stored before the event is handled.
 */
class BrowserRelay(
    private val cookieJar: CookieJar,
    private val clock: () -> Long = System::currentTimeMillis,
) : Browser.Link {
    private val queue = LinkedBlockingQueue<JsonObject>()
    private val polling = AtomicInteger()

    /** When a poll last ended; counted from the start, while the app's first poll is on its way. */
    @Volatile
    private var lastPoll = clock()

    /** Whether the app is polling, or was a moment ago and is handing out the last commands. */
    val attached: Boolean get() = polling.get() > 0 || clock() - lastPoll < ATTACH_GRACE_MS

    override fun send(command: JsonObject): Boolean {
        if (!attached) return false
        queue.put(withCookies(command))
        return true
    }

    fun route(request: Request): Response? =
        when {
            request.method == "GET" && request.path == "/browser/poll" -> poll(request.query["wait"]?.toLongOrNull() ?: DEFAULT_WAIT_MS)
            request.method == "POST" && request.path == "/browser/events" -> events(request.body)
            else -> null
        }

    private fun poll(waitMs: Long): Response {
        polling.incrementAndGet()
        try {
            val batch = ArrayList<JsonObject>()
            queue.poll(waitMs.coerceIn(0, MAX_WAIT_MS), TimeUnit.MILLISECONDS)?.let {
                batch += it
                queue.drainTo(batch)
            }
            return Response.json(200, JsonObject(mapOf("commands" to JsonArray(batch))).toString())
        } finally {
            lastPoll = clock()
            polling.decrementAndGet()
        }
    }

    private fun events(body: ByteArray): Response {
        val events = Json.parseToJsonElement(body.decodeToString()).jsonObject["events"] as? JsonArray ?: JsonArray(emptyList())
        for (event in events) {
            val fields = event as? JsonObject ?: continue
            (fields["cookies"] as? JsonArray)?.let { CookieCodec.import(cookieJar, it) }
            Browser.dispatch(fields)
        }
        return Response.json(200, "{}")
    }

    private fun withCookies(command: JsonObject): JsonObject {
        val url =
            when ((command["op"] as? JsonPrimitive)?.contentOrNull) {
                "load" -> command.string("url")
                "loadHtml" -> command.string("baseUrl")
                else -> null
            } ?: return command
        if (!url.startsWith("http://") && !url.startsWith("https://")) return command
        return JsonObject(command + ("cookies" to CookieCodec.export(cookieJar, url)))
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    companion object {
        const val DEFAULT_WAIT_MS = 25_000L
        const val MAX_WAIT_MS = 60_000L

        /** How long after its last poll the app still counts as there. */
        const val ATTACH_GRACE_MS = 15_000L
    }
}
