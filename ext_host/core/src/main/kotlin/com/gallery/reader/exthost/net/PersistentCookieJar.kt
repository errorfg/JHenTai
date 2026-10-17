package com.gallery.reader.exthost.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.util.concurrent.Executors

/**
 * Cookies shared by every extension, kept in one file as Set-Cookie strings
 * with their host. Also answers android.webkit.CookieManager on the JVM.
 */
class PersistentCookieJar(
    private val file: File,
) : CookieJar {
    private val lock = Any()
    private val cookies = mutableListOf<Cookie>()

    init {
        if (file.exists()) {
            try {
                Json.parseToJsonElement(file.readText()).jsonArray.forEach { element ->
                    val (url, header) = element.jsonArray.map { it.jsonPrimitive.content }
                    url.toHttpUrlOrNull()?.let { Cookie.parse(it, header) }?.takeIf { it.expiresAt > System.currentTimeMillis() }?.let(cookies::add)
                }
            } catch (e: Exception) {
                System.err.println("PersistentCookieJar: cannot read ${file.path}: $e")
            }
        }
    }

    override fun saveFromResponse(
        url: HttpUrl,
        cookies: List<Cookie>,
    ) {
        if (cookies.isEmpty()) return
        synchronized(lock) {
            for (cookie in cookies) {
                this.cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
                if (cookie.expiresAt > System.currentTimeMillis()) this.cookies.add(cookie)
            }
        }
        save()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        return synchronized(lock) {
            cookies.removeAll { it.expiresAt <= now }
            cookies.filter { it.matches(url) }
        }
    }

    /** The Cookie header value for [url], as CookieManager.getCookie gives it. */
    fun header(url: String): String? =
        url.toHttpUrlOrNull()?.let(::loadForRequest)?.takeIf { it.isNotEmpty() }?.joinToString("; ") { "${it.name}=${it.value}" }

    fun set(
        url: String,
        setCookie: String,
    ) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        Cookie.parse(httpUrl, setCookie)?.let { saveFromResponse(httpUrl, listOf(it)) }
    }

    fun clear() {
        synchronized(lock) { cookies.clear() }
        save()
    }

    private fun save() {
        val snapshot =
            synchronized(lock) {
                cookies.filter { it.persistent }.map { JsonArray(listOf(JsonPrimitive(urlOf(it)), JsonPrimitive(it.toString()))) }
            }
        writer.execute {
            synchronized(file) {
                file.parentFile?.mkdirs()
                File(file.path + ".tmp").apply { writeText(JsonArray(snapshot).toString()) }.renameTo(file)
            }
        }
    }

    private fun urlOf(cookie: Cookie): String = "${if (cookie.secure) "https" else "http"}://${cookie.domain}${cookie.path}"

    companion object {
        private val writer =
            Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "cookie-writer").apply { isDaemon = true } }
    }
}
