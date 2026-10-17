package com.gallery.reader.exthost.jvm

import com.gallery.reader.exthost.ExtHost
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.system.exitProcess

/**
 * Desktop entry. The app starts `java -XX:+UnlockDiagnosticVMOptions
 * -XX:-BytecodeVerificationRemote -jar exthost.jar` and writes one line of JSON to its standard input:
 * `{"dataDir": ..., "token": ..., "proxy": ...}`. The host answers on standard
 * output with `{"port": N}` and exits when its standard input closes, which
 * happens when the app quits.
 *
 * Extension classes are loaded without bytecode verification, as dex2jar's
 * output refers to Android classes this host does not provide; those are
 * only resolved, and fail, when an extension actually calls them.
 */
fun main() {
    val line = readlnOrNull() ?: exitProcess(2)
    val running = start(line)
    println("""{"port":${running.port}}""")
    System.out.flush()
    while (System.`in`.read() >= 0) {
        // Keep running until the app closes the pipe.
    }
    exitProcess(0)
}

/** Starts the host from its JSON configuration; iOS calls this through JNI. */
fun start(config: String): ExtHost.Running {
    val json = Json.parseToJsonElement(config).jsonObject
    fun string(key: String) = (json[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
    val dataDir = File(string("dataDir") ?: error("dataDir is required")).apply { mkdirs() }
    return ExtHost.start(
        platform = JvmPlatform(dataDir),
        token = string("token") ?: error("token is required"),
        proxySpec = string("proxy"),
        port = json["port"]?.jsonPrimitive?.intOrNull ?: 0,
    )
}

/** For JNI callers: returns the port. */
object Embedded {
    @JvmStatic
    fun start(config: String): Int = com.gallery.reader.exthost.jvm.start(config).port

    @JvmStatic
    fun restartServer(): Int = ExtHost.running?.server?.restart() ?: -1
}
