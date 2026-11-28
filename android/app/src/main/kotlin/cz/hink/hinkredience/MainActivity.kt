package cz.hink.hinkredience

import android.app.Activity
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
    private var receiptChannel: MethodChannel? = null

    /** PDF účtenky sdílené při spuštění, než si ho aplikace vyzvedne. */
    private var pendingReceipt: String? = null
    private var pickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Účtenky v PDF: sdílené z jiné aplikace (Můj Albert) nebo vybrané
        // ze souborů. Soubor se zkopíruje do mezipaměti aplikace a Dart
        // dostane jen cestu (lib/core/receipt_share.dart).
        receiptChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cz.hink.hinkredience/receipt")
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "initial" -> {
                            result.success(pendingReceipt)
                            pendingReceipt = null
                        }
                        "pick" -> {
                            pickResult?.success(null)
                            pickResult = result
                            try {
                                startActivityForResult(
                                    Intent(Intent.ACTION_OPEN_DOCUMENT)
                                        .addCategory(Intent.CATEGORY_OPENABLE)
                                        .setType("application/pdf"),
                                    PICK_RECEIPT,
                                )
                            } catch (e: Exception) {
                                pickResult = null
                                result.error("pick", e.message, null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        pendingReceipt = sharedReceipt(intent)
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val path = sharedReceipt(intent) ?: return
        val channel = receiptChannel
        if (channel == null) pendingReceipt = path else channel.invokeMethod("shared", path)
    }

    @Deprecated("Výběr souboru přes startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_RECEIPT) return
        val result = pickResult ?: return
        pickResult = null
        val uri = data?.data
        result.success(if (resultCode == Activity.RESULT_OK && uri != null) copyReceipt(uri) else null)
    }

    /** Cesta k PDF ze sdílení, nebo null (jiný typ, jiná akce). */
    private fun sharedReceipt(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "application/pdf") return null
        @Suppress("DEPRECATION")
        val uri = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        } ?: return null
        // Stejné sdílení se po návratu do aplikace nezpracuje znovu.
        intent.action = Intent.ACTION_MAIN
        return copyReceipt(uri)
    }

    /** Zkopíruje PDF (max. 10 MB) do mezipaměti; staré účtenky smaže. */
    private fun copyReceipt(uri: Uri): String? = try {
        val dir = File(cacheDir, "receipts").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, "uctenka-${System.currentTimeMillis()}.pdf")
        contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > 10L * 1024 * 1024) throw IllegalStateException("Soubor je příliš velký")
                    output.write(buffer, 0, read)
                }
            }
        } ?: return null
        file.absolutePath
    } catch (e: Exception) {
        null
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

    companion object {
        private const val PICK_RECEIPT = 4711
    }
}
