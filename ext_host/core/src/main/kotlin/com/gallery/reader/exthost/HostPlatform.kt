package com.gallery.reader.exthost

import android.app.Application
import android.content.SharedPreferences
import androidx.preference.PreferenceScreen
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import java.io.File

/**
 * What differs between the places the host runs. On Android extensions are
 * loaded as they are; on the JVM (desktop, and iOS through OpenJDK) their
 * dex code is converted to JVM classes first and the Android classes they use
 * come from the compat module.
 */
interface HostPlatform {
    val application: Application

    /** Where installed extensions, their settings and cookies are kept. */
    val dataDir: File

    val cookieJar: CookieJar

    /** Runs once when an extension is installed; the JVM converts the dex code here. */
    fun prepare(
        apk: File,
        workDir: File,
    ) {}

    fun classLoader(
        apk: File,
        workDir: File,
    ): ClassLoader

    fun releaseClassLoader(loader: ClassLoader) {}

    fun createPreferenceScreen(
        name: String,
        preferences: SharedPreferences,
    ): PreferenceScreen

    /** Lets a platform change how requests are carried, e.g. iOS's native networking. */
    fun configureClient(builder: OkHttpClient.Builder) {}

    fun log(message: String) {
        System.err.println("ExtHost: $message")
    }
}
