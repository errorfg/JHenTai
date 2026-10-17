package com.gallery.reader.exthost.net

import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/**
 * Follows the app's proxy setting, which can change while the host runs.
 * Spec: `http://host:port`, `socks5://host:port`, or empty for a direct connection.
 */
class HostProxySelector : ProxySelector() {
    @Volatile
    private var proxy: Proxy = Proxy.NO_PROXY

    @Volatile
    var spec: String = ""
        private set

    fun set(spec: String?) {
        val value = spec?.trim().orEmpty()
        proxy =
            if (value.isEmpty()) {
                Proxy.NO_PROXY
            } else {
                val uri = URI(value)
                val type =
                    when (uri.scheme?.lowercase()) {
                        "http", "https" -> Proxy.Type.HTTP
                        "socks", "socks5", "socks4" -> Proxy.Type.SOCKS
                        else -> throw IllegalArgumentException("unknown proxy $value")
                    }
                Proxy(type, InetSocketAddress.createUnresolved(uri.host, uri.port))
            }
        this.spec = value
    }

    override fun select(uri: URI): List<Proxy> {
        val host = uri.host ?: return listOf(Proxy.NO_PROXY)
        if (host == "localhost" || host == "[::1]" || (host.first().isDigit() && runCatching { InetAddress.getByName(host).isLoopbackAddress }.getOrDefault(false))) {
            return listOf(Proxy.NO_PROXY)
        }
        return listOf(proxy)
    }

    override fun connectFailed(
        uri: URI,
        sa: SocketAddress,
        ioe: IOException,
    ) {}
}
