package com.gallery.reader.exthost.android

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import android.webkit.CookieManager
import androidx.preference.PreferenceManager
import androidx.preference.PreferenceScreen
import com.gallery.reader.exthost.HostPlatform
import dalvik.system.PathClassLoader
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import java.io.File

/** The host on Android: extensions load as they are, on the system's runtime. */
class AndroidPlatform(
    private val context: Context,
    override val dataDir: File,
) : HostPlatform {
    override val application: Application = context.applicationContext as Application

    override val cookieJar: CookieJar = WebViewCookieJar()

    override fun classLoader(
        apk: File,
        workDir: File,
    ): ClassLoader {
        // Android 14 refuses to load code from a writable file.
        apk.setReadOnly()
        return PathClassLoader(apk.absolutePath, null, javaClass.classLoader)
    }

    override fun createPreferenceScreen(
        name: String,
        preferences: SharedPreferences,
    ): PreferenceScreen {
        val manager = PreferenceManager(context)
        manager.sharedPreferencesName = name
        manager.sharedPreferencesMode = Context.MODE_PRIVATE
        return manager.createPreferenceScreen(context)
    }

    override fun log(message: String) {
        Log.i("ExtHost", message)
    }
}

/** OkHttp's cookies kept by WebView's CookieManager, as Tachiyomi does, so pages and requests share them. */
class WebViewCookieJar : CookieJar {
    private val manager: CookieManager by lazy { CookieManager.getInstance() }

    override fun saveFromResponse(
        url: HttpUrl,
        cookies: List<Cookie>,
    ) {
        val target = url.toString()
        cookies.forEach { manager.setCookie(target, it.toString()) }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> =
        manager
            .getCookie(url.toString())
            ?.split(';')
            ?.mapNotNull { Cookie.parse(url, it.trim()) }
            .orEmpty()
}
