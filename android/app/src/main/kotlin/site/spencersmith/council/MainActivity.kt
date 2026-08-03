package site.spencersmith.council

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

        // Installing a downloaded update. Android is the only platform that
        // needs native code for this: the package installer will not accept a
        // file path, only a content:// URI from a FileProvider, and only from
        // an Activity.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site.spencersmith.council/updates",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> installApk(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("no_path", "No installer path was given.", null)
            return
        }
        val apk = File(path)
        if (!apk.exists()) {
            result.error("missing", "The downloaded installer is gone.", null)
            return
        }

        try {
            // Since Oreo this is a per-app switch the reader has to throw in
            // Settings, and the intent below does *nothing* without it — no
            // dialog, no error, no installer. Sending them to the right page is
            // the difference between an update that works and a button that
            // appears to do nothing at all.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success("permission")
                return
            }

            // A file:// URI would throw FileUriExposedException on anything
            // since Nougat, which is every device this app runs on.
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.updates",
                apk,
            )
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_ACTIVITY_NEW_TASK,
                    )
                },
            )
            result.success("installing")
        } catch (e: Exception) {
            result.error("install_failed", e.message, null)
        }
    }
}
