package com.gallery.reader.exthost.compat

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * What one android.webkit.WebView does on the JVM: its calls become commands
 * for the [Browser] engine, and the engine's events become the callbacks
 * Android makes. Page events and evaluateJavascript results arrive on the
 * main looper; shouldInterceptRequest and JavaScript interface calls on
 * other threads, as on Android.
 *
 * The engine can watch requests but not answer them, so what
 * shouldInterceptRequest returns is not used. JavaScript interface methods
 * run when the page calls them, but the page gets no return value.
 */
class WebViewSession(
    private val view: WebView,
) {
    private val id = Browser.register(::onEvent)
    private val main = Handler(Looper.getMainLooper())
    private val calls = AtomicInteger()
    private val evaluations = ConcurrentHashMap<Int, ValueCallback<String>?>()
    private val interfaces = ConcurrentHashMap<String, Any>()

    @Volatile
    private var destroyed = false

    @Volatile
    var url: String? = null
        private set

    @Volatile
    var title: String? = null
        private set

    @Volatile
    var progress: Int = 0
        private set

    fun addInterface(
        target: Any,
        name: String,
    ) {
        interfaces[name] = target
    }

    fun removeInterface(name: String) {
        interfaces.remove(name)
    }

    fun load(
        url: String,
        headers: Map<String, String>,
    ) {
        this.url = url
        progress = 0
        send("load") {
            put("url", url)
            put("headers", JsonObject(headers.mapValues { JsonPrimitive(it.value) }))
        }
    }

    fun loadHtml(
        html: String,
        baseUrl: String?,
    ) {
        url = baseUrl ?: "about:blank"
        progress = 0
        send("loadHtml") {
            put("html", html)
            put("baseUrl", baseUrl)
        }
    }

    fun evaluate(
        script: String,
        callback: ValueCallback<String>?,
    ) {
        val call = calls.incrementAndGet()
        evaluations[call] = callback
        val sent =
            send("eval") {
                put("call", call)
                put("script", script)
            }
        if (!sent) evaluations.remove(call)?.let { main.post { it.onReceiveValue(null) } }
    }

    fun stop() {
        send("stop") {}
    }

    fun destroy() {
        if (destroyed) return
        send("destroy") {}
        destroyed = true
        Browser.unregister(id)
        evaluations.clear()
    }

    private fun send(
        op: String,
        fill: JsonObjectBuilder.() -> Unit,
    ): Boolean {
        if (destroyed) return false
        val command =
            buildJsonObject {
                put("op", op)
                put("view", id)
                put("userAgent", view.settings.userAgentString)
                put("javaScript", view.settings.javaScriptEnabled)
                put("interfaces", JsonObject(interfaces.mapValues { (_, target) -> JsonArray(methodsOf(target).map(::JsonPrimitive)) }))
                fill()
            }
        if (Browser.link?.send(command) == true) return true
        if (op == "load" || op == "loadHtml") {
            val failed = url ?: "about:blank"
            System.err.println("WebView: no browser engine in this host; failing $failed")
            main.post { view.webViewClient.onReceivedError(view, Request(failed, "GET", emptyMap(), true), Error(WebViewClient.ERROR_UNKNOWN, "WebView is not available in this host")) }
        }
        return false
    }

    private fun onEvent(event: JsonObject) {
        if (destroyed) return
        val eventUrl = event.string("url")
        when (event.string("type")) {
            "started" ->
                main.post {
                    url = eventUrl ?: url
                    progress = 10
                    view.webViewClient.onPageStarted(view, eventUrl, null)
                    view.webChromeClient?.onProgressChanged(view, 10)
                }
            "finished" ->
                main.post {
                    url = eventUrl ?: url
                    title = event.string("title")
                    progress = 100
                    title?.let { view.webChromeClient?.onReceivedTitle(view, it) }
                    view.webChromeClient?.onProgressChanged(view, 100)
                    view.webViewClient.onPageFinished(view, eventUrl)
                }
            "error" -> {
                val request = request(event)
                val error = Error(event.int("code") ?: WebViewClient.ERROR_UNKNOWN, event.string("description").orEmpty())
                main.post { view.webViewClient.onReceivedError(view, request, error) }
            }
            "httpError" -> {
                val request = request(event)
                val headers = (event["headers"] as? JsonObject)?.mapValues { it.value.text() }.orEmpty()
                val response = WebResourceResponse(null, null, event.int("status") ?: 0, event.string("reason") ?: "", headers, null)
                main.post { view.webViewClient.onReceivedHttpError(view, request, response) }
            }
            "request" -> {
                val request = request(event)
                background.execute {
                    try {
                        view.webViewClient.shouldInterceptRequest(view, request)
                    } catch (e: Throwable) {
                        System.err.println("WebView: shouldInterceptRequest failed: $e")
                    }
                }
            }
            "navigate" -> {
                val request = request(event)
                val call = event.int("call") ?: return
                main.post {
                    val handled =
                        try {
                            view.webViewClient.shouldOverrideUrlLoading(view, request)
                        } catch (e: Throwable) {
                            System.err.println("WebView: shouldOverrideUrlLoading failed: $e")
                            false
                        }
                    send("decide") {
                        put("call", call)
                        put("allow", !handled)
                    }
                }
            }
            "eval" -> {
                val callback = evaluations.remove(event.int("call") ?: return) ?: return
                val value = event.string("value") ?: "null"
                main.post { callback.onReceiveValue(value) }
            }
            "js" -> {
                val target = interfaces[event.string("interface") ?: return] ?: return
                val method = event.string("method") ?: return
                val args = event["args"] as? JsonArray ?: JsonArray(emptyList())
                javaBridge.execute { invoke(target, method, args) }
            }
            "console" -> {
                val message = ConsoleMessage(event.string("message").orEmpty(), event.string("source").orEmpty(), event.int("line") ?: 0)
                main.post { view.webChromeClient?.onConsoleMessage(message) }
            }
        }
    }

    private fun request(event: JsonObject): Request =
        Request(
            event.string("url") ?: url ?: "about:blank",
            event.string("method") ?: "GET",
            (event["headers"] as? JsonObject)?.mapValues { it.value.text() }.orEmpty(),
            (event["mainFrame"] as? JsonPrimitive)?.booleanOrNull ?: true,
            hasGesture = (event["gesture"] as? JsonPrimitive)?.booleanOrNull ?: false,
        )

    private class Request(
        private val url: String,
        private val method: String,
        private val headers: Map<String, String>,
        private val mainFrame: Boolean,
        private val hasGesture: Boolean = false,
    ) : WebResourceRequest {
        override fun getUrl(): Uri = Uri.parse(url)

        override fun isForMainFrame() = mainFrame

        override fun isRedirect() = false

        override fun hasGesture() = hasGesture

        override fun getMethod() = method

        override fun getRequestHeaders() = headers
    }

    private class Error(
        private val code: Int,
        private val description: String,
    ) : WebResourceError() {
        override fun getErrorCode() = code

        override fun getDescription(): CharSequence = description
    }

    companion object {
        /** Where shouldInterceptRequest runs: off the main looper, as on Android. */
        private val background: ExecutorService = daemonPool("webview-requests")

        /** Where JavaScript interface methods run: Android's "JavaBridge" thread. */
        private val javaBridge: ExecutorService = daemonPool("JavaBridge")

        private fun daemonPool(name: String): ExecutorService =
            Executors.newSingleThreadExecutor { runnable -> Thread(runnable, name).apply { isDaemon = true } }

        /** The methods a page may call: those marked @JavascriptInterface, as on Android since 4.2. */
        fun methodsOf(target: Any): List<String> =
            target.javaClass.methods
                .filter { it.isAnnotationPresent(JavascriptInterface::class.java) }
                .map(Method::getName)
                .distinct()

        private fun invoke(
            target: Any,
            name: String,
            args: JsonArray,
        ) {
            val method =
                target.javaClass.methods.firstOrNull {
                    it.name == name && it.parameterCount == args.size && it.isAnnotationPresent(JavascriptInterface::class.java)
                } ?: return
            try {
                method.isAccessible = true
                method.invoke(target, *method.parameterTypes.mapIndexed { i, type -> convert(args[i], type) }.toTypedArray())
            } catch (e: InvocationTargetException) {
                System.err.println("WebView: ${target.javaClass.name}.$name failed: ${e.targetException}")
            } catch (e: Exception) {
                System.err.println("WebView: cannot call ${target.javaClass.name}.$name: $e")
            }
        }

        /** A JavaScript value as the parameter type, the way Android's bridge converts it. */
        private fun convert(
            value: JsonElement,
            type: Class<*>,
        ): Any? {
            val primitive = value as? JsonPrimitive
            val number = primitive?.doubleOrNull
            return when (type) {
                String::class.java -> if (value is JsonNull) null else value.text()
                Int::class.javaPrimitiveType, Int::class.javaObjectType -> primitive?.intOrNull ?: number?.toInt() ?: 0
                Long::class.javaPrimitiveType, Long::class.javaObjectType -> primitive?.longOrNull ?: number?.toLong() ?: 0L
                Double::class.javaPrimitiveType, Double::class.javaObjectType -> number ?: 0.0
                Float::class.javaPrimitiveType, Float::class.javaObjectType -> number?.toFloat() ?: 0f
                Boolean::class.javaPrimitiveType, Boolean::class.javaObjectType -> primitive?.booleanOrNull ?: false
                else -> null
            }
        }

        private fun JsonElement.text(): String = (this as? JsonPrimitive)?.contentOrNull ?: toString()

        private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

        private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
    }
}
