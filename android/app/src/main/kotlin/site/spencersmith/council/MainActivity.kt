package site.spencersmith.council

import android.app.ActivityManager
import android.content.Context
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Physical memory, so the app can stop offering a 2.1 GB model to a
        // phone that cannot hold it. Dart cannot read this portably, and one
        // method is cheaper than a dependency.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site.spencersmith.council/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "totalMemoryMb" -> {
                    val manager =
                        getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val info = ActivityManager.MemoryInfo()
                    manager.getMemoryInfo(info)
                    // totalMem is what the OS reports as installed, not what is
                    // free right now: the question is what the device can ever
                    // hold, not what it happens to have spare while a settings
                    // screen is open.
                    result.success((info.totalMem / (1024L * 1024L)).toInt())
                }
                "freeDiskMb" -> {
                    // Measured on the directory the model is actually written
                    // to, not on the root volume: adopted storage and separate
                    // data partitions make those different numbers on plenty
                    // of devices.
                    val stat = StatFs(filesDir.absolutePath)
                    val free = stat.availableBlocksLong * stat.blockSizeLong
                    result.success((free / (1024L * 1024L)).toInt())
                }
                else -> result.notImplemented()
            }
        }
    }
}
