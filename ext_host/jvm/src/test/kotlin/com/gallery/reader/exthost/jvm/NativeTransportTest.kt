package com.gallery.reader.exthost.jvm

import com.gallery.reader.exthost.net.PersistentCookieJar
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Headers.Companion.headersOf
import okio.Buffer
import okio.GzipSink
import okio.buffer
import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.util.Collections
import java.util.zip.GZIPInputStream
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Requests carried by a platform transport, as on iOS: OkHttp keeps doing
 * cookies, redirects, decompression and the extension's interceptors.
 * The stand-in transport behaves as NSURLSession does: no redirects, no
 * cookies, and it decompresses gzip itself.
 */
class NativeTransportTest {
    private lateinit var site: MockWebServer
    private val carried: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val plain = OkHttpClient.Builder().followRedirects(false).build()

    private val transport =
        Transport { meta, body ->
            val m = Json.parseToJsonElement(String(meta)).jsonObject
            val url = m["url"]!!.jsonPrimitive.content
            carried += "${m["method"]!!.jsonPrimitive.content} $url"
            val headers = m["headers"]!!.jsonArray.map { it.jsonArray.map { v -> v.jsonPrimitive.content } }
            val request =
                Request
                    .Builder()
                    .url(url)
                    .headers(headersOf(*headers.flatten().toTypedArray()))
                    .method(m["method"]!!.jsonPrimitive.content, body?.toRequestBody())
                    .build()
            plain.newCall(request).execute().use { response ->
                var data = response.body.bytes()
                val out = response.headers.toMultimap().toMutableMap()
                if (response.header("Content-Encoding") == "gzip") {
                    data = GZIPInputStream(ByteArrayInputStream(data)).readBytes()
                    out.remove("content-encoding")
                    out.remove("content-length")
                }
                val info =
                    buildJsonObject {
                        put("code", response.code)
                        put("message", response.message)
                        put("headers", JsonArray(out.flatMap { (k, vs) -> vs.map { JsonArray(listOf(JsonPrimitive(k), JsonPrimitive(it))) } }))
                    }
                arrayOf(info.toString().toByteArray(), data)
            }
        }

    @BeforeTest
    fun setUp() {
        site = MockWebServer()
        site.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse =
                    when (request.url.encodedPath) {
                        "/login" -> MockResponse.Builder().code(302).addHeader("Location", "/home").addHeader("Set-Cookie", "sid=42; Path=/").build()
                        "/home" -> MockResponse.Builder().body("home cookie=${request.headers["Cookie"]} ext=${request.headers["X-Ext"]} net=${request.headers["X-Net"]}").build()
                        "/zipped" -> {
                            val buffer = Buffer()
                            GzipSink(buffer).buffer().use { it.writeUtf8("unzipped text") }
                            MockResponse.Builder().addHeader("Content-Encoding", "gzip").body(buffer).build()
                        }
                        "/echo" -> MockResponse.Builder().body("got ${request.body?.utf8()} as ${request.headers["Content-Type"]}").build()
                        else -> MockResponse.Builder().code(404).build()
                    }
            }
        site.start()
    }

    @AfterTest
    fun tearDown() {
        site.close()
    }

    private fun client(): OkHttpClient =
        OkHttpClient
            .Builder()
            .cookieJar(PersistentCookieJar(Files.createTempFile("cookies", ".json").toFile()))
            .addInterceptor(NativeTransportSwitch(transport) { "" })
            // As an extension would add them.
            .addInterceptor { it.proceed(it.request().newBuilder().header("X-Ext", "yes").build()) }
            .addNetworkInterceptor { it.proceed(it.request().newBuilder().header("X-Net", "yes").build()) }
            .build()

    @Test
    fun `redirects, cookies and the extension's interceptors still work`() {
        val text = client().newCall(Request.Builder().url(site.url("/login")).build()).execute().use { it.body.string() }
        assertEquals("home cookie=sid=42 ext=yes net=yes", text)
        assertEquals(listOf("GET ${site.url("/login")}", "GET ${site.url("/home")}"), carried)
    }

    @Test
    fun `gzip comes back readable whether or not the platform unpacked it`() {
        val text = client().newCall(Request.Builder().url(site.url("/zipped")).build()).execute().use { it.body.string() }
        assertEquals("unzipped text", text)
    }

    @Test
    fun `a posted body and its type reach the site`() {
        val text =
            client()
                .newCall(Request.Builder().url(site.url("/echo")).post("""{"a":1}""".toRequestBody("application/json".toMediaType())).build())
                .execute()
                .use { it.body.string() }
        assertTrue(text.startsWith("""got {"a":1} as application/json"""), text)
    }
}
