package com.gallery.reader.exthost.jvm

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException

/**
 * Carries one HTTP exchange outside the JVM. [meta] is JSON:
 * `{"url", "method", "headers": [[name, value]...], "proxy", "timeoutMs"}`;
 * the answer is `[metaJson, body]` with
 * `{"code", "message", "headers": [[name, value]...], "url"}` or `{"error"}`.
 * Redirects are not followed and cookies not handled: OkHttp does both.
 * A body the platform decompressed comes without Content-Encoding.
 */
fun interface Transport {
    fun execute(
        meta: ByteArray,
        body: ByteArray?,
    ): Array<ByteArray?>
}

/** iOS: NSURLSession, through JNI (ext_host/flutter/ios/Classes/ExtHostNet.m). */
object NativeNet : Transport {
    @JvmStatic
    private external fun call(
        meta: ByteArray,
        body: ByteArray?,
    ): Array<ByteArray?>

    override fun execute(
        meta: ByteArray,
        body: ByteArray?,
    ): Array<ByteArray?> = call(meta, body)
}

/**
 * The first interceptor of every call. It replaces OkHttp's own connection
 * and wire exchange at the end of the call's interceptor chain with
 * [transport], so the extension's interceptors, cookies, redirects, the
 * cache and decompression all still run in OkHttp, and only the bytes travel
 * through the platform. (The chain's list is per call; changing it here
 * affects this call only.)
 */
class NativeTransportSwitch(
    private val transport: Transport,
    private val proxy: () -> String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        @Suppress("UNCHECKED_CAST")
        val interceptors =
            try {
                chain.javaClass.getDeclaredField("interceptors").apply { isAccessible = true }.get(chain) as MutableList<Interceptor>
            } catch (e: ReflectiveOperationException) {
                return chain.proceed(chain.request())
            }
        val connect = interceptors.indexOfFirst { it.javaClass.name == "okhttp3.internal.connection.ConnectInterceptor" }
        val callServer = interceptors.indexOfLast { it.javaClass.name == "okhttp3.internal.http.CallServerInterceptor" }
        if (connect >= 0 && callServer > connect) {
            interceptors[callServer] = Exchange(transport, proxy)
            interceptors.removeAt(connect)
        }
        return chain.proceed(chain.request())
    }

    private class Exchange(
        private val transport: Transport,
        private val proxy: () -> String,
    ) : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val sentAt = System.currentTimeMillis()
            val body =
                request.body?.let { b ->
                    Buffer().also { b.writeTo(it) }.readByteArray()
                }
            val meta =
                buildJsonObject {
                    put("url", request.url.toString())
                    put("method", request.method)
                    put(
                        "headers",
                        JsonArray(
                            buildList {
                                for (i in 0 until request.headers.size) add(JsonArray(listOf(JsonPrimitive(request.headers.name(i)), JsonPrimitive(request.headers.value(i)))))
                                val type = request.body?.contentType()
                                if (type != null && request.header("Content-Type") == null) add(JsonArray(listOf(JsonPrimitive("Content-Type"), JsonPrimitive(type.toString()))))
                            },
                        ),
                    )
                    put("proxy", proxy())
                    put("timeoutMs", chain.readTimeoutMillis().coerceAtLeast(chain.connectTimeoutMillis()).toLong().takeIf { it > 0 } ?: 30_000L)
                }
            val answer =
                try {
                    transport.execute(meta.toString().toByteArray(), body)
                } catch (e: Throwable) {
                    throw IOException("native request failed: $e", e)
                }
            val info = Json.parseToJsonElement(String(answer[0] ?: throw IOException("native request gave no answer"))).jsonObject
            info["error"]?.jsonPrimitive?.contentOrNull?.let { throw IOException(it) }
            val headers =
                Headers
                    .Builder()
                    .apply {
                        info["headers"]?.jsonArray?.forEach { pair ->
                            val (name, value) = pair.jsonArray.map { it.jsonPrimitive.content }
                            addUnsafeNonAscii(name, value)
                        }
                    }.build()
            val data = answer[1] ?: ByteArray(0)
            return Response
                .Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(info["code"]?.jsonPrimitive?.intOrNull ?: 500)
                .message(info["message"]?.jsonPrimitive?.contentOrNull.orEmpty())
                .headers(headers)
                .body(data.toResponseBody(headers["Content-Type"]?.toMediaTypeOrNull()))
                .sentRequestAtMillis(sentAt)
                .receivedResponseAtMillis(System.currentTimeMillis())
                .build()
        }
    }
}
