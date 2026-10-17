package com.gallery.reader.exthost

import android.app.Application
import com.gallery.reader.exthost.extension.ExtensionStore
import com.gallery.reader.exthost.net.HostProxySelector
import com.gallery.reader.exthost.server.Api
import com.gallery.reader.exthost.server.HttpServer
import eu.kanade.tachiyomi.network.NetworkHelper
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton

/**
 * Starts the extension host: registers what extensions look up through
 * Injekt, then serves the API on a loopback port. One host per process.
 */
object ExtHost {
    class Running(
        val port: Int,
        val server: HttpServer,
        val store: ExtensionStore,
        val proxy: HostProxySelector,
    )

    @Volatile
    var running: Running? = null
        private set

    @Synchronized
    fun start(
        platform: HostPlatform,
        token: String,
        proxySpec: String? = null,
        port: Int = 0,
    ): Running {
        running?.let { return it }
        val started = System.currentTimeMillis()
        val proxy = HostProxySelector().apply { set(proxySpec) }
        val network = NetworkHelper(platform.application, platform.cookieJar, proxy, platform::configureClient)
        Injekt.addSingleton<Application>(platform.application)
        Injekt.addSingleton<NetworkHelper>(network)
        Injekt.addSingleton<Json>(
            Json {
                ignoreUnknownKeys = true
                explicitNulls = false
            },
        )
        val store = ExtensionStore(platform)
        val server = HttpServer(token, Api(platform, store, network, proxy)::handle)
        val bound = server.start(port)
        platform.log("listening on 127.0.0.1:$bound, ${store.list().size} extensions, started in ${System.currentTimeMillis() - started} ms")
        return Running(bound, server, store, proxy).also { running = it }
    }
}
