package com.gallery.reader.exthost.server

import com.gallery.reader.exthost.HostPlatform
import com.gallery.reader.exthost.codec.FilterCodec
import com.gallery.reader.exthost.codec.MangaCodec
import com.gallery.reader.exthost.codec.PreferenceCodec
import com.gallery.reader.exthost.codec.PreferenceStore
import com.gallery.reader.exthost.codec.asObject
import com.gallery.reader.exthost.codec.string
import com.gallery.reader.exthost.extension.ExtensionException
import com.gallery.reader.exthost.extension.ExtensionStore
import com.gallery.reader.exthost.net.HostProxySelector
import com.gallery.reader.exthost.net.PersistentCookieJar
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Response as OkResponse
import java.io.File

/**
 * The host's HTTP interface. JSON in and out, except the image endpoints,
 * which answer with the image bytes so the reader can load them by URL.
 */
class Api(
    private val platform: HostPlatform,
    private val store: ExtensionStore,
    private val network: NetworkHelper,
    private val proxy: HostProxySelector,
) {
    fun handle(request: Request): Response =
        try {
            route(request)
        } catch (e: HttpException) {
            error(502, "HTTP ${e.code}", "http", e.code)
        } catch (e: ExtensionException) {
            error(400, e.message ?: e.toString(), "extension")
        } catch (e: IllegalArgumentException) {
            error(400, e.message ?: e.toString(), "request")
        } catch (e: Exception) {
            platform.log("${request.path}: ${e.stackTraceToString()}")
            error(500, e.toString(), "source")
        } catch (e: LinkageError) {
            // An extension called something this host does not provide.
            platform.log("${request.path}: ${e.stackTraceToString()}")
            error(500, e.toString(), "unsupported")
        }

    private fun route(request: Request): Response {
        val get = request.method == "GET" || request.method == "HEAD"
        return when {
            get && request.path == "/ping" -> ok(buildJsonObject { put("ok", true); put("api", API_VERSION) })
            get && request.path == "/extensions" -> ok(JsonObject(mapOf("extensions" to JsonArray(store.list().map { it.toJson() }))))
            get && request.path == "/extensions/icon" -> icon(request.query["pkg"].orEmpty())
            get && request.path == "/image" -> image(request)
            get && request.path == "/cover" -> cover(request)
            request.method == "POST" -> post(request.path, parse(request.body))
            else -> error(404, "no route ${request.method} ${request.path}", "request")
        }
    }

    private fun post(
        path: String,
        body: JsonObject,
    ): Response =
        when (path) {
            "/config" -> {
                proxy.set(body.string("proxy"))
                body.string("userAgent")?.takeIf { it.isNotBlank() }?.let { network.userAgent = it }
                ok(buildJsonObject { put("proxy", proxy.spec) })
            }
            "/extensions/install" -> {
                val file = File(body.string("path") ?: throw IllegalArgumentException("path is required"))
                if (!file.isFile) throw IllegalArgumentException("no file at ${file.path}")
                ok(store.install(file).toJson())
            }
            "/extensions/uninstall" -> {
                store.uninstall(body.string("pkg") ?: throw IllegalArgumentException("pkg is required"))
                ok(JsonObject(emptyMap()))
            }
            "/source/popular" -> {
                val source = source(body)
                ok(MangaCodec.encode(runBlocking { source.getPopularManga(page(body)) }))
            }
            "/source/latest" -> {
                val source = source(body)
                if (!source.supportsLatest) throw IllegalArgumentException("${source.name} has no latest list")
                ok(MangaCodec.encode(runBlocking { source.getLatestUpdates(page(body)) }))
            }
            "/source/search" -> {
                val source = source(body)
                val filters = source.getFilterList()
                (body["filters"] as? JsonArray)?.let { FilterCodec.apply(filters, it) }
                ok(MangaCodec.encode(runBlocking { source.getSearchManga(page(body), body.string("query").orEmpty(), filters) }))
            }
            "/source/filters" -> ok(JsonObject(mapOf("filters" to FilterCodec.encode(source(body).getFilterList()))))
            "/manga/details" -> {
                val source = source(body)
                val manga = MangaCodec.decodeManga(body["manga"].asObject())
                val update = runBlocking { source.getMangaUpdate(manga, emptyList(), fetchDetails = true, fetchChapters = false) }
                ok(MangaCodec.encode(MangaCodec.merge(manga, update.manga)))
            }
            "/manga/chapters" -> {
                val source = source(body)
                val manga = MangaCodec.decodeManga(body["manga"].asObject())
                val update = runBlocking { source.getMangaUpdate(manga, emptyList(), fetchDetails = false, fetchChapters = true) }
                ok(JsonObject(mapOf("chapters" to JsonArray(update.chapters.map(MangaCodec::encode)))))
            }
            "/manga/web-url" -> {
                val source = source(body) as? HttpSource ?: throw IllegalArgumentException("not a web source")
                val manga = MangaCodec.decodeManga(body["manga"].asObject())
                ok(buildJsonObject { put("url", source.getMangaUrl(manga)) })
            }
            "/chapter/pages" -> {
                val source = source(body)
                val chapter = MangaCodec.decodeChapter(body["chapter"].asObject())
                val pages = runBlocking { source.getPageList(chapter) }
                ok(JsonObject(mapOf("pages" to JsonArray(pages.map(MangaCodec::encode)))))
            }
            "/page/image-url" -> {
                val source = source(body) as? HttpSource ?: throw IllegalArgumentException("not a web source")
                val page = MangaCodec.decodePage(body["page"].asObject())
                ok(buildJsonObject { put("imageUrl", runBlocking { source.getImageUrl(page) }) })
            }
            "/source/preferences" -> ok(JsonObject(mapOf("preferences" to preferences(body, null))))
            "/source/preferences/set" -> {
                val key = body.string("key") ?: throw IllegalArgumentException("key is required")
                val value = body["value"] ?: throw IllegalArgumentException("value is required")
                ok(JsonObject(mapOf("preferences" to preferences(body, key to value))))
            }
            "/source/preference-store" -> {
                val source = source(body) as? ConfigurableSource ?: throw IllegalArgumentException("source has no settings")
                ok(JsonObject(mapOf("values" to PreferenceStore.read(source.getSourcePreferences()))))
            }
            "/source/preference-store/set" -> {
                val source = source(body) as? ConfigurableSource ?: throw IllegalArgumentException("source has no settings")
                PreferenceStore.write(source.getSourcePreferences(), body["values"].asObject())
                store.extensionOf(source.id)?.let { store.unload(it.pkg) }
                ok(JsonObject(emptyMap()))
            }
            "/cookies/clear" -> {
                (network.cookieJar as? PersistentCookieJar)?.clear()
                ok(JsonObject(emptyMap()))
            }
            else -> error(404, "no route POST $path", "request")
        }

    private fun preferences(
        body: JsonObject,
        change: Pair<String, JsonElement>?,
    ): JsonArray {
        val source = source(body) as? ConfigurableSource ?: throw IllegalArgumentException("source has no settings")
        val name = "source_${source.id}"
        val screen = platform.createPreferenceScreen(name, source.getSourcePreferences())
        source.setupPreferenceScreen(screen)
        if (change != null && PreferenceCodec.set(screen, change.first, change.second)) {
            // Extensions read their settings when created; the next request gets new source objects.
            store.extensionOf(source.id)?.let { store.unload(it.pkg) }
        }
        return PreferenceCodec.encode(screen)
    }

    private fun image(request: Request): Response {
        val source = httpSource(request.query["source"])
        val imageUrl = request.query["url"]?.takeIf { it.isNotEmpty() }
        val page = Page(request.query["index"]?.toIntOrNull() ?: 0, request.query["page"].orEmpty(), imageUrl)
        if (page.imageUrl == null) page.imageUrl = runBlocking { source.getImageUrl(page) }
        return bytes(runBlocking { source.getImage(page) })
    }

    private fun cover(request: Request): Response {
        val source = httpSource(request.query["source"])
        val url = request.query["url"] ?: throw IllegalArgumentException("url is required")
        return bytes(runBlocking { source.client.newCall(GET(url, source.headers)).awaitSuccess() })
    }

    private fun bytes(response: OkResponse): Response =
        response.use {
            val data = it.body.bytes()
            val type = it.header("Content-Type")?.takeIf { t -> t.startsWith("image/") } ?: sniff(data)
            Response(200, type, data, mapOf("Cache-Control" to "no-store"))
        }

    private fun icon(pkg: String): Response {
        val file = store.icon(pkg) ?: return error(404, "no icon", "request")
        return Response(200, "image/png", file.readBytes())
    }

    private fun source(body: JsonObject): CatalogueSource = store.source(sourceId(body.string("source")))

    private fun httpSource(id: String?): HttpSource = store.source(sourceId(id)) as? HttpSource ?: throw IllegalArgumentException("not a web source")

    private fun sourceId(id: String?): Long = id?.toLongOrNull() ?: throw IllegalArgumentException("source is required")

    private fun page(body: JsonObject): Int = body["page"]?.jsonPrimitive?.intOrNull ?: 1

    private fun parse(body: ByteArray): JsonObject =
        if (body.isEmpty()) JsonObject(emptyMap()) else Json.parseToJsonElement(body.decodeToString()).asObject()

    private fun ok(json: JsonElement) = Response.json(200, json.toString())

    private fun error(
        status: Int,
        message: String,
        kind: String,
        httpCode: Int? = null,
    ) = Response.json(
        status,
        buildJsonObject {
            put("error", message)
            put("kind", kind)
            if (httpCode != null) put("httpCode", httpCode)
        }.toString(),
    )

    companion object {
        const val API_VERSION = 1

        fun sniff(data: ByteArray): String {
            fun at(
                i: Int,
                vararg b: Int,
            ) = data.size >= i + b.size && b.indices.all { data[i + it] == b[it].toByte() }
            return when {
                at(0, 0xFF, 0xD8, 0xFF) -> "image/jpeg"
                at(0, 0x89, 0x50, 0x4E, 0x47) -> "image/png"
                at(0, 0x47, 0x49, 0x46) -> "image/gif"
                at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50) -> "image/webp"
                at(4, 0x66, 0x74, 0x79, 0x70) -> "image/avif"
                else -> "application/octet-stream"
            }
        }
    }
}
