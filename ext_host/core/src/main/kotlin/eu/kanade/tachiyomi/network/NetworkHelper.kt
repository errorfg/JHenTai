package eu.kanade.tachiyomi.network

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import okhttp3.Cache
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import java.io.File
import java.net.ProxySelector
import java.util.concurrent.TimeUnit

/**
 * The HTTP client extensions build on (`network.client`). Cookies, proxy and
 * any platform transport come from the host; the interceptor order follows
 * Tachiyomi's so extension interceptors see requests the same way.
 */
class NetworkHelper(
    context: Context,
    val cookieJar: CookieJar,
    proxySelector: ProxySelector,
    configure: (OkHttpClient.Builder) -> Unit = {},
) {
    @Volatile
    var userAgent: String = DEFAULT_USER_AGENT

    fun defaultUserAgentProvider(): String = userAgent

    val client: OkHttpClient =
        OkHttpClient
            .Builder()
            .cookieJar(cookieJar)
            .proxySelector(proxySelector)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(2, TimeUnit.MINUTES)
            .cache(Cache(File(context.cacheDir, "network_cache"), 5L * 1024 * 1024))
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
            .also(configure)
            .build()

    @Deprecated("The regular client handles Cloudflare by default")
    @Suppress("UNUSED")
    val cloudflareClient: OkHttpClient
        get() = client

    companion object {
        const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 11; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
    }
}
