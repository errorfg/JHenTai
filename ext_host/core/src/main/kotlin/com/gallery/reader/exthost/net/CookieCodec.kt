package com.gallery.reader.exthost.net

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Cookies between the host and a browser engine: each one a Set-Cookie
 * value with the URL it applies to, `{"url": ..., "setCookie": ...}`. A
 * cookie without a Domain attribute belongs to that URL's host only.
 */
object CookieCodec {
    /** What [jar] would send to [url]. */
    fun export(
        jar: CookieJar,
        url: String,
    ): JsonArray {
        val httpUrl = url.toHttpUrlOrNull() ?: return JsonArray(emptyList())
        return JsonArray(jar.loadForRequest(httpUrl).map(::encode))
    }

    fun encode(cookie: Cookie): JsonObject =
        buildJsonObject {
            put("url", "${if (cookie.secure) "https" else "http"}://${cookie.domain}${cookie.path}")
            put("setCookie", cookie.toString())
        }

    /** Stores cookies given as [export] gives them; returns how many were stored. */
    fun import(
        jar: CookieJar,
        entries: JsonArray,
    ): Int {
        var stored = 0
        for (entry in entries) {
            val fields = entry as? JsonObject ?: continue
            val url = (fields["url"] as? JsonPrimitive)?.contentOrNull?.toHttpUrlOrNull() ?: continue
            val cookie = (fields["setCookie"] as? JsonPrimitive)?.contentOrNull?.let { Cookie.parse(url, it) } ?: continue
            jar.saveFromResponse(url, listOf(cookie))
            stored++
        }
        return stored
    }
}
