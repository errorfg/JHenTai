package com.gallery.reader.exthost.testext

import android.app.Application
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.preference.ListPreference
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.Response
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import uy.kohesive.injekt.injectLazy
import java.util.concurrent.ConcurrentHashMap

/**
 * A Tachiyomi extension written for the host's tests. It is built like a
 * real one (compiled against the source API, converted to dex, packed with a
 * binary manifest) and talks to a test server whose address is a setting.
 */
class TestSource :
    HttpSource(),
    ConfigurableSource {
    override val name = "Test Source"
    override val lang = "en"
    override val supportsLatest = true

    private val preferences: SharedPreferences by lazy {
        Injekt.get<Application>().getSharedPreferences("source_$id", 0)
    }

    private val json: Json by injectLazy()

    override val baseUrl: String get() = preferences.getString(BASE_URL, "http://127.0.0.1:9")!!

    override fun popularMangaRequest(page: Int): Request = GET("$baseUrl/list?page=$page&sort=${preferences.getString(SORT, "hot")}", headers)

    override fun popularMangaParse(response: Response): MangasPage = parseList(response)

    override fun latestUpdatesRequest(page: Int): Request = GET("$baseUrl/list?page=$page&sort=new", headers)

    override fun latestUpdatesParse(response: Response): MangasPage = parseList(response)

    override fun searchMangaRequest(
        page: Int,
        query: String,
        filters: FilterList,
    ): Request {
        val url = "$baseUrl/search".toHttpUrl().newBuilder().addQueryParameter("q", query).addQueryParameter("page", page.toString())
        filters.forEach { filter ->
            when (filter) {
                is GenreFilter -> url.addQueryParameter("genre", filter.values[filter.state])
                is CompletedFilter -> if (filter.state) url.addQueryParameter("completed", "1")
                is GroupFilter -> filter.state.filter { it.state }.forEach { url.addQueryParameter("tag", it.name) }
                is OrderFilter -> filter.state?.let { url.addQueryParameter("order", "${it.index}:${it.ascending}") }
                else -> {}
            }
        }
        return GET(url.build(), headers)
    }

    override fun searchMangaParse(response: Response): MangasPage = parseList(response)

    override suspend fun getSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): MangasPage = if (query.startsWith(WEBVIEW)) webViewProbe(query.removePrefix(WEBVIEW)) else super.getSearchManga(page, query, filters)

    /**
     * Loads [url] in a WebView the way CopyManga's login does and lists what
     * the page gave, one title each: "cookie:" its cookies, "auth:" the
     * Authorization header of a request it made, "js:" what it passed to a
     * JavaScript interface, "eval:" the result of a script, "error:" a
     * loading error.
     */
    private fun webViewProbe(url: String): MangasPage {
        val found = ConcurrentHashMap<String, String>()
        val main = Handler(Looper.getMainLooper())
        var view: WebView? = null
        main.post {
            view =
                WebView(Injekt.get<Application>()).apply {
                    settings.javaScriptEnabled = true
                    addJavascriptInterface(Bridge(found), "Native")
                    webViewClient =
                        object : WebViewClient() {
                            override fun shouldInterceptRequest(
                                view: WebView,
                                request: WebResourceRequest,
                            ): WebResourceResponse? {
                                request.requestHeaders.entries.firstOrNull { it.key.equals("Authorization", ignoreCase = true) }?.let { found["auth"] = it.value }
                                return super.shouldInterceptRequest(view, request)
                            }

                            override fun onPageFinished(
                                view: WebView,
                                url: String,
                            ) {
                                CookieManager.getInstance().getCookie(url)?.let { found["cookie"] = it }
                                view.evaluateJavascript("document.title") { found["eval"] = it }
                            }

                            override fun onReceivedError(
                                view: WebView,
                                request: WebResourceRequest,
                                error: WebResourceError,
                            ) {
                                if (request.isForMainFrame) found["error"] = error.description.toString()
                            }
                        }
                    loadUrl(url)
                }
        }
        val deadline = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < deadline && !found.containsKey("error") && !found.keys.containsAll(listOf("cookie", "auth", "js", "eval"))) Thread.sleep(50)
        main.post { view?.destroy() }
        return MangasPage(found.entries.sortedBy { it.key }.map { (key, value) -> SManga.create().apply { this.url = "/probe/$key"; title = "$key:$value" } }, false)
    }

    class Bridge(
        private val found: MutableMap<String, String>,
    ) {
        @JavascriptInterface
        fun sendToken(token: String) {
            found["js"] = token
        }
    }

    private fun parseList(response: Response): MangasPage {
        val root = json.parseToJsonElement(response.body.string()).jsonObject
        val mangas =
            root["items"]!!.jsonArray.map { item ->
                SManga.create().apply {
                    url = "/manga/" + item.jsonObject["id"]!!.jsonPrimitive.content
                    title = item.jsonObject["title"]!!.jsonPrimitive.content
                    thumbnail_url = "$baseUrl/cover/" + item.jsonObject["id"]!!.jsonPrimitive.content
                }
            }
        return MangasPage(mangas, root["next"]!!.jsonPrimitive.content.toBoolean())
    }

    override fun mangaDetailsParse(response: Response): SManga {
        val item = json.parseToJsonElement(response.body.string()).jsonObject
        return SManga.create().apply {
            title = item["title"]!!.jsonPrimitive.content
            author = item["author"]?.jsonPrimitive?.content
            description = item["description"]?.jsonPrimitive?.content
            genre = item["genres"]?.jsonArray?.joinToString { it.jsonPrimitive.content }
            status = SManga.ONGOING
        }
    }

    override fun chapterListRequest(manga: SManga): Request = GET("$baseUrl${manga.url}/chapters", headers)

    override fun chapterListParse(response: Response): List<SChapter> =
        json.parseToJsonElement(response.body.string()).jsonArray.map { item ->
            SChapter.create().apply {
                url = item.jsonObject["url"]!!.jsonPrimitive.content
                name = item.jsonObject["name"]!!.jsonPrimitive.content
                date_upload = item.jsonObject["date"]!!.jsonPrimitive.content.toLong()
            }
        }

    override fun pageListParse(response: Response): List<Page> =
        json.parseToJsonElement(response.body.string()).jsonArray.mapIndexed { i, item ->
            // Odd pages give only a page URL, so the host has to ask for the image URL.
            val url = item.jsonPrimitive.content
            if (i % 2 == 0) Page(i, imageUrl = url) else Page(i, url = url)
        }

    override fun imageUrlParse(response: Response): String = response.body.string().trim()

    override fun getFilterList() =
        FilterList(
            Filter.Header("Filters"),
            GenreFilter(),
            CompletedFilter(),
            GroupFilter(listOf(TagFilter("a"), TagFilter("b"))),
            OrderFilter(),
        )

    class GenreFilter : Filter.Select<String>("Genre", arrayOf("all", "action", "romance"))

    class CompletedFilter : Filter.CheckBox("Completed")

    class TagFilter(
        name: String,
    ) : Filter.CheckBox(name)

    class GroupFilter(
        tags: List<TagFilter>,
    ) : Filter.Group<TagFilter>("Tags", tags)

    class OrderFilter : Filter.Sort("Order", arrayOf("updated", "views"), Selection(0, false))

    override fun setupPreferenceScreen(screen: PreferenceScreen) {
        ListPreference(screen.context).apply {
            key = SORT
            title = "Popular order"
            summary = "%s"
            entries = arrayOf("Hot", "New")
            entryValues = arrayOf("hot", "new")
            setDefaultValue("hot")
        }.also(screen::addPreference)
        SwitchPreferenceCompat(screen.context).apply {
            key = LOCKED
            title = "Locked switch"
            setDefaultValue(false)
            setOnPreferenceChangeListener { _, _ ->
                Toast.makeText(screen.context, "cannot change", Toast.LENGTH_SHORT).show()
                false
            }
        }.also(screen::addPreference)
    }

    companion object {
        const val BASE_URL = "base_url"
        const val SORT = "sort"
        const val LOCKED = "locked"

        /** A search for "webview:<url>" loads the URL in a WebView instead (webViewProbe). */
        const val WEBVIEW = "webview:"
    }
}
