package com.example.offline_ai_chat

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "offline_ai/model_installer"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "installModel") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val assetName = call.argument<String>("assetName")
                val destPath = call.argument<String>("destPath")
                if (assetName == null || destPath == null) {
                    result.error("bad_args", "assetName and destPath are required", null)
                    return@setMethodCallHandler
                }

                Thread {
                    try {
                        val destination = File(destPath)
                        destination.parentFile?.mkdirs()
                        if (destination.exists()) destination.delete()

                        applicationContext.assets.open(assetName).use { input ->
                            FileOutputStream(destination).use { output ->
                                val buffer = ByteArray(1024 * 1024)
                                while (true) {
                                    val read = input.read(buffer)
                                    if (read <= 0) break
                                    output.write(buffer, 0, read)
                                }
                                output.flush()
                            }
                        }

                        Handler(Looper.getMainLooper()).post { result.success(true) }
                    } catch (error: Exception) {
                        Handler(Looper.getMainLooper()).post {
                            result.error("copy_failed", error.message, null)
                        }
                    }
                }.start()
            }
    }
}
