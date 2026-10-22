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
import android.os.Handler
import android.os.Looper
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.atan

class MainActivity : FlutterActivity() {
    private var pendingStart: PendingStart? = null
    /**
     * Các lệnh `ensureCapturePermissions` đang chờ người dùng trả lời hộp thoại
     * quyền (C7): lệnh đến khi hộp thoại đang mở chỉ được xếp vào đây, không
     * requestPermissions lần hai; khi có kết quả trả cho tất cả.
     */
    private val pendingCapturePermissionResults = mutableListOf<MethodChannel.Result>()
    private var activityResumed = false
    /**
     * Chính app vừa tự mở một màn hình khác (cài đặt ứng dụng, chọn thư mục):
     * onUserLeaveHint không được đưa app vào PiP. Xoá ở onResume.
     */
    private var suppressPipForOwnActivity = false
    // Đọc từ luồng thu âm (onPcm) nên cần volatile.
    @Volatile
    private var rtspPublisher: VnvarRtspPublisher? = null
    /** MethodChannel.Result phải được trả trên main thread. */
    private val mainHandler = Handler(Looper.getMainLooper())
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
    // Dùng chung cấp tiến trình (giống sharedAudioRecorder): Activity mới dùng
    // lại đường 4G/5G của Activity cũ thay vì để nó rò NetworkCallback/socket.
    private val cellularUplink: CellularUplink
        get() = sharedCellularUplink ?: synchronized(MainActivity::class.java) {
            sharedCellularUplink ?: CellularUplink(applicationContext).also {
                sharedCellularUplink = it
            }
        }
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
        // App tự mở màn hình khác (cài đặt, chọn thư mục): không vào PiP.
        if (suppressPipForOwnActivity) return
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

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        runOnUiThread {
            try {
                if (::platformChannel.isInitialized) {
                    platformChannel.invokeMethod(
                        "onPictureInPictureModeChanged",
                        mapOf("inPip" to isInPictureInPictureMode)
                    )
                }
            } catch (_: Exception) {}
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_CACHE_KEY)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_CACHE_KEY, flutterEngine)
        // Activity này giờ sở hữu handler của channel (engine dùng chung).
        activeActivity = java.lang.ref.WeakReference(this)

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

                "isInPictureInPictureMode" -> {
                    val inPip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        isInPictureInPictureMode
                    } else {
                        false
                    }
                    result.success(inPip)
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
                        // Lỗi làm mới foreground type không được làm hỏng việc
                        // thu âm (hàm tự bắt lỗi và chỉ chạy khi cần).
                        refreshCameraStationForegroundTypes()
                        // Xả hàng ghi, fsync và khởi tạo AudioRecord có thể mất
                        // vài giây: chạy trên luồng âm thanh nền (giữ thứ tự).
                        runInBackground(audioExecutor, "startNativeAudioSegment") {
                            try {
                                val response = nativeAudioRecorder.start(path)
                                mainHandler.post { result.success(response) }
                            } catch (error: Throwable) {
                                mainHandler.post {
                                    result.error("AUDIO_START_FAILED", error.message, null)
                                }
                            }
                        }
                    }
                }

                "stopNativeAudioSegment" -> {
                    runInBackground(audioExecutor, "stopNativeAudioSegment") {
                        try {
                            val response = nativeAudioRecorder.stop()
                            mainHandler.post { result.success(response) }
                        } catch (error: Throwable) {
                            mainHandler.post {
                                result.error("AUDIO_STOP_FAILED", error.message, null)
                            }
                        }
                    }
                }

                "getNativeAudioSegmentStatus" -> {
                    result.success(nativeAudioRecorder.status())
                }

                "isEmulator" -> result.success(isRunningOnEmulator())

                // Xin quyền camera/micro (và thông báo) TRƯỚC khi mở camera, chờ
                // người dùng trả lời không giới hạn thời gian. Trước đây hộp thoại
                // quyền bật ra giữa lúc getUserMedia (timeout 12 s) nên lần cài
                // đầu tiên hay báo lỗi và phải bấm "Thử lại".
                "ensureCapturePermissions" -> ensureCapturePermissions(result)

                "openAppSettings" -> {
                    suppressPipForOwnActivity = true
                    val opened = try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        true
                    } catch (error: Exception) {
                        suppressPipForOwnActivity = false
                        android.util.Log.w("MainActivity", "Unable to open app settings: ${error.message}")
                        false
                    }
                    result.success(opened)
                }

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

                "setCameraLock" -> {
                    val trackId = call.argument<String>("trackId")
                    val locked = call.argument<Boolean>("locked") ?: true
                    if (trackId.isNullOrBlank()) {
                        result.error("INVALID_TRACK", "trackId is required", null)
                    } else {
                        CameraExposureController.setLock(trackId, locked) { response ->
                            runOnUiThread { result.success(response["applied"] == true) }
                        }
                    }
                }

                "setCameraMeteringPoint" -> {
                    val trackId = call.argument<String>("trackId")
                    val x = call.argument<Double>("x")
                    val y = call.argument<Double>("y")
                    if (trackId.isNullOrBlank() || x == null || y == null) {
                        result.error("INVALID_ARGS", "trackId, x and y are required", null)
                    } else {
                        CameraExposureController.setMeteringPoint(trackId, x, y) { response ->
                            runOnUiThread { result.success(response["applied"] == true) }
                        }
                    }
                }

                "setStableExposure" -> {
                    val trackId = call.argument<String>("trackId")
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    if (trackId.isNullOrBlank()) {
                        result.error("INVALID_TRACK", "trackId is required", null)
                    } else {
                        CameraExposureController.setStableExposure(trackId, enabled) { response ->
                            runOnUiThread { result.success(response["applied"] == true) }
                        }
                    }
                }

                "setCaptureFpsCap" -> {
                    val trackId = call.argument<String>("trackId")
                    val fps = call.argument<Int>("fps")
                    if (trackId.isNullOrBlank()) {
                        result.error("INVALID_TRACK", "trackId is required", null)
                    } else {
                        result.success(CameraExposureController.setCaptureFpsCap(trackId, fps))
                    }
                }

                "startRtsp" -> {
                    val trackId = call.argument<String>("trackId")
                    val port = call.argument<Int>("port") ?: 8554
                    val bitrate = call.argument<Int>("bitrate") ?: 2_000_000
                    val fps = call.argument<Int>("fps") ?: 30
                    val remoteAudio = call.argument<Boolean>("remoteAudio") ?: false
                    val track = trackId?.let {
                        FlutterWebRTCPlugin.sharedSingleton?.getTrackForId(it, null)
                    }
                    if (track !is org.webrtc.VideoTrack) {
                        result.error("RTSP_TRACK_NOT_FOUND", "Không tìm thấy video track WebRTC.", null)
                    } else {
                        try {
                            val previous = rtspPublisher
                            rtspPublisher = null
                            previous?.stop()
                            // Callback mang id phiên publisher: callback trễ của
                            // phiên cũ (đã stop/thay thế) bị bỏ qua.
                            rtspPublisher = VnvarRtspPublisher(
                                track = track,
                                audioAvailable = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
                                port = port,
                                bitrate = bitrate,
                                fps = fps,
                                remoteAudioEnabled = remoteAudio,
                                onEncoderConfigured = { publisherId ->
                                    mainHandler.post {
                                        if (rtspPublisher?.publisherId == publisherId &&
                                            ::platformChannel.isInitialized
                                        ) {
                                            platformChannel.invokeMethod(
                                                "onRtspEncoderConfigured",
                                                null,
                                            )
                                        }
                                    }
                                },
                                onEncoderError = { publisherId, message ->
                                    mainHandler.post {
                                        if (rtspPublisher?.publisherId == publisherId &&
                                            ::platformChannel.isInitialized
                                        ) {
                                            platformChannel.invokeMethod(
                                                "onRtspEncoderError",
                                                mapOf("error" to message),
                                            )
                                        }
                                    }
                                },
                            ).also { it.start() }
                            val audioPermissionGranted = ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.RECORD_AUDIO,
                            ) == PackageManager.PERMISSION_GRANTED
                            if (audioPermissionGranted) {
                                nativeAudioRecorder.onPcm = { pcm -> rtspPublisher?.sendAudioPcm(pcm) }
                                // Khởi tạo AudioRecord có thể chậm: không chặn UI thread.
                                runInBackground(audioExecutor, "startStreaming") {
                                    nativeAudioRecorder.startStreaming()
                                }
                            }
                            result.success(mapOf(
                                "running" to true,
                                "started" to true,
                                "port" to port,
                                "path" to "/camera",
                                "audio" to audioPermissionGranted,
                            ))
                        } catch (error: Exception) {
                            rtspPublisher = null
                            result.error("RTSP_START_FAILED", error.message, null)
                        }
                    }
                }

                "openCellularTunnel" -> {
                    val host = call.argument<String>("host")
                    val port = call.argument<Int>("port")
                    val tls = call.argument<Boolean>("tls") ?: false
                    if (host.isNullOrBlank() || port == null || port !in 1..65535) {
                        result.error("INVALID_TUNNEL_TARGET", "Thiếu máy chủ hoặc cổng.", null)
                    } else {
                        // Chờ mạng di động có thể mất vài giây: không chặn UI thread.
                        Thread({
                            val localPort = try {
                                cellularUplink.open(host, port, tls)
                            } catch (error: Exception) {
                                android.util.Log.w("MainActivity", "Cellular tunnel failed: ${error.message}")
                                null
                            }
                            runOnUiThread { result.success(localPort) }
                        }, "VNVAR-Cellular-Open").start()
                    }
                }

                "closeCellularTunnel" -> {
                    val uplink = sharedCellularUplink
                    if (uplink != null) {
                        Thread({
                            try { uplink.close() } catch (_: Throwable) {}
                        }, "VNVAR-Cellular-Close").start()
                    }
                    result.success(null)
                }

                "setRtspBitrate" -> {
                    val bitrate = call.argument<Int>("bitrate")
                    if (bitrate != null && bitrate > 0) {
                        rtspPublisher?.setTargetBitrate(bitrate)
                    }
                    result.success(null)
                }

                "setRtspRemoteAudio" -> {
                    rtspPublisher?.remoteAudioEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(null)
                }

                "stopRtsp" -> {
                    nativeAudioRecorder.onPcm = null
                    runInBackground(audioExecutor, "stopStreaming") {
                        nativeAudioRecorder.stopStreaming()
                    }
                    val publisher = rtspPublisher
                    rtspPublisher = null
                    try { publisher?.stop() } catch (_: Exception) {}
                    result.success(null)
                }

                "selectVideoFolder" -> selectVideoFolder(result)

                "supportsVideoFolderSelection" ->
                    result.success(Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q)

                "ensurePublicVideoStorage" -> ensurePublicVideoStorage(result)

                "scanMediaFile" -> {
                    // Không scanMediaFile để tránh Android MediaStore đưa video vào Bộ sưu tập
                    result.success(true)
                }

                "deleteDirectoryRecursively" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "Thiếu đường dẫn thư mục cần xóa.", null)
                    } else {
                        // Xóa đệ quy + MediaStore có thể chạm hàng nghìn file:
                        // chạy trên luồng I/O nền, trả kết quả trên main thread.
                        runInBackground(ioExecutor, "deleteDirectoryRecursively") {
                            try {
                                val dir = java.io.File(path)
                                val success = if (dir.exists()) dir.deleteRecursively() else true
                                try {
                                    purgeMediaStoreForVnvar(path)
                                } catch (_: Exception) {}
                                mainHandler.post { result.success(success) }
                            } catch (error: Throwable) {
                                mainHandler.post { result.error("DELETE_FAILED", error.message, path) }
                            }
                        }
                    }
                }

                "ensureNoMedia" -> {
                    val path = call.argument<String>("path")
                    if (!path.isNullOrBlank()) {
                        try {
                            val dir = java.io.File(path)
                            if (dir.exists() && dir.isDirectory) {
                                val nomedia = java.io.File(dir, ".nomedia")
                                if (!nomedia.exists()) {
                                    nomedia.createNewFile()
                                }
                                // Chỉ quét file .nomedia. Không xóa bản ghi MediaStore ở
                                // đây: trên Android 10+ xóa bản ghi sẽ xóa luôn file video thật.
                                MediaScannerConnection.scanFile(this, arrayOf(nomedia.absolutePath), null, null)
                            }
                        } catch (_: Exception) {}
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
                    // Dự báo nhiệt 30 giây tới (Android 11+): 1.0 = chạm mức SEVERE.
                    // NaN khi máy không hỗ trợ / gọi quá dày.
                    val headroom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            power?.getThermalHeadroom(30)?.toDouble()?.takeIf { !it.isNaN() }
                        } catch (_: Throwable) { null }
                    } else null
                    val plugged = battery?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) ?: 0
                    result.success(mapOf(
                        "temperatureC" to if (tenths == Int.MIN_VALUE) null else tenths / 10.0,
                        "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power?.currentThermalStatus else 0,
                        "headroom" to headroom,
                        "charging" to (plugged != 0),
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

    private fun capturePermissionStatus(): Map<String, Boolean> = mapOf(
        "camera" to hasCameraPermission(),
        "microphone" to (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED),
    )

    private fun ensureCapturePermissions(result: MethodChannel.Result) {
        val missing = requiredRuntimePermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        // Chỉ hỏi khi còn thiếu camera hoặc micro; thông báo được hỏi kèm cho gọn.
        val needsCapture = missing.any {
            it == Manifest.permission.CAMERA || it == Manifest.permission.RECORD_AUDIO
        }
        if (!needsCapture) {
            result.success(capturePermissionStatus())
            return
        }
        // C7: hộp thoại đang mở → chỉ xếp hàng, KHÔNG requestPermissions lần hai
        // (lần gọi thứ hai sẽ huỷ/đè hộp thoại đang chờ). Kết quả trả cho tất cả.
        val dialogPending = pendingCapturePermissionResults.isNotEmpty()
        pendingCapturePermissionResults.add(result)
        if (dialogPending) return
        try {
            requestPermissions(missing.toTypedArray(), CAPTURE_PERMISSION_REQUEST)
        } catch (error: Exception) {
            android.util.Log.w("MainActivity", "requestPermissions failed: ${error.message}")
            completeCapturePermissionRequests()
        }
    }

    /** Trả trạng thái quyền hiện tại cho mọi lệnh `ensureCapturePermissions` đang chờ. */
    private fun completeCapturePermissionRequests() {
        if (pendingCapturePermissionResults.isEmpty()) return
        val waiting = pendingCapturePermissionResults.toList()
        pendingCapturePermissionResults.clear()
        val status = capturePermissionStatus()
        for (pending in waiting) {
            try {
                pending.success(status)
            } catch (error: Exception) {
                android.util.Log.w("MainActivity", "ensureCapturePermissions reply failed: ${error.message}")
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == CAPTURE_PERMISSION_REQUEST) {
            completeCapturePermissionRequests()
            return
        }

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

    override fun onResume() {
        super.onResume()
        // Đã quay lại app: lần rời app kế tiếp (Home) lại được vào PiP.
        suppressPipForOwnActivity = false
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

    private fun purgeMediaStoreForVnvar(folderPath: String) {
        // `%` và `_` trong tên thư mục là ký tự đại diện của LIKE: escape để
        // không xóa nhầm bản ghi của thư mục khác (vd "VNVAR_1" khớp "VNVARx1").
        val escapedFolder = folderPath
            .replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_")
        val selectionArgs = arrayOf("$escapedFolder/%")
        try {
            val uri = android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            val selection = "${android.provider.MediaStore.Video.Media.DATA} LIKE ? ESCAPE '\\'"
            contentResolver.delete(uri, selection, selectionArgs)
        } catch (_: Exception) {}
        try {
            val imageUri = android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val selection = "${android.provider.MediaStore.Images.Media.DATA} LIKE ? ESCAPE '\\'"
            contentResolver.delete(imageUri, selection, selectionArgs)
        } catch (_: Exception) {}
    }

    private fun ensurePublicVideoStorage(result: MethodChannel.Result) {
        // Di chuyển dữ liệu cũ có thể chạm nhiều file; chạy ngoài UI thread để
        // tránh ANR, rồi trả kết quả về MethodChannel trên main thread.
        Thread({
            try {
                // Lưu tại thư mục riêng của ứng dụng (App-specific external storage):
                // /storage/emulated/0/Android/data/vn.vnvar.cameraStation/files/VNVAR.
                // MediaStore/Gallery không quét Android/data/ nên video không hiện
                // trong Bộ sưu tập, và không cần quyền bộ nhớ.
                val appStorageDir = getExternalFilesDir(null) ?: filesDir
                val appVnvar = java.io.File(appStorageDir, "VNVAR")
                if (!appVnvar.exists()) {
                    appVnvar.mkdirs()
                }
                try {
                    val nomedia = java.io.File(appVnvar, ".nomedia")
                    if (!nomedia.exists()) {
                        nomedia.createNewFile()
                    }
                } catch (_: Exception) {}

                migrateLegacyPublicStorage(appVnvar)

                android.util.Log.i("MainActivity", "[STORAGE] Private VNVAR video storage initialized at: ${appVnvar.absolutePath}")
                runOnUiThread { result.success(appVnvar.absolutePath) }
            } catch (error: Exception) {
                runOnUiThread { result.error("STORAGE_INIT_FAILED", error.message, null) }
            }
        }, "VNVAR-StorageInit").start()
    }

    /**
     * Chuyển video từ thư mục công khai cũ Movies/VNVAR sang thư mục riêng.
     * Trước đây bản ghi MediaStore của thư mục cũ bị xóa trực tiếp, việc này
     * trên Android 10+ xóa luôn file video. Giờ file được di chuyển trước; chỉ
     * khi thư mục cũ không còn video nào mới dọn các bản ghi MediaStore (lúc đó
     * đã trỏ tới file không còn tồn tại).
     */
    private fun migrateLegacyPublicStorage(target: java.io.File) {
        val legacy = try {
            java.io.File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                "VNVAR",
            )
        } catch (_: Exception) {
            return
        }
        if (!legacy.isDirectory) return
        if (legacy.canonicalPath == target.canonicalPath) return

        var remaining = 0
        legacy.walkBottomUp().forEach { source ->
            if (source == legacy) return@forEach
            if (source.isDirectory) {
                // Chỉ xóa được thư mục rỗng; thư mục còn file sẽ được giữ lại.
                source.delete()
                return@forEach
            }
            if (source.name == ".nomedia") return@forEach
            val relative = source.relativeTo(legacy).path
            var destination = java.io.File(target, relative)
            if (destination.exists()) {
                // Không ghi đè dữ liệu hiện có: thêm hậu tố để giữ cả hai bản.
                destination = java.io.File(
                    destination.parentFile,
                    "${destination.nameWithoutExtension}_legacy.${destination.extension}",
                )
            }
            try {
                destination.parentFile?.mkdirs()
                val moved = source.renameTo(destination) || run {
                    source.copyTo(destination, overwrite = false)
                    if (destination.length() == source.length()) {
                        source.delete()
                    } else {
                        destination.delete()
                        false
                    }
                }
                if (!moved) remaining++
            } catch (error: Exception) {
                remaining++
                android.util.Log.w("MainActivity", "[STORAGE] Unable to migrate ${source.absolutePath}: ${error.message}")
            }
        }
        if (remaining == 0) {
            try { java.io.File(legacy, ".nomedia").delete() } catch (_: Exception) {}
            legacy.delete()
            purgeMediaStoreForVnvar(legacy.absolutePath)
            android.util.Log.i("MainActivity", "[STORAGE] Legacy Movies/VNVAR migrated to ${target.absolutePath}")
        } else {
            android.util.Log.w("MainActivity", "[STORAGE] $remaining legacy file(s) kept in ${legacy.absolutePath}")
        }
    }

    private fun launchFolderPicker() {
        // Trình chọn thư mục là màn hình do app tự mở: không vào PiP.
        suppressPipForOwnActivity = true
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
            // 2K/4K đã bỏ khỏi trạm camera (nóng máy, không nét hơn ở cùng bitrate).
        )
        return targets.mapNotNull { (id, width, height) ->
            val size = sizes.firstOrNull { it.width == width && it.height == height }
                ?: return@mapNotNull null

            // ── 1. minFrameDuration từ SCALER_STREAM_CONFIGURATION_MAP ──────────
            // Đây là khả năng phần cứng thực: thời gian tối thiểu (ns) để cảm biến
            // phơi sáng 1 frame ở kích thước này. Giá trị này chính xác và đáng tin.
            val minFrameDurationNs: Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                configuration.getOutputMinFrameDuration(SurfaceTexture::class.java, size)
            } else {
                0L
            }
            val sensorMaxFps: Int = if (minFrameDurationNs > 0L) {
                (1_000_000_000L / minFrameDurationNs).toInt().coerceAtLeast(1)
            } else {
                0
            }

            // ── 2. AE ranges chỉ dùng làm fallback / cross-check ────────────────
            // CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES phản ánh khả năng auto-exposure,
            // không nhất thiết là FPS hardware tối đa. Nhiều máy chỉ khai báo [15, 30]
            // hoặc [8, 30] dù sensor 1080p60 thực sự hỗ trợ 60 FPS qua camera2.
            val aeFpsRanges = characteristics.get(
                CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
            )
            val maxAeFps = aeFpsRanges?.map { it.upper }?.maxOrNull() ?: 30

            // ── 3. Quyết định FPS thực ──────────────────────────────────────────
            // Ưu tiên sensorMaxFps (từ minFrameDuration) vì đây là ground truth.
            // Nếu không có (thiết bị cũ, API < M), dùng maxAeFps làm fallback.
            // Không cap theo maxAeFps vì AE range thường thấp hơn khả năng thực.
            val actualFps = if (sensorMaxFps > 0) {
                sensorMaxFps.coerceIn(1, 60)
            } else {
                maxAeFps.coerceIn(1, 60)
            }

            android.util.Log.i(
                "MainActivity",
                "[CAMERA] $id ${width}x${height}: minFrameDuration=${minFrameDurationNs}ns " +
                    "→ sensorMaxFps=$sensorMaxFps, maxAeFps=$maxAeFps, actualFps=$actualFps"
            )

            mapOf(
                "id" to id,
                "width" to width,
                "height" to height,
                "maxFps" to actualFps,
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

    /**
     * Làm mới foreground type của dịch vụ CHỈ khi tập type cần thiết khác với
     * tập đã áp dụng (vd vừa được cấp quyền micro) và Activity đang hiển thị.
     * Gọi startForegroundService từ nền bị Android 12+/14 chặn bằng exception,
     * nên lỗi chỉ được ghi log, không lan ra người gọi.
     */
    private fun refreshCameraStationForegroundTypes() {
        if (!activityResumed || !CameraStationForegroundService.isRunning) return
        try {
            val required = CameraStationForegroundService.requiredForegroundTypes(this)
            if (required == CameraStationForegroundService.appliedForegroundTypes) return
            ContextCompat.startForegroundService(
                this,
                Intent(this, CameraStationForegroundService::class.java).apply {
                    action = CameraStationForegroundService.ACTION_REFRESH_TYPES
                },
            )
        } catch (error: Exception) {
            android.util.Log.w("MainActivity", "Foreground type refresh failed: ${error.message}")
        }
    }

    /** Chạy [block] trên [executor]; mọi lỗi được ghi log, không làm chết luồng. */
    private fun runInBackground(executor: ExecutorService, label: String, block: () -> Unit) {
        try {
            executor.execute {
                try {
                    block()
                } catch (error: Throwable) {
                    android.util.Log.w("MainActivity", "$label failed: ${error.message}")
                }
            }
        } catch (error: Exception) {
            android.util.Log.e("MainActivity", "$label could not be scheduled", error)
        }
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
        @Volatile
        private var sharedCellularUplink: CellularUplink? = null
        /**
         * Activity đang sở hữu MethodCallHandler của engine dùng chung. Activity
         * cũ bị huỷ SAU khi Activity mới đã gắn handler không được gỡ handler
         * hay dừng tài nguyên dùng chung (micro, 4G) của Activity mới.
         */
        @Volatile
        private var activeActivity: java.lang.ref.WeakReference<MainActivity>? = null
        // Dùng chung cho mọi instance Activity (recorder cũng dùng chung), một
        // luồng mỗi loại để giữ thứ tự start/stop âm thanh và các thao tác file.
        private val audioExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
            Thread(task, "VNVAR-Audio-Control").apply { isDaemon = true }
        }
        private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
            Thread(task, "VNVAR-Main-IO").apply { isDaemon = true }
        }
        private const val CHANNEL_NAME = "vnvar/camera_station_service"
        private const val PERMISSION_REQUEST = 4101
        private const val NOTIFICATION_PERMISSION_REQUEST = 4102
        private const val CAPTURE_PERMISSION_REQUEST = 4103
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
        // Lệnh xin quyền còn treo: trả trạng thái hiện tại thay vì bỏ rơi Future Dart.
        completeCapturePermissionRequests()
        // Không còn Activity chủ nào (null/đã thu hồi) cũng coi như là chủ.
        val currentOwner = activeActivity?.get()
        val ownsChannel = currentOwner == null || currentOwner === this
        if (ownsChannel) {
            activeActivity = null
            // Engine được giữ lại sau khi Activity huỷ: gỡ handler để lệnh Dart
            // (vd startRtsp thử lại) không còn tạo publisher/uplink trong Activity
            // đã chết (rò cổng 8554, micro, 4G). Activity mới sẽ gắn handler mới.
            if (::platformChannel.isInitialized) {
                try { platformChannel.setMethodCallHandler(null) } catch (_: Exception) {}
            }
        }
        val publisher = rtspPublisher
        rtspPublisher = null
        if (publisher != null) {
            try { publisher.stop() } catch (_: Exception) {}
        }
        if (ownsChannel) {
            // Micro (recorder dùng chung) và 4G chỉ dừng khi Activity này còn là
            // chủ; nếu Activity mới đã tiếp quản thì tài nguyên thuộc về nó.
            nativeAudioRecorder.onPcm = null
            runInBackground(audioExecutor, "stopStreaming(onDestroy)") {
                nativeAudioRecorder.stopStreaming()
            }
            if (publisher != null) notifyRtspStoppedByActivityDestroy()
            val uplink = sharedCellularUplink
            if (uplink != null) {
                // close() đồng bộ với open() (có thể đang chờ mạng di động vài giây).
                runInBackground(ioExecutor, "cellularUplink.close") { uplink.close() }
            }
        }
        super.onDestroy()
    }

    /**
     * Engine Flutter được giữ lại sau khi Activity bị huỷ: báo Dart rằng RTSP
     * đã dừng để trạng thái không còn "đang chạy" (Dart sẽ tự thử khởi động lại).
     */
    private fun notifyRtspStoppedByActivityDestroy() {
        if (!::platformChannel.isInitialized) return
        if (FlutterEngineCache.getInstance().get(ENGINE_CACHE_KEY) == null) return
        try {
            platformChannel.invokeMethod(
                "onRtspEncoderError",
                mapOf("error" to "activity_destroyed", "reason" to "activity_destroyed"),
            )
        } catch (error: Exception) {
            android.util.Log.w("MainActivity", "Unable to notify RTSP stop: ${error.message}")
        }
    }
}
