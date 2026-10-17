package com.gallery.reader.exthost.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.gallery.reader.exthost.ExtHost
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/** Starts the host in the app's process when the app asks for it. */
class TachiHostPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.gallery.reader/exthost")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "start" -> {
                val config = JSONObject(call.arguments as String)
                thread(name = "exthost-start") {
                    try {
                        val running =
                            ExtHost.start(
                                platform = AndroidPlatform(context, File(config.getString("dataDir")).apply { mkdirs() }),
                                token = config.getString("token"),
                                proxySpec = config.optString("proxy"),
                            )
                        main.post { result.success(running.port) }
                    } catch (e: Throwable) {
                        main.post { result.error("start", e.toString(), null) }
                    }
                }
            }
            "restartServer" -> thread(name = "exthost-restart") {
                val port = ExtHost.running?.server?.restart() ?: -1
                main.post { result.success(port) }
            }
            else -> result.notImplemented()
        }
    }
}
