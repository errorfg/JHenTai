package com.gallery.reader.exthost.server

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class Request(
    val method: String,
    val path: String,
    val query: Map<String, String>,
    val headers: Map<String, String>,
    val body: ByteArray,
)

class Response(
    val status: Int,
    val contentType: String,
    val body: ByteArray,
    val headers: Map<String, String> = emptyMap(),
) {
    companion object {
        fun json(
            status: Int,
            text: String,
        ) = Response(status, "application/json; charset=utf-8", text.toByteArray())
    }
}

/**
 * A small HTTP/1.1 server on the loopback interface, for the app in the same
 * device. Every request must carry the token the app chose at start, as
 * `Authorization: Bearer <token>` or `?token=<token>`. Bodies are read by
 * Content-Length; responses are sent whole with Content-Length, and
 * connections are kept alive.
 */
class HttpServer(
    private val token: String,
    private val handler: (Request) -> Response,
) {
    private var socket: ServerSocket? = null
    private val workers: ExecutorService =
        Executors.newCachedThreadPool { runnable -> Thread(runnable, "exthost-http").apply { isDaemon = true } }
    private val tokenBytes = token.toByteArray()

    val port: Int get() = socket?.localPort ?: -1

    @Synchronized
    fun start(port: Int = 0): Int {
        socket?.let { if (!it.isClosed) return it.localPort }
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), port), 64)
        socket = server
        Thread({ accept(server) }, "exthost-accept").apply { isDaemon = true }.start()
        return server.localPort
    }

    /** Opens the socket again on the same port, e.g. after iOS reclaimed it in the background. */
    @Synchronized
    fun restart(): Int {
        val old = socket?.localPort ?: 0
        socket?.close()
        socket = null
        return try {
            start(old)
        } catch (_: IOException) {
            start(0)
        }
    }

    @Synchronized
    fun stop() {
        socket?.close()
        socket = null
    }

    private fun accept(server: ServerSocket) {
        while (!server.isClosed) {
            val client =
                try {
                    server.accept()
                } catch (_: SocketException) {
                    break
                } catch (e: IOException) {
                    System.err.println("ExtHost: accept failed: $e")
                    continue
                }
            workers.execute { serve(client) }
        }
    }

    private fun serve(client: Socket) {
        client.use {
            try {
                client.tcpNoDelay = true
                client.soTimeout = KEEP_ALIVE_MS
                val input = BufferedInputStream(client.getInputStream())
                val output = BufferedOutputStream(client.getOutputStream(), 64 * 1024)
                while (true) {
                    val request = read(input) ?: break
                    val response =
                        if (!authorized(request)) {
                            Response.json(401, """{"error":"unauthorized"}""")
                        } else {
                            try {
                                handler(request)
                            } catch (e: Throwable) {
                                System.err.println("ExtHost: ${request.path} failed: $e")
                                Response.json(500, """{"error":${quote(e.toString())}}""")
                            }
                        }
                    val keepAlive = !request.headers["connection"].equals("close", ignoreCase = true)
                    write(output, response, keepAlive, request.method == "HEAD")
                    if (!keepAlive) break
                }
            } catch (_: SocketTimeoutException) {
            } catch (_: SocketException) {
            } catch (e: IOException) {
                System.err.println("ExtHost: connection error: $e")
            }
        }
    }

    private fun authorized(request: Request): Boolean {
        val given = request.headers["authorization"]?.removePrefix("Bearer ")?.trim() ?: request.query["token"] ?: return false
        return MessageDigest.isEqual(given.toByteArray(), tokenBytes)
    }

    private fun read(input: InputStream): Request? {
        val requestLine = readLine(input) ?: return null
        if (requestLine.isEmpty()) return null
        val parts = requestLine.split(' ')
        if (parts.size < 3) throw IOException("bad request line")
        val headers = HashMap<String, String>()
        var headerBytes = 0
        while (true) {
            val line = readLine(input) ?: throw IOException("connection closed in headers")
            if (line.isEmpty()) break
            headerBytes += line.length
            if (headerBytes > MAX_HEADER_BYTES) throw IOException("headers too large")
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        if (length > MAX_BODY_BYTES) throw IOException("body too large")
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) throw IOException("connection closed in body")
            read += n
        }
        val target = parts[1]
        val path = target.substringBefore('?')
        val query =
            target
                .substringAfter('?', "")
                .split('&')
                .filter { it.isNotEmpty() }
                .associate { pair ->
                    URLDecoder.decode(pair.substringBefore('='), "UTF-8") to URLDecoder.decode(pair.substringAfter('=', ""), "UTF-8")
                }
        return Request(parts[0].uppercase(), URLDecoder.decode(path, "UTF-8"), query, headers, body)
    }

    private fun readLine(input: InputStream): String? {
        val line = ByteArrayOutputStream(128)
        while (true) {
            val b = input.read()
            if (b < 0) return if (line.size() == 0) null else line.toString("ISO-8859-1")
            if (b == '\n'.code) break
            if (b != '\r'.code) line.write(b)
            if (line.size() > MAX_HEADER_BYTES) throw IOException("line too long")
        }
        return line.toString("ISO-8859-1")
    }

    private fun write(
        output: OutputStream,
        response: Response,
        keepAlive: Boolean,
        head: Boolean,
    ) {
        val header = StringBuilder()
        header.append("HTTP/1.1 ").append(response.status).append(' ').append(reason(response.status)).append("\r\n")
        header.append("Content-Type: ").append(response.contentType).append("\r\n")
        header.append("Content-Length: ").append(response.body.size).append("\r\n")
        header.append("Connection: ").append(if (keepAlive) "keep-alive" else "close").append("\r\n")
        for ((name, value) in response.headers) header.append(name).append(": ").append(value).append("\r\n")
        header.append("\r\n")
        output.write(header.toString().toByteArray(Charsets.ISO_8859_1))
        if (!head) output.write(response.body)
        output.flush()
    }

    private fun reason(status: Int) =
        when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            404 -> "Not Found"
            500 -> "Internal Server Error"
            502 -> "Bad Gateway"
            else -> "Status"
        }

    companion object {
        private const val KEEP_ALIVE_MS = 120_000
        private const val MAX_HEADER_BYTES = 64 * 1024
        private const val MAX_BODY_BYTES = 8 * 1024 * 1024

        fun quote(text: String): String = kotlinx.serialization.json.JsonPrimitive(text).toString()
    }
}
