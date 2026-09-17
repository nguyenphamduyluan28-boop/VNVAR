package vn.vnvar.cameraStation

import android.Manifest
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.Settings
import android.view.OrientationEventListener
import android.view.Surface
import android.view.WindowManager
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
    /// Hướng màn hình được Flutter yêu cầu khóa. Giá trị hợp lệ:
    /// "landscape", "portrait", "auto".
    /// Dùng trong onPause() để khóa orientation ở tầng native TRƯỚC KHI
    /// Android Keyguard ép portrait.
    private var lockedOrientation: String = "portrait"
    @Volatile
    private var lastKnownLandscapeRotation: Int = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
    private var manualQuarterTurns = 0
    private var orientationListener: OrientationEventListener? = null
    private val nativeAudioRecorder: NativeAudioSegmentRecorder
        get() = sharedAudioRecorder ?: synchronized(MainActivity::class.java) {
            sharedAudioRecorder ?: NativeAudioSegmentRecorder(applicationContext).also {
                sharedAudioRecorder = it
            }
        }
    private lateinit var platformChannel: MethodChannel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Luôn luôn giữ màn hình sáng liên tục (Keep Screen On) không bao giờ tự tắt
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Đảm bảo Activity tiếp tục chạy ở chế độ Landscape khi màn hình tắt / khóa Keyguard
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        initOrientationListener()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Khi người dùng bấm Home hoặc vuốt thoát app:
        // Khóa hướng landscape và chuyển sang chế độ Picture-in-Picture (PiP) 16:9
        lockOrientationForBackground()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val params = android.app.PictureInPictureParams.Builder()
                    .setAspectRatio(android.util.Rational(16, 9))
                    .build()
                enterPictureInPictureMode(params)
            } catch (_: Exception) {
                // PiP không được hỗ trợ hoặc bị tắt bởi người dùng
            }
        }
    }

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
                    val targetEv = call.argument<Double>("targetEv") ?: 0.0
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

                "getAvailableCameras" -> {
                    val cameras = CameraExposureController.getAvailableCameras(this)
                    result.success(cameras)
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

                "switchCameraToId" -> {
                    val trackId = call.argument<String>("trackId")
                    val cameraId = call.argument<String>("cameraId")
                    if (trackId.isNullOrBlank() || cameraId.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "trackId and cameraId are required", null)
                    } else {
                        CameraExposureController.switchCameraToId(trackId, cameraId) { success, error ->
                            runOnUiThread {
                                if (success) {
                                    result.success(true)
                                } else {
                                    result.error("SWITCH_CAMERA_FAILED", error ?: "Failed to switch camera", null)
                                }
                            }
                        }
                    }
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

                "ensurePublicVideoStorage" -> ensurePublicVideoStorage(result)

                "scanMediaFile" -> {
                    val path = call.argument<String>("path")
                    if (!path.isNullOrBlank()) {
                        MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                    }
                    result.success(true)
                }

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

                "setScreenOrientation" -> {
                    val mode = call.argument<String>("mode") ?: "landscape"
                    lockedOrientation = mode
                    runOnUiThread {
                        if (activityResumed) {
                            unlockOrientationForForeground()
                        } else {
                            lockOrientationForBackground()
                        }
                    }
                    result.success(null)
                }

                "lockOrientationForBackground" -> {
                    lockOrientationForBackground()
                    result.success(null)
                }

                "setCameraRotation" -> {
                    val quarterTurns = call.argument<Int>("quarterTurns") ?: 0
                    manualQuarterTurns = (quarterTurns % 4 + 4) % 4
                    val applied = updateEffectiveRotation()
                    result.success(applied)
                }

                "getEffectiveRotation" -> {
                    result.success(computeEffectiveRotation())
                }

                "getDisplayRotationDegrees" -> {
                    result.success(getDisplayRotationDegrees())
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
        val rot = getDisplayRotation()
        if (rot == Surface.ROTATION_270) {
            lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
        } else if (rot == Surface.ROTATION_90) {
            lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        unlockOrientationForForeground()
        updateEffectiveRotation()
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

    private fun ensurePublicVideoStorage(result: MethodChannel.Result) {
        try {
            val publicMovies = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            val publicVnvar = java.io.File(publicMovies, "VNVAR")

            // Test if public Movies/VNVAR is actually accessible (can create, write, and list)
            val isPublicFullyAccessible = try {
                if (!publicVnvar.exists()) {
                    publicVnvar.mkdirs()
                }
                // Check if directory can be listed without permission denial
                val canList = publicVnvar.listFiles() != null
                val testFile = java.io.File(publicVnvar, "probe_${System.currentTimeMillis()}.mp4")
                val canWrite = testFile.createNewFile() && testFile.delete()
                android.util.Log.i("MainActivity", "[STORAGE] Public Movies/VNVAR probe: canList=$canList canWrite=$canWrite")
                canList && canWrite
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "[STORAGE] Public Movies/VNVAR probe failed: ${e.message}", e)
                false
            }

            if (isPublicFullyAccessible) {
                result.success(publicVnvar.absolutePath)
                return
            }

            // Fallback to app-specific external files dir (Movies/VNVAR).
            // On Android, getExternalFilesDir() is located on external storage
            // (/storage/emulated/0/Android/data/<package>/files/Movies/VNVAR).
            // It has full storage capacity and requires ZERO permissions, guaranteed
            // accessible via POSIX File/Directory APIs on all Android versions.
            val appMovies = getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: filesDir
            val appVnvar = java.io.File(appMovies, "VNVAR")
            if (!appVnvar.exists()) {
                appVnvar.mkdirs()
            }
            result.success(appVnvar.absolutePath)
        } catch (error: Exception) {
            result.error("PUBLIC_STORAGE_CREATE_FAILED", error.message, null)
        }
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

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) {
            // Vuốt thanh thông báo / màn hình chờ xuống (thanh trạng thái chiếm focus)
            lockOrientationForBackground()
        } else if (activityResumed) {
            unlockOrientationForForeground()
        }
    }

    override fun onPause() {
        activityResumed = false
        lockOrientationForBackground()
        super.onPause()
        CameraExposureController.reapplyAfterLifecycleChange("background")
    }

    override fun onStop() {
        activityResumed = false
        lockOrientationForBackground()
        super.onStop()
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

    private fun getDisplayRotation(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display?.rotation ?: Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.rotation
        }
    }

    /**
     * Khóa cứng (Hard lock) hướng màn hình ở tầng native để:
     * 1. Khi vuốt thanh thông báo / trung tâm điều khiển (onWindowFocusChanged false).
     * 2. Khi màn hình tắt / khóa máy (onPause, onStop).
     * Android Keyguard hay SystemUI không thể ép về Portrait.
     * Cảm biến gia tốc khi tắt màn hình không bị rơi về Portrait.
     */
    private fun lockOrientationForBackground() {
        val currentRotation = getDisplayRotation()
        val targetOrientation = when (lockedOrientation) {
            "portrait" -> {
                if (currentRotation == Surface.ROTATION_180) {
                    ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                } else {
                    ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
            }
            "landscape" -> {
                // Khóa cứng vào hướng landscape thực tế:
                // Nếu getDisplayRotation() vẫn trả về 90 hoặc 270 thì cập nhật,
                // ngược lại (khi màn hình tắt, vuốt về home hoặc notification shade mở)
                // sử dụng lastKnownLandscapeRotation đã lưu lúc active!
                if (currentRotation == Surface.ROTATION_270) {
                    lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                    ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                } else if (currentRotation == Surface.ROTATION_90) {
                    lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                } else {
                    lastKnownLandscapeRotation
                }
            }
            else -> {
                // Chế độ auto: nếu đang quay ngang thì khóa cứng ngang, nếu đang dọc thì khóa cứng dọc
                when (currentRotation) {
                    Surface.ROTATION_270 -> {
                        lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                        ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                    }
                    Surface.ROTATION_90 -> {
                        lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                    }
                    Surface.ROTATION_180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                    Surface.ROTATION_0 -> {
                        if (lockedOrientation == "landscape") lastKnownLandscapeRotation
                        else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    }
                    else -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
                }
            }
        }
        runOnUiThread {
            super.setRequestedOrientation(targetOrientation)
        }
    }

    /**
     * Mở khóa để cho phép xoay linh hoạt (sensor) khi app quay lại Foreground.
     */
    private fun unlockOrientationForForeground() {
        val targetOrientation = activityInfoOrientationFor(lockedOrientation)
        runOnUiThread {
            super.setRequestedOrientation(targetOrientation)
        }
    }

    override fun setRequestedOrientation(requestedOrientation: Int) {
        val effectiveOrientation = if (!activityResumed) {
            // Khi app ở background, màn hình tắt, hoặc mất focus (vuốt thanh thông báo):
            // Tuyệt đối không cho phép SENSOR_LANDSCAPE hay SENSOR_PORTRAIT vì cảm biến
            // tắt sẽ làm Android rơi về Portrait mặc định. Ép sang HARD lock tương ứng!
            when (requestedOrientation) {
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE,
                ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE,
                ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED -> {
                    val rot = getDisplayRotation()
                    if (rot == Surface.ROTATION_270) {
                        lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                        ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                    } else if (rot == Surface.ROTATION_90) {
                        lastKnownLandscapeRotation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                    } else {
                        lastKnownLandscapeRotation
                    }
                }
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT,
                ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT -> {
                    val rot = getDisplayRotation()
                    if (rot == Surface.ROTATION_180) {
                        ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                    } else {
                        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    }
                }
                else -> requestedOrientation
            }
        } else {
            requestedOrientation
        }
        super.setRequestedOrientation(effectiveOrientation)
    }

    private fun activityInfoOrientationFor(mode: String): Int = when (mode) {
        "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        "portrait" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    private fun getDisplayRotationDegrees(): Int {
        return when (getDisplayRotation()) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

    private fun computeEffectiveRotation(): Int {
        val displayRot = getDisplayRotation()
        // Khi máy quay ngang Landscape Right (ROTATION_270 - đỉnh máy bên phải, USB bên trái),
        // mắt camera sau bị úp ngược 180° so với Landscape Left chuẩn (ROTATION_90).
        // Cần bù 180° tự động để video gửi sang tablet luôn xuôi chiều.
        val autoCompensation = if (displayRot == Surface.ROTATION_270) 180 else 0
        val manualRotation = manualQuarterTurns * 90
        return ((autoCompensation + manualRotation) % 360 + 360) % 360
    }

    private fun updateEffectiveRotation(): Boolean {
        val degrees = computeEffectiveRotation()
        val success = CameraExposureController.setCaptureRotation(degrees)
        android.util.Log.i("MainActivity", "Updated effective camera rotation: $degrees° (manual=$manualQuarterTurns, display=${getDisplayRotation()})")
        return success
    }

    private fun initOrientationListener() {
        orientationListener = object : OrientationEventListener(this) {
            private var lastDisplayRotation = -1

            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                val currentDisplay = getDisplayRotation()
                if (currentDisplay != lastDisplayRotation) {
                    lastDisplayRotation = currentDisplay
                    runOnUiThread {
                        updateEffectiveRotation()
                        if (::platformChannel.isInitialized) {
                            platformChannel.invokeMethod(
                                "onDisplayRotationChanged",
                                mapOf(
                                    "displayRotation" to currentDisplay,
                                    "degrees" to getDisplayRotationDegrees(),
                                    "effectiveRotation" to computeEffectiveRotation(),
                                ),
                            )
                        }
                    }
                }
            }
        }
        if (orientationListener?.canDetectOrientation() == true) {
            orientationListener?.enable()
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        runOnUiThread {
            updateEffectiveRotation()
        }
    }

    override fun onDestroy() {
        orientationListener?.disable()
        orientationListener = null
        super.onDestroy()
    }
}
