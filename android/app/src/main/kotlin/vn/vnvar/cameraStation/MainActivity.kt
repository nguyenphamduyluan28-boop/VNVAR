package vn.vnvar.cameraStation

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.PowerManager
import android.provider.DocumentsContract
import androidx.core.content.ContextCompat
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.atan

class MainActivity : FlutterActivity() {
    private var pendingStart: PendingStart? = null
    private var activityResumed = false
    private var rtspPublisher: VnvarRtspPublisher? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private val nativeAudioRecorder: NativeAudioSegmentRecorder
        get() = sharedAudioRecorder ?: synchronized(MainActivity::class.java) {
            sharedAudioRecorder ?: NativeAudioSegmentRecorder(applicationContext).also {
                sharedAudioRecorder = it
            }
        }
    private lateinit var platformChannel: MethodChannel

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_CACHE_KEY)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_CACHE_KEY, flutterEngine)

        platformChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        platformChannel.setMethodCallHandler { call, result ->
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

                "startNativeAudioSegment" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("AUDIO_PATH_REQUIRED", "Audio path is required", null)
                    } else if (
                        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
                            PackageManager.PERMISSION_GRANTED
                    ) {
                        result.error(
                            "MICROPHONE_PERMISSION_DENIED",
                            "Microphone permission is not granted",
                            null,
                        )
                    } else {
                        try {
                            refreshCameraStationForegroundTypes()
                            result.success(nativeAudioRecorder.start(path))
                        } catch (error: Exception) {
                            result.error("AUDIO_START_FAILED", error.message, null)
                        }
                    }
                }

                "stopNativeAudioSegment" -> {
                    try {
                        result.success(nativeAudioRecorder.stop())
                    } catch (error: Exception) {
                        result.error("AUDIO_STOP_FAILED", error.message, null)
                    }
                }

                "getNativeAudioSegmentStatus" -> {
                    result.success(nativeAudioRecorder.status())
                }

                "isEmulator" -> result.success(isRunningOnEmulator())

                "setScreenDimmed" -> {
                    val dimmed = call.argument<Boolean>("dimmed") ?: false
                    runOnUiThread {
                        val attributes = window.attributes
                        attributes.screenBrightness = if (dimmed) 0.05f else -1f
                        window.attributes = attributes
                        result.success(null)
                    }
                }

                "getCameraResolutionProfiles" -> {
                    try {
                        val facing = call.argument<String>("facing") ?: "environment"
                        result.success(getCameraResolutionProfiles(facing))
                    } catch (error: Exception) {
                        result.error("CAMERA_CAPABILITY_FAILED", error.message, null)
                    }
                }

                "setCameraExposureBoost" -> {
                    val trackId = call.argument<String>("trackId")
                    val targetEv = call.argument<Double>("targetEv") ?: 1.3
                    if (trackId.isNullOrBlank()) {
                        result.error("INVALID_TRACK", "Thiếu video track để chỉnh exposure.", null)
                    } else {
                        CameraExposureController.apply(trackId, targetEv) { response ->
                            runOnUiThread { result.success(response) }
                        }
                    }
                }

                "clearCameraExposureBoost" -> {
                    CameraExposureController.clear(call.argument<String>("trackId"))
                    result.success(null)
                }

                "getCameraZoom" -> {
                    val trackId = call.argument<String>("trackId")
                    if (trackId.isNullOrBlank()) result.error("INVALID_TRACK", "Video track is required", null)
                    else CameraExposureController.zoomCapabilities(trackId) { response -> runOnUiThread { result.success(response) } }
                }

                "setCameraZoom" -> {
                    val trackId = call.argument<String>("trackId")
                    val zoom = call.argument<Double>("zoom")
                    if (trackId.isNullOrBlank() || zoom == null) result.error("INVALID_ZOOM", "Track and zoom are required", null)
                    else CameraExposureController.setZoom(trackId, zoom) { response -> runOnUiThread { result.success(response) } }
                }

                "startRtsp" -> {
                    val trackId = call.argument<String>("trackId")
                    val port = call.argument<Int>("port") ?: 8554
                    val bitrate = call.argument<Int>("bitrate") ?: 2_000_000
                    val fps = call.argument<Int>("fps") ?: 30
                    val track = trackId?.let {
                        FlutterWebRTCPlugin.sharedSingleton?.getTrackForId(it, null)
                    }
                    if (track !is org.webrtc.VideoTrack) {
                        result.error("RTSP_TRACK_NOT_FOUND", "Không tìm thấy video track WebRTC.", null)
                    } else {
                        try {
                            rtspPublisher?.stop()
                            rtspPublisher = VnvarRtspPublisher(
                                track = track,
                                audioAvailable = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
                                port = port,
                                bitrate = bitrate,
                                fps = fps,
                                onEncoderConfigured = {
                                    runOnUiThread {
                                        platformChannel.invokeMethod(
                                            "onRtspEncoderConfigured",
                                            null,
                                        )
                                    }
                                },
                                onEncoderError = { message ->
                                    runOnUiThread {
                                        platformChannel.invokeMethod(
                                            "onRtspEncoderError",
                                            mapOf("error" to message),
                                        )
                                    }
                                },
                            ).also { it.start() }
                            nativeAudioRecorder.onPcm = { pcm -> rtspPublisher?.sendAudioPcm(pcm) }
                            result.success(mapOf(
                                "running" to true,
                                "started" to true,
                                "port" to port,
                                "path" to "/camera",
                                "audio" to (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
                            ))
                        } catch (error: Exception) {
                            rtspPublisher = null
                            result.error("RTSP_START_FAILED", error.message, null)
                        }
                    }
                }

                "stopRtsp" -> {
                    nativeAudioRecorder.onPcm = null
                    rtspPublisher?.stop()
                    rtspPublisher = null
                    result.success(null)
                }

                "selectVideoFolder" -> selectVideoFolder(result)

                "supportsVideoFolderSelection" ->
                    result.success(Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q)

                "getAvailableStorageBytes" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_STORAGE_PATH", "Thiếu đường dẫn bộ nhớ.", null)
                    } else {
                        try {
                            result.success(StatFs(path).availableBytes)
                        } catch (error: Exception) {
                            result.error("STORAGE_STAT_FAILED", error.message, path)
                        }
                    }
                }

                "getThermalStatus" -> {
                    val battery = registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val tenths = battery?.getIntExtra("temperature", Int.MIN_VALUE) ?: Int.MIN_VALUE
                    val power = getSystemService(PowerManager::class.java)
                    result.success(mapOf(
                        "temperatureC" to if (tenths == Int.MIN_VALUE) null else tenths / 10.0,
                        "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power?.currentThermalStatus else 0,
                    ))
                }

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
        refreshCameraStationForegroundTypes()
        CameraExposureController.reapplyAfterLifecycleChange("foreground")
        completePendingStartIfPossible()
    }

    private fun selectVideoFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("FOLDER_PICK_IN_PROGRESS", "Đang chọn thư mục lưu video.", null)
            return
        }
        pendingFolderResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            pendingFolderResult = null
            result.error(
                "CUSTOM_STORAGE_UNSUPPORTED",
                "Android 11+ sử dụng thư mục ứng dụng để không cần quyền quản lý toàn bộ tệp.",
                null,
            )
            return
        }
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
        CameraExposureController.reapplyAfterLifecycleChange("background")
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun getCameraResolutionProfiles(facing: String): List<Map<String, Any>> {
        val manager = getSystemService(CameraManager::class.java)
        val requestedLensFacing = if (facing == "user") {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }
        val cameraId = selectMainCamera(manager, requestedLensFacing) ?: return emptyList()
        val characteristics = manager.getCameraCharacteristics(cameraId)
        val configuration = characteristics.get(
            CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP,
        ) ?: return emptyList()
        val sizes = configuration.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty()
        val targets = listOf(
            Triple("hd720", 1280, 720),
            Triple("fullHd1080", 1920, 1080),
            Triple("qhd2k", 2560, 1440),
            Triple("ultraHd4k", 3840, 2160),
        )
        return targets.mapNotNull { (id, width, height) ->
            val size = sizes.firstOrNull { it.width == width && it.height == height }
                ?: return@mapNotNull null
            // WebRTC getUserMedia opens a STANDARD capture session. High-speed
            // ranges describe constrained high-speed sessions and must not be
            // used here: a device may advertise 1080p60 for high-speed capture
            // while only supporting 1080p30 in a standard session.
            val minFrameDurationNs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                configuration.getOutputMinFrameDuration(SurfaceTexture::class.java, size)
            } else {
                0L
            }
            val standardMaxFps = if (minFrameDurationNs > 0L) {
                (1_000_000_000L / minFrameDurationNs).toInt().coerceAtLeast(1)
            } else {
                // A zero duration means the camera does not publish a reliable
                // per-output limit. Prefer a safe standard-capture fallback.
                30
            }
            // Keep normal capture at 30 fps. Compared with 60 fps this gives
            // auto-exposure up to twice as much time per frame, which is much
            // closer to the stock camera preview in indoor/low-light courts.
            // WebRTC does not receive the vendor HDR/night-processing pipeline,
            // so preferring 60 fps here makes its image unnecessarily dark.
            val preferredFps = 30
            mapOf(
                "id" to id,
                "width" to width,
                "height" to height,
                "maxFps" to minOf(preferredFps, standardMaxFps),
                "deviceId" to cameraId,
            )
        }
    }

    /**
     * Selects the normal wide camera (roughly 1x) instead of relying on camera
     * ID ordering, which may put an ultra-wide or auxiliary sensor first.
     */
    private fun selectMainCamera(manager: CameraManager, lensFacing: Int): String? {
        val candidates = manager.cameraIdList.filter { id ->
            manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == lensFacing
        }
        if (candidates.isEmpty()) return null

        return candidates.minByOrNull { id ->
            val characteristics = manager.getCameraCharacteristics(id)
            val sensorSize = characteristics.get(
                CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE,
            )
            val focalLength = characteristics.get(
                CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS,
            )?.firstOrNull()
            if (sensorSize == null || focalLength == null || focalLength <= 0f) {
                Double.MAX_VALUE
            } else {
                val horizontalFovDegrees =
                    2.0 * atan(sensorSize.width / (2.0 * focalLength)) * 180.0 / Math.PI
                // A phone's primary 1x camera is normally around 65-80 degrees.
                abs(horizontalFovDegrees - 73.0)
            }
        }
    }

    private fun hasCapturePermissions(): Boolean {
        return hasCameraPermission()
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
        val permissions = mutableListOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return permissions.toTypedArray()
    }

    private fun completePendingStartIfPossible() {
        if (!activityResumed || !hasCapturePermissions()) return

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

    private fun refreshCameraStationForegroundTypes() {
        if (!CameraStationForegroundService.isRunning) return
        ContextCompat.startForegroundService(
            this,
            Intent(this, CameraStationForegroundService::class.java).apply {
                action = CameraStationForegroundService.ACTION_REFRESH_TYPES
            },
        )
    }

    private data class PendingStart(
        val cameraId: String,
        val courtId: String,
        val result: MethodChannel.Result,
    )

    companion object {
        private const val ENGINE_CACHE_KEY = "vnvar_camera_station_engine"
        @Volatile
        private var sharedAudioRecorder: NativeAudioSegmentRecorder? = null
        private const val CHANNEL_NAME = "vnvar/camera_station_service"
        private const val PERMISSION_REQUEST = 4101
        private const val NOTIFICATION_PERMISSION_REQUEST = 4102
        private const val VIDEO_FOLDER_REQUEST = 45186
        private const val STORAGE_PERMISSION_REQUEST = 45187
    }
}
