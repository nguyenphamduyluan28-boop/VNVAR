package com.example.camera_station

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingStart: PendingStart? = null
    private var activityResumed = false
    private var rtspPublisher: VnvarRtspPublisher? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var waitingStoragePermission = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val cameraId = call.argument<String>("cameraId") ?: "Camera"
                    val courtId = call.argument<String>("courtId") ?: "Chưa chọn sân"
                    startWhenCameraPermissionGranted(cameraId, courtId, result)
                }

                "stop" -> {
                    stopService(Intent(this, CameraStationForegroundService::class.java))
                    result.success(null)
                }

                "isEmulator" -> result.success(isRunningOnEmulator())

                "startRtsp" -> {
                    val trackId = call.argument<String>("trackId")
                    val port = call.argument<Int>("port") ?: 8554
                    val track = trackId?.let {
                        FlutterWebRTCPlugin.sharedSingleton?.getTrackForId(it, null)
                    }
                    if (track !is org.webrtc.VideoTrack) {
                        result.error("RTSP_TRACK_NOT_FOUND", "Không tìm thấy video track WebRTC.", null)
                    } else {
                        try {
                            rtspPublisher?.stop()
                            rtspPublisher = VnvarRtspPublisher(track, port).also { it.start() }
                            result.success(mapOf("running" to true, "port" to port, "path" to "/camera"))
                        } catch (error: Exception) {
                            rtspPublisher = null
                            result.error("RTSP_START_FAILED", error.message, null)
                        }
                    }
                }

                "stopRtsp" -> {
                    rtspPublisher?.stop()
                    rtspPublisher = null
                    result.success(null)
                }

                "selectVideoFolder" -> selectVideoFolder(result)

                else -> result.notImplemented()
            }
        }
    }

    private fun startWhenCameraPermissionGranted(
        cameraId: String,
        courtId: String,
        result: MethodChannel.Result,
    ) {
        if (pendingStart != null) {
            result.error("START_IN_PROGRESS", "Camera permission request is in progress.", null)
            return
        }

        pendingStart = PendingStart(cameraId, courtId, result)

        if (!hasCameraPermission()) {
            requestPermissions(requiredRuntimePermissions(), PERMISSION_REQUEST)
            return
        }

        if (requestNotificationPermissionIfNeeded()) return
        completePendingStartIfPossible()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == STORAGE_PERMISSION_REQUEST) {
            if (grantResults.isNotEmpty() && grantResults.first() == PackageManager.PERMISSION_GRANTED) {
                launchFolderPicker()
            } else {
                pendingFolderResult?.error(
                    "STORAGE_PERMISSION_DENIED",
                    "Cần quyền bộ nhớ để lưu video vào thư mục đã chọn.",
                    null,
                )
                pendingFolderResult = null
            }
            return
        }

        if (requestCode != PERMISSION_REQUEST &&
            requestCode != NOTIFICATION_PERMISSION_REQUEST
        ) return

        val pending = pendingStart ?: return

        if (!hasCameraPermission()) {
            pendingStart = null
            pending.result.error(
                "CAMERA_PERMISSION_DENIED",
                "Camera permission is required to run Camera Station.",
                null,
            )
            return
        }

        completePendingStartIfPossible()
    }

    override fun onPostResume() {
        super.onPostResume()
        activityResumed = true
        completePendingStartIfPossible()
        if (waitingStoragePermission &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager())
        ) {
            waitingStoragePermission = false
            launchFolderPicker()
        } else if (waitingStoragePermission && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            waitingStoragePermission = false
            pendingFolderResult?.error(
                "STORAGE_PERMISSION_DENIED",
                "Cần cho phép quản lý tệp để lưu MPEG-TS vào thư mục đã chọn.",
                null,
            )
            pendingFolderResult = null
        }
    }

    private fun selectVideoFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("FOLDER_PICK_IN_PROGRESS", "Đang chọn thư mục lưu video.", null)
            return
        }
        pendingFolderResult = result
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                STORAGE_PERMISSION_REQUEST,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            waitingStoragePermission = true
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            return
        }
        launchFolderPicker()
    }

    private fun launchFolderPicker() {
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                // This Station only supports a real path in primary storage.
                // Hiding cloud/document providers also avoids a DocumentsUI
                // crash present on some Samsung Android 9 builds when their
                // stale provider root is pushed onto the navigation stack.
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(
                        DocumentsContract.EXTRA_INITIAL_URI,
                        DocumentsContract.buildDocumentUri(
                            "com.android.externalstorage.documents",
                            "primary:",
                        ),
                    )
                }
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            },
            VIDEO_FOLDER_REQUEST,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != VIDEO_FOLDER_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingFolderResult
        pendingFolderResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result?.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION),
            )
            val documentId = DocumentsContract.getTreeDocumentId(uri)
            val parts = documentId.split(":", limit = 2)
            if (parts.firstOrNull().equals("primary", ignoreCase = true)) {
                val relative = parts.getOrNull(1).orEmpty()
                val root = Environment.getExternalStorageDirectory().absolutePath
                result?.success(if (relative.isEmpty()) root else "$root/$relative")
            } else {
                result?.error(
                    "UNSUPPORTED_STORAGE",
                    "Hiện chỉ hỗ trợ thư mục trong bộ nhớ chính của điện thoại.",
                    uri.toString(),
                )
            }
        } catch (error: Exception) {
            result?.error("FOLDER_PICK_FAILED", error.message, uri.toString())
        }
    }

    override fun onPause() {
        activityResumed = false
        super.onPause()
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun isRunningOnEmulator(): Boolean {
        return Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator", ignoreCase = true) ||
            Build.MODEL.contains("Emulator", ignoreCase = true) ||
            Build.MODEL.contains("Android SDK built for", ignoreCase = true) ||
            Build.MANUFACTURER.contains("Genymotion", ignoreCase = true) ||
            Build.PRODUCT.contains("sdk", ignoreCase = true) ||
            Build.HARDWARE.contains("ranchu", ignoreCase = true) ||
            Build.HARDWARE.contains("goldfish", ignoreCase = true)
    }

    private fun requiredRuntimePermissions(): Array<String> {
        val permissions = mutableListOf(Manifest.permission.CAMERA)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return permissions.toTypedArray()
    }

    private fun completePendingStartIfPossible() {
        if (!activityResumed || !hasCameraPermission()) return

        val pending = pendingStart ?: return
        pendingStart = null
        startCameraStationService(pending.cameraId, pending.courtId)
        pending.result.success(null)
    }

    private fun requestNotificationPermissionIfNeeded(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return true
        }
        return false
    }

    private fun startCameraStationService(cameraId: String, courtId: String) {
        val intent = Intent(this, CameraStationForegroundService::class.java).apply {
            action = CameraStationForegroundService.ACTION_START
            putExtra(CameraStationForegroundService.EXTRA_CAMERA_ID, cameraId)
            putExtra(CameraStationForegroundService.EXTRA_COURT_ID, courtId)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    private data class PendingStart(
        val cameraId: String,
        val courtId: String,
        val result: MethodChannel.Result,
    )

    companion object {
        private const val CHANNEL_NAME = "vnvar/camera_station_service"
        private const val PERMISSION_REQUEST = 4101
        private const val NOTIFICATION_PERMISSION_REQUEST = 4102
        private const val VIDEO_FOLDER_REQUEST = 45186
        private const val STORAGE_PERMISSION_REQUEST = 45187
    }
}
