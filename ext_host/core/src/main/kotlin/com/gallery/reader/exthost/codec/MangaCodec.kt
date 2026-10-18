package com.gallery.reader.exthost.codec

import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Manga, chapters and pages as the JSON the app reads. */
object MangaCodec {
    // SManga and SChapter use lateinit fields an extension may leave unset.
    private inline fun <T> field(read: () -> T): T? =
        try {
            read()
        } catch (_: UninitializedPropertyAccessException) {
            null
        }

    fun encode(manga: SManga): JsonObject =
        buildJsonObject {
            put("url", field { manga.url }.orEmpty())
            put("title", field { manga.title }.orEmpty())
            put("thumbnailUrl", manga.thumbnail_url)
            put("artist", manga.artist)
            put("author", manga.author)
            put("description", manga.description)
            put("genre", manga.genre)
            put("status", manga.status)
            put("initialized", manga.initialized)
            put("updateStrategy", manga.update_strategy.name)
        }

    fun decodeManga(json: JsonObject): SManga =
        SManga.create().apply {
            url = json.string("url").orEmpty()
            title = json.string("title").orEmpty()
            thumbnail_url = json.string("thumbnailUrl")
            artist = json.string("artist")
            author = json.string("author")
            description = json.string("description")
            genre = json.string("genre")
            status = json["status"]?.jsonPrimitive?.intOrNull ?: SManga.UNKNOWN
            initialized = json["initialized"]?.jsonPrimitive?.booleanOrNull ?: false
            update_strategy = json.string("updateStrategy")?.let { name -> UpdateStrategy.entries.firstOrNull { it.name == name } } ?: UpdateStrategy.ALWAYS_UPDATE
        }

    /**
     * Details an extension parsed, laid over the manga the app sent, as
     * Tachiyomi does: the parse rarely sets the URL, and fields it leaves
     * empty keep their earlier values.
     */
    fun merge(
        base: SManga,
        details: SManga,
    ): SManga =
        base.copy().apply {
            field { details.url }?.takeIf { it.isNotEmpty() }?.let { url = it }
            field { details.title }?.takeIf { it.isNotEmpty() }?.let { title = it }
            details.author?.let { author = it }
            details.artist?.let { artist = it }
            details.description?.let { description = it }
            details.genre?.let { genre = it }
            details.thumbnail_url?.let { thumbnail_url = it }
            status = details.status
            update_strategy = details.update_strategy
            initialized = true
        }

    fun encode(page: MangasPage): JsonObject =
        JsonObject(
            mapOf(
                "mangas" to JsonArray(page.mangas.map(::encode)),
                "hasNextPage" to JsonPrimitive(page.hasNextPage),
            ),
        )

    fun encode(chapter: SChapter): JsonObject =
        buildJsonObject {
            put("url", field { chapter.url }.orEmpty())
            put("name", field { chapter.name }.orEmpty())
            put("dateUpload", chapter.date_upload)
            put("chapterNumber", chapter.chapter_number)
            put("scanlator", chapter.scanlator)
        }

    fun decodeChapter(json: JsonObject): SChapter =
        SChapter.create().apply {
            url = json.string("url").orEmpty()
            name = json.string("name").orEmpty()
            date_upload = json["dateUpload"]?.jsonPrimitive?.longOrNull ?: 0
            chapter_number = json["chapterNumber"]?.jsonPrimitive?.floatOrNull ?: -1f
            scanlator = json.string("scanlator")
        }

    fun encode(page: Page): JsonObject =
        buildJsonObject {
            put("index", page.index)
            put("url", page.url)
            put("imageUrl", page.imageUrl)
        }

    fun decodePage(json: JsonObject): Page =
        Page(
            index = json["index"]?.jsonPrimitive?.intOrNull ?: 0,
            url = json.string("url").orEmpty(),
            imageUrl = json.string("imageUrl"),
        )
}

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull

internal fun JsonElement?.asObject(): JsonObject = this as? JsonObject ?: throw IllegalArgumentException("expected a JSON object")
