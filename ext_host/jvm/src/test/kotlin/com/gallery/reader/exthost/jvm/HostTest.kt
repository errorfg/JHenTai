package com.gallery.reader.exthost.jvm

import android.webkit.CookieManager
import com.gallery.reader.exthost.ExtHost
import com.gallery.reader.exthost.compat.Bridges
import com.gallery.reader.exthost.extension.ApkManifest
import com.gallery.reader.exthost.extension.ExtensionStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URLEncoder
import java.nio.file.Files
import java.util.Collections
import java.util.zip.ZipFile
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The host end to end: the test extension (a real APK, dex and binary
 * manifest) is installed, converted and loaded, and every API call reaches
 * a local stand-in for the site.
 */
class HostTest {
    private lateinit var site: MockWebServer
    private val seen: MutableList<RecordedRequest> = Collections.synchronizedList(mutableListOf())
    private val toasts: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val client = OkHttpClient()

    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3)
    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 9, 9)

    private fun json(text: String) = MockResponse.Builder().addHeader("Content-Type", "application/json").body(text).build()

    @BeforeTest
    fun setUp() {
        site = MockWebServer()
        site.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    seen += request
                    val path = request.url.encodedPath
                    return when {
                        path == "/list" ->
                            MockResponse
                                .Builder()
                                .addHeader("Set-Cookie", "session=abc; Path=/; Max-Age=3600")
                                .body("""{"items":[{"id":"1","title":"First"},{"id":"2","title":"Second"}],"next":"true"}""")
                                .build()
                        path == "/search" -> json("""{"items":[{"id":"3","title":"Found"}],"next":"false"}""")
                        path == "/manga/1" -> json("""{"title":"First","author":"Someone","description":"About","genres":["a","b"]}""")
                        path == "/manga/1/chapters" -> json("""[{"url":"/chapter/2","name":"Ch. 2","date":"200"},{"url":"/chapter/1","name":"Ch. 1","date":"100"}]""")
                        path == "/chapter/1" -> json("""["${site.url("/img/0.png")}","${site.url("/page/1")}"]""")
                        path == "/page/1" -> MockResponse.Builder().body(site.url("/img/1.jpg").toString()).build()
                        path == "/img/0.png" -> MockResponse.Builder().addHeader("Content-Type", "image/png").body(okio.Buffer().write(png)).build()
                        path == "/img/1.jpg" -> MockResponse.Builder().addHeader("Content-Type", "application/octet-stream").body(okio.Buffer().write(jpeg)).build()
                        path.startsWith("/cover/") -> MockResponse.Builder().addHeader("Content-Type", "image/png").body(okio.Buffer().write(png)).build()
                        else -> MockResponse.Builder().code(404).build()
                    }
                }
            }
        site.start()
        Bridges.notices = Bridges.Notices { toasts += it }
        host.store.uninstall(TEST_PKG)
        val installed = post("/extensions/install", """{"path":${JsonPrimitive(testApk.path)}}""")
        sourceId = installed["sources"]!!.jsonArray[0].jsonObject["id"]!!.jsonPrimitive.content
        platform.application
            .getSharedPreferences("source_$sourceId", 0)
            .edit()
            .clear()
            .putString("base_url", site.url("/").toString().trimEnd('/'))
            .commit()
        host.store.unload(TEST_PKG)
        seen.clear()
    }

    @AfterTest
    fun tearDown() {
        site.close()
    }

    private lateinit var sourceId: String

    private fun call(
        path: String,
        body: String? = null,
        token: String? = TOKEN,
    ): okhttp3.Response {
        val request =
            Request
                .Builder()
                .url("http://127.0.0.1:${host.port}$path")
                .apply { if (token != null) header("Authorization", "Bearer $token") }
                .apply { if (body != null) post(body.toRequestBody("application/json".toMediaType())) }
                .build()
        return client.newCall(request).execute()
    }

    private fun post(
        path: String,
        body: String,
    ): JsonObject =
        call(path, body).use {
            val text = it.body.string()
            assertEquals(200, it.code, text)
            Json.parseToJsonElement(text).jsonObject
        }

    private fun source(extra: String = "") = """{"source":"$sourceId"$extra}"""

    private fun JsonElement.str(key: String) = jsonObject[key]!!.jsonPrimitive.content

    @Test
    fun `the manifest reader finds what the host needs`() {
        val manifest = ZipFile(testApk).use { ApkManifest.parse(it.getInputStream(it.getEntry("AndroidManifest.xml")).readBytes()) }
        assertEquals("com.gallery.reader.exthost.testext", manifest.packageName)
        assertEquals("1.4.3", manifest.versionName)
        assertEquals(3, manifest.versionCode)
        assertEquals("Tachiyomi: Test Source", manifest.label)
        assertEquals(listOf("tachiyomi.extension"), manifest.features)
        assertEquals(mapOf("tachiyomi.extension.class" to ".TestSource", "tachiyomi.extension.nsfw" to "0"), manifest.metaData)
    }

    @Test
    fun `an installed extension is listed and survives a restart`() {
        val listed = call("/extensions").use { Json.parseToJsonElement(it.body.string()).jsonObject }["extensions"]!!.jsonArray.single()
        assertEquals("Test Source", listed.str("name"))
        assertEquals("1.4", listed.str("libVersion"))
        assertEquals(false, listed.jsonObject["nsfw"]!!.jsonPrimitive.boolean)
        val src = listed.jsonObject["sources"]!!.jsonArray.single()
        assertEquals("en", src.str("lang"))
        assertEquals(true, src.jsonObject["configurable"]!!.jsonPrimitive.boolean)
        assertEquals(true, src.jsonObject["supportsLatest"]!!.jsonPrimitive.boolean)

        // A new store reads the same directory without loading any code.
        val again = ExtensionStore(platform)
        assertEquals(listOf(TEST_PKG), again.list().map { it.pkg })
        assertEquals("Test Source", again.source(sourceId.toLong()).name)
    }

    @Test
    fun `requests need the token`() {
        call("/extensions", token = null).use { assertEquals(401, it.code) }
        call("/extensions", token = "wrong").use { assertEquals(401, it.code) }
        client.newCall(Request.Builder().url("http://127.0.0.1:${host.port}/ping?token=$TOKEN").build()).execute().use { assertEquals(200, it.code) }
    }

    @Test
    fun `popular and latest lists come from the source`() {
        val popular = post("/source/popular", source(""","page":2"""))
        assertEquals(listOf("First", "Second"), popular["mangas"]!!.jsonArray.map { it.str("title") })
        assertEquals("/manga/1", popular["mangas"]!!.jsonArray[0].str("url"))
        assertEquals(site.url("/cover/1").toString(), popular["mangas"]!!.jsonArray[0].str("thumbnailUrl"))
        assertEquals(true, popular["hasNextPage"]!!.jsonPrimitive.boolean)
        val request = seen.single()
        assertEquals("2", request.url.queryParameter("page"))
        assertEquals("hot", request.url.queryParameter("sort"))
        assertTrue(request.headers["User-Agent"]!!.startsWith("Mozilla/5.0"))

        post("/source/latest", source(""","page":1"""))
        assertEquals("new", seen.last().url.queryParameter("sort"))
    }

    @Test
    fun `search applies the filters the app edited`() {
        val filters = post("/source/filters", source())["filters"]!!.jsonArray
        assertEquals(listOf("header", "select", "checkbox", "group", "sort"), filters.map { it.str("type") })
        assertEquals(listOf("all", "action", "romance"), filters[1].jsonObject["values"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(0, filters[4].jsonObject["state"]!!.jsonObject["index"]!!.jsonPrimitive.int)

        val edited =
            JsonArray(
                filters.mapIndexed { i, f ->
                    val o = f.jsonObject.toMutableMap()
                    when (i) {
                        1 -> o["state"] = JsonPrimitive(1)
                        2 -> o["state"] = JsonPrimitive(true)
                        3 -> o["state"] = JsonArray(o["state"]!!.jsonArray.map { t -> JsonObject(t.jsonObject + ("state" to JsonPrimitive(t.str("name") == "b"))) })
                        4 -> o["state"] = JsonObject(mapOf("index" to JsonPrimitive(1), "ascending" to JsonPrimitive(true)))
                    }
                    JsonObject(o)
                },
            )
        val found = post("/source/search", source(""","page":1,"query":"tea time","filters":$edited"""))
        assertEquals(listOf("Found"), found["mangas"]!!.jsonArray.map { it.str("title") })
        val url = seen.single().url
        assertEquals("tea time", url.queryParameter("q"))
        assertEquals("action", url.queryParameter("genre"))
        assertEquals("1", url.queryParameter("completed"))
        assertEquals(listOf("b"), url.queryParameterValues("tag"))
        assertEquals("1:true", url.queryParameter("order"))
    }

    @Test
    fun `details, chapters, pages and images`() {
        val manga = """{"url":"/manga/1","title":"First"}"""
        val details = post("/manga/details", source(""","manga":$manga"""))
        assertEquals("Someone", details.str("author"))
        assertEquals("a, b", details.str("genre"))
        assertEquals("/manga/1", details.str("url"))
        assertEquals(true, details["initialized"]!!.jsonPrimitive.boolean)

        val chapters = post("/manga/chapters", source(""","manga":$manga"""))["chapters"]!!.jsonArray
        assertEquals(listOf("Ch. 2", "Ch. 1"), chapters.map { it.str("name") })
        assertEquals(100, chapters[1].jsonObject["dateUpload"]!!.jsonPrimitive.int)

        val pages = post("/chapter/pages", source(""","chapter":${chapters[1]}"""))["pages"]!!.jsonArray
        assertEquals(2, pages.size)
        assertEquals(site.url("/img/0.png").toString(), pages[0].str("imageUrl"))
        assertEquals(site.url("/page/1").toString(), pages[1].str("url"))

        fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
        call("/image?source=$sourceId&url=${enc(pages[0].str("imageUrl"))}").use {
            assertEquals(200, it.code)
            assertEquals("image/png", it.header("Content-Type"))
            assertTrue(png.contentEquals(it.body.bytes()))
        }
        // A page with only its page URL: the host asks the source for the image URL first.
        call("/image?source=$sourceId&index=1&page=${enc(pages[1].str("url"))}").use {
            assertEquals(200, it.code)
            assertEquals("image/jpeg", it.header("Content-Type"), "octet-stream is replaced by the sniffed type")
            assertTrue(jpeg.contentEquals(it.body.bytes()))
        }
        call("/cover?source=$sourceId&url=${enc(site.url("/cover/1").toString())}").use {
            assertEquals(200, it.code)
            assertTrue(png.contentEquals(it.body.bytes()))
        }
        val imageUrl = post("/page/image-url", source(""","page":${pages[1]}"""))
        assertEquals(site.url("/img/1.jpg").toString(), imageUrl.str("imageUrl"))
    }

    @Test
    fun `settings go through the extension's change listener`() {
        val prefs = post("/source/preferences", source())["preferences"]!!.jsonArray
        assertEquals(listOf("list", "switch"), prefs.map { it.str("type") })
        assertEquals("Hot", prefs[0].str("summary"), "%s shows the chosen entry")
        assertEquals("hot", prefs[0].str("value"))

        val changed = post("/source/preferences/set", source(""","key":"sort","value":"new""""))["preferences"]!!.jsonArray
        assertEquals("new", changed[0].str("value"))
        assertEquals("New", changed[0].str("summary"))
        post("/source/popular", source(""","page":1"""))
        assertEquals("new", seen.last().url.queryParameter("sort"), "a new source object reads the new setting")

        val refused = post("/source/preferences/set", source(""","key":"locked","value":true"""))["preferences"]!!.jsonArray
        assertEquals(false, refused[1].jsonObject["value"]!!.jsonPrimitive.boolean)
        assertEquals(listOf("cannot change"), toasts)
    }

    @Test
    fun `cookies a site sets are kept and visible to CookieManager`() {
        post("/source/popular", source(""","page":1"""))
        post("/source/popular", source(""","page":2"""))
        assertEquals("session=abc", seen.last().headers["Cookie"])
        assertEquals("session=abc", CookieManager.getInstance().getCookie(site.url("/list").toString()))
    }

    @Test
    fun `errors say what failed`() {
        call("/source/popular", """{"source":"42"}""").use {
            assertEquals(400, it.code)
            assertTrue(it.body.string().contains("no installed extension has source 42"))
        }
        call("/manga/details", source(""","manga":{"url":"/missing","title":"x"}""")).use {
            assertEquals(502, it.code)
            assertEquals(404, Json.parseToJsonElement(it.body.string()).jsonObject["httpCode"]!!.jsonPrimitive.int)
        }
        call("/extensions/icon?pkg=$TEST_PKG").use { assertEquals(404, it.code) }
    }

    companion object {
        const val TOKEN = "test-token"
        const val TEST_PKG = "com.gallery.reader.exthost.testext"

        private val dataDir: File = Files.createTempDirectory("exthost-test").toFile()
        val platform = JvmPlatform(dataDir)
        val host: ExtHost.Running by lazy { ExtHost.start(platform, TOKEN) }

        val testApk: File by lazy {
            File(dataDir, "testext.apk").apply {
                HostTest::class.java.getResourceAsStream("/testext.apk")!!.use { input -> outputStream().use { input.copyTo(it) } }
                assertNotNull(this)
            }
        }
    }
}
