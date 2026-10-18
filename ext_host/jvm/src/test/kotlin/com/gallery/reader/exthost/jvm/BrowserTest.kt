package com.gallery.reader.exthost.jvm

import android.app.Application
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import com.gallery.reader.exthost.compat.Bridges
import com.gallery.reader.exthost.compat.Browser
import com.gallery.reader.exthost.server.Request
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Headers.Companion.toHeaders
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * WebView through the browser relay, with the test playing the app's
 * engine: it polls for commands and posts events as TachiBrowser.swift does.
 */
class BrowserTest {
    private lateinit var dir: File
    private lateinit var platform: JvmPlatform

    @BeforeTest
    fun setUp() {
        dir = Files.createTempDirectory("browser-test").toFile()
        platform = JvmPlatform(dir, browser = true)
    }

    @AfterTest
    fun tearDown() {
        Browser.link = null
        dir.deleteRecursively()
    }

    private fun poll(wait: Long = 5_000): List<JsonObject> {
        val response = platform.route(Request("GET", "/browser/poll", mapOf("wait" to "$wait"), emptyMap(), ByteArray(0)))!!
        return Json.parseToJsonElement(response.body.decodeToString()).jsonObject["commands"]!!.jsonArray.map { it.jsonObject }
    }

    private fun post(vararg events: JsonObject) {
        val body = JsonObject(mapOf("events" to JsonArray(events.toList()))).toString().toByteArray()
        assertEquals(200, platform.route(Request("POST", "/browser/events", emptyMap(), emptyMap(), body))!!.status)
    }

    private fun event(
        type: String,
        view: Int,
        fill: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ) = buildJsonObject {
        put("type", type)
        put("view", view)
        fill()
    }

    private class Native(
        val token: CompletableFuture<String>,
    ) {
        @JavascriptInterface
        fun sendToken(value: String) {
            token.complete(value)
        }

        @Suppress("unused")
        fun notExposed() {}
    }

    /** CopyManga's login: the token comes from the page's cookie, a request it makes, or its JavaScript. */
    @Test
    fun pageLoadCarriesCookiesBothWaysAndReportsRequestsAndScriptCalls() {
        Bridges.cookies.set("https://site.test/", "sid=1; Path=/")
        val finishedCookie = CompletableFuture<String?>()
        val authorization = CompletableFuture<String?>()
        val token = CompletableFuture<String>()
        val view = WebView(Application(dir))
        view.settings.javaScriptEnabled = true
        view.addJavascriptInterface(Native(token), "Native")
        view.webViewClient =
            object : WebViewClient() {
                override fun onPageFinished(
                    view: WebView,
                    url: String,
                ) {
                    finishedCookie.complete(CookieManager.getInstance().getCookie(url))
                }

                override fun shouldInterceptRequest(
                    view: WebView,
                    request: WebResourceRequest,
                ): WebResourceResponse? {
                    if (request.url.toString().endsWith("/system/config/2020/1")) authorization.complete(request.requestHeaders.toHeaders()["Authorization"])
                    return null
                }
            }
        view.loadUrl("https://site.test/h5")

        val load = poll().single()
        assertEquals("load", load["op"]!!.jsonPrimitive.content)
        assertEquals("https://site.test/h5", load["url"]!!.jsonPrimitive.content)
        assertTrue(load["javaScript"]!!.jsonPrimitive.boolean)
        assertEquals(listOf("sendToken"), load["interfaces"]!!.jsonObject["Native"]!!.jsonArray.map { it.jsonPrimitive.content })
        val sent = load["cookies"]!!.jsonArray.single().jsonObject
        // Not Secure, so for http as well; a host-only cookie, so no Domain.
        assertEquals("http://site.test/", sent["url"]!!.jsonPrimitive.content)
        assertTrue("domain=" !in sent["setCookie"]!!.jsonPrimitive.content)
        assertTrue(sent["setCookie"]!!.jsonPrimitive.content.startsWith("sid=1"))

        val id = load["view"]!!.jsonPrimitive.int
        post(
            event("started", id) { put("url", "https://site.test/h5") },
            event("request", id) {
                put("url", "https://api.site.test/api/v3/system/config/2020/1")
                put("method", "GET")
                put("mainFrame", false)
                putJsonObject("headers") { put("authorization", "Token abc") }
            },
            event("finished", id) {
                put("url", "https://site.test/h5")
                put("title", "h5")
                putJsonArray("cookies") {
                    add(
                        buildJsonObject {
                            put("url", "https://site.test/")
                            put("setCookie", "token=abc; Path=/; Secure; HttpOnly")
                        },
                    )
                }
            },
            event("js", id) {
                put("interface", "Native")
                put("method", "sendToken")
                put("args", buildJsonArray { add(JsonPrimitive("abc")) })
            },
        )

        val cookie = finishedCookie.get(5, TimeUnit.SECONDS)!!
        assertTrue("sid=1" in cookie && "token=abc" in cookie, cookie)
        assertEquals("Token abc", authorization.get(5, TimeUnit.SECONDS))
        assertEquals("abc", token.get(5, TimeUnit.SECONDS))
        assertEquals("h5", view.title)
        assertEquals(100, view.progress)

        view.destroy()
        assertEquals("destroy", poll().single()["op"]!!.jsonPrimitive.content)
    }

    @Test
    fun scriptResultsAndNavigationDecisionsComeBack() {
        val view = WebView(Application(dir))
        view.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    url: String,
                ): Boolean = url.startsWith("app://")
            }
        val result = CompletableFuture<String?>()
        view.evaluateJavascript("1 + 1") { result.complete(it) }
        val eval = poll().single()
        assertEquals("eval", eval["op"]!!.jsonPrimitive.content)
        val id = eval["view"]!!.jsonPrimitive.int
        post(
            event("eval", id) {
                put("call", eval["call"]!!.jsonPrimitive.int)
                put("value", "2")
            },
        )
        assertEquals("2", result.get(5, TimeUnit.SECONDS))

        post(
            event("navigate", id) {
                put("call", 7)
                put("url", "app://open")
            },
        )
        val decide = poll().single()
        assertEquals("decide", decide["op"]!!.jsonPrimitive.content)
        assertEquals(7, decide["call"]!!.jsonPrimitive.int)
        assertEquals(false, decide["allow"]!!.jsonPrimitive.boolean)

        post(
            event("navigate", id) {
                put("call", 8)
                put("url", "https://site.test/next")
            },
        )
        assertEquals(true, poll().single()["allow"]!!.jsonPrimitive.boolean)
        view.destroy()
    }

    /** Without the app polling, a page fails at once rather than after the extension's own timeout. */
    @Test
    fun failsFastWhenNoEngineIsAttached() {
        var now = 0L
        Browser.link = BrowserRelay(platform.cookieJar) { now }
        now += BrowserRelay.ATTACH_GRACE_MS + 1
        val error = CompletableFuture<Int>()
        val view = WebView(Application(dir))
        view.webViewClient =
            object : WebViewClient() {
                override fun onReceivedError(
                    view: WebView,
                    errorCode: Int,
                    description: String,
                    failingUrl: String,
                ) {
                    error.complete(errorCode)
                }
            }
        view.loadUrl("https://site.test/")
        assertEquals(WebViewClient.ERROR_UNKNOWN, error.get(5, TimeUnit.SECONDS))
        val result = CompletableFuture<String?>()
        view.evaluateJavascript("1") { result.complete(it) }
        assertNull(result.get(5, TimeUnit.SECONDS))
    }
}
