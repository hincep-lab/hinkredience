package cz.hink.hinkredience

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Chytré aktualizace: složka pro stažené APK, typ připojení a
        // otevření systémové instalace (lib/core/app_update.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cz.hink.hinkredience/update")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "directory" -> result.success(updatesDir().absolutePath)
                        "metered" -> {
                            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                            result.success(cm.isActiveNetworkMetered)
                        }
                        "install" -> result.success(install(call.argument<String>("path") ?: ""))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("update", e.message, null)
                }
            }
    }

    private fun updatesDir(): File = File(filesDir, "updates").apply { mkdirs() }

    private fun install(path: String): String {
        val file = File(path)
        // Jen soubory z vlastní složky aktualizací.
        if (!file.exists() || file.parentFile?.canonicalPath != updatesDir().canonicalPath) {
            return "missing"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return "permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "started"
    }
}
