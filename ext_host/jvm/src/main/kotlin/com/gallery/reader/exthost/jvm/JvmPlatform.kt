package com.gallery.reader.exthost.jvm

import android.app.Application
import android.content.SharedPreferences
import androidx.preference.PreferenceScreen
import com.gallery.reader.exthost.HostPlatform
import com.gallery.reader.exthost.compat.Bridges
import com.gallery.reader.exthost.net.PersistentCookieJar
import okhttp3.CookieJar
import java.io.File
import java.net.URLClassLoader

/** The host on a JVM: desktop through a bundled runtime, iOS through OpenJDK in the app. */
open class JvmPlatform(
    final override val dataDir: File,
) : HostPlatform {
    final override val application = Application(dataDir)

    private val cookies = PersistentCookieJar(File(dataDir, "cookies.json"))

    final override val cookieJar: CookieJar = cookies

    init {
        Bridges.cookies =
            object : Bridges.Cookies {
                override fun get(url: String): String? = cookies.header(url)

                override fun set(
                    url: String,
                    setCookie: String,
                ) = cookies.set(url, setCookie)

                override fun removeAll() = cookies.clear()
            }
    }

    override fun prepare(
        apk: File,
        workDir: File,
    ) {
        val result = DexConverter.convert(apk, File(workDir, CLASSES))
        log("converted ${apk.parentFile?.name}: ${result.classes} classes (${result.fixedClasses} with interface calls fixed) in ${result.millis} ms")
        result.failedMethods.forEach { log("not translated: $it") }
    }

    override fun classLoader(
        apk: File,
        workDir: File,
    ): ClassLoader {
        val jar = File(workDir, CLASSES)
        if (!jar.isFile || jar.lastModified() < apk.lastModified()) prepare(apk, workDir)
        return URLClassLoader(arrayOf(jar.toURI().toURL()), javaClass.classLoader)
    }

    override fun releaseClassLoader(loader: ClassLoader) {
        (loader as? URLClassLoader)?.close()
    }

    override fun createPreferenceScreen(
        name: String,
        preferences: SharedPreferences,
    ): PreferenceScreen = PreferenceScreen(application, preferences)

    companion object {
        const val CLASSES = "classes.jar"
    }
}
