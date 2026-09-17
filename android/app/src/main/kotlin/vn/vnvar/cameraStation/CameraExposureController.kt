package vn.vnvar.cameraStation

import android.content.Context
import android.hardware.Camera
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.GetUserMediaImpl
import org.webrtc.Camera1Capturer
import org.webrtc.Camera2Capturer
import org.webrtc.CameraEnumerationAndroid
import org.webrtc.CameraVideoCapturer
import kotlin.math.roundToInt

/** Applies a conservative exposure bias to flutter_webrtc's active camera. */
object CameraExposureController {
    private const val TAG = "CameraExposure"
    private val lifecycleHandler = Handler(Looper.getMainLooper())
    private const val WATCHDOG_INTERVAL_MS = 1_500L
    private const val CAPTURE_HEARTBEAT_TIMEOUT_MS = 3_000L

    @Volatile
    private var activeTrackId: String? = null
    @Volatile
    private var activeTargetEv = 0.0
    @Volatile private var activeZoom = 1.0
    @Volatile
    private var activeCamera2 = false
    @Volatile
    private var lastCaptureHeartbeatMs = 0L
    @Volatile
    private var requestGeneration = 0

    private val captureWatchdog = object : Runnable {
        override fun run() {
            val trackId = activeTrackId ?: return
            if (activeCamera2 &&
                SystemClock.elapsedRealtime() - lastCaptureHeartbeatMs > CAPTURE_HEARTBEAT_TIMEOUT_MS
            ) {
                Log.i(TAG, "Capture request heartbeat lost; restoring exposure")
                apply(trackId, activeTargetEv) { response ->
                    if (response["applied"] != true) {
                        Log.w(TAG, "Exposure watchdog retry failed: ${response["reason"]}")
                    }
                }
                // apply() restarts the watchdog from a single fresh schedule.
                return
            }
            lifecycleHandler.postDelayed(this, WATCHDOG_INTERVAL_MS)
        }
    }

    fun apply(trackId: String, targetEv: Double, callback: (Map<String, Any>) -> Unit) {
        if (activeTrackId != trackId) {
            requestGeneration++
            lastCaptureHeartbeatMs = 0L
        }
        activeTrackId = trackId
        activeTargetEv = targetEv
        startWatchdog()
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton
                ?: return callback(result(false, reason = "plugin_unavailable"))
            val handler = readField(plugin, "methodCallHandler")
            val getUserMedia = readField(handler, "getUserMediaImpl") as GetUserMediaImpl
            val info = getUserMedia.getCapturerInfo(trackId)
                ?: return callback(result(false, reason = "capturer_unavailable"))

            when (val capturer = info.capturer) {
                is Camera2Capturer -> {
                    activeCamera2 = true
                    applyCamera2(trackId, capturer, targetEv, callback)
                }
                is Camera1Capturer -> {
                    activeCamera2 = false
                    callback(applyCamera1(capturer, targetEv))
                }
                else -> callback(result(false, reason = "unsupported_capturer"))
            }
        } catch (error: Throwable) {
            Log.w(TAG, "Exposure boost unavailable", error)
            callback(result(false, reason = error.javaClass.simpleName))
        }
    }

    fun reapplyAfterLifecycleChange(reason: String) {
        val trackId = activeTrackId ?: return
        // Force the session-bound watchdog to verify the first capture request
        // after a foreground transition. No fixed retry window is required.
        lastCaptureHeartbeatMs = 0L
        lifecycleHandler.post {
            apply(trackId, activeTargetEv) { response ->
                if (response["applied"] == true) {
                    Log.i(
                        TAG,
                        "Exposure rebound after $reason: ${response["appliedEv"]} EV",
                    )
                }
            }
        }
    }

    fun clear(trackId: String?) {
        if (trackId != null && activeTrackId != trackId) return
        activeTrackId = null
        activeCamera2 = false
        lastCaptureHeartbeatMs = 0L
        requestGeneration++
        lifecycleHandler.removeCallbacks(captureWatchdog)
    }

    fun zoomCapabilities(trackId: String, callback: (Map<String, Any>) -> Unit) {
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton ?: error("plugin unavailable")
            val handler = readField(plugin, "methodCallHandler")
            val gum = readField(handler, "getUserMediaImpl") as GetUserMediaImpl
            val info = gum.getCapturerInfo(trackId) ?: error("capturer unavailable")
            when (val capturer = info.capturer) {
                is Camera2Capturer -> {
                    val session = readField(capturer, "currentSession")
                    val device = readField(session, "cameraDevice") as CameraDevice
                    val manager = readField(capturer, "cameraManager") as CameraManager
                    val characteristics = manager.getCameraCharacteristics(device.id)

                    // Android 11+ (API 30): CONTROL_ZOOM_RATIO_RANGE cho phép
                    // zoom < 1.0 trên thiết bị có ống kính ultra-wide.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val zoomRange = characteristics.get(
                            CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE
                        )
                        if (zoomRange != null) {
                            val minZoom = zoomRange.lower.toDouble().coerceAtLeast(0.3)
                            val maxZoom = zoomRange.upper.toDouble().coerceAtMost(10.0)
                            callback(mapOf(
                                "supported" to (maxZoom > minZoom),
                                "min" to minZoom,
                                "max" to maxZoom,
                                "current" to activeZoom.coerceIn(minZoom, maxZoom),
                                "cameraId" to device.id,
                            ))
                            return
                        }
                    }

                    // Fallback: SCALER_AVAILABLE_MAX_DIGITAL_ZOOM (min cố định 1.0)
                    val max = characteristics.get(
                        CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM
                    )?.toDouble() ?: 1.0
                    callback(mapOf(
                        "supported" to (max > 1.0),
                        "min" to 1.0,
                        "max" to max.coerceAtMost(10.0),
                        "current" to activeZoom.coerceIn(1.0, max),
                        "cameraId" to device.id,
                    ))
                }
                is Camera1Capturer -> {
                    val camera = readField(readField(capturer, "currentSession"), "camera") as Camera
                    val p = camera.parameters
                    val max = if (p.isZoomSupported) p.zoomRatios[p.maxZoom] / 100.0 else 1.0
                    callback(mapOf("supported" to p.isZoomSupported, "min" to 1.0, "max" to max, "current" to activeZoom.coerceIn(1.0, max)))
                }
                else -> callback(mapOf("supported" to false))
            }
        } catch (error: Throwable) { callback(mapOf("supported" to false, "reason" to error.javaClass.simpleName)) }
    }

    private data class ParsedCamera(
        val id: String,
        val facing: Int,
        val facingStr: String,
        val minFocal: Float,
        val fov: Float,
        val minZoom: Double,
        val maxZoom: Double,
        var isUltraWide: Boolean,
    )

    fun getAvailableCameras(context: Context): List<Map<String, Any>> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return emptyList()
        val parsedList = mutableListOf<ParsedCamera>()
        val examinedIds = mutableSetOf<String>()
        try {
            val candidateIds = mutableListOf<String>()
            candidateIds.addAll(manager.cameraIdList)

            // Probe physical IDs from logical cameras (Android 9+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                for (id in manager.cameraIdList) {
                    try {
                        val chars = manager.getCameraCharacteristics(id)
                        candidateIds.addAll(chars.physicalCameraIds)
                    } catch (_: Throwable) {}
                }
            }

            // Probe auxiliary IDs (0..9) used by Xiaomi, Samsung, Oppo, Vivo, OnePlus
            for (i in 0..9) {
                val idStr = i.toString()
                if (!candidateIds.contains(idStr)) {
                    candidateIds.add(idStr)
                }
            }

            for (id in candidateIds) {
                if (!examinedIds.add(id)) continue
                try {
                    val chars = manager.getCameraCharacteristics(id)
                    val facing = chars.get(CameraCharacteristics.LENS_FACING) ?: continue
                    val facingStr = when (facing) {
                        CameraCharacteristics.LENS_FACING_FRONT -> "front"
                        CameraCharacteristics.LENS_FACING_BACK -> "back"
                        else -> "external"
                    }
                    val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    val minFocal = focalLengths?.minOrNull() ?: 0f
                    val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                    val fov = if (sensorSize != null && minFocal > 0f) {
                        (2.0 * Math.toDegrees(Math.atan((sensorSize.width / (2.0 * minFocal)).toDouble()))).toFloat()
                    } else 0f

                    var minZoom = 1.0
                    var maxZoom = 1.0
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val zoomRange = chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                        if (zoomRange != null) {
                            minZoom = zoomRange.lower.toDouble()
                            maxZoom = zoomRange.upper.toDouble()
                        }
                    }
                    if (maxZoom <= 1.0) {
                        val maxDigital = chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)?.toDouble() ?: 1.0
                        maxZoom = maxDigital
                    }

                    // Ultra-wide criteria:
                    // 1) Facing back
                    // 2) AND (minZoom <= 0.85 OR (minFocal in 0.1f..3.5f) OR fov >= 82f)
                    val isUltraWide = (facing == CameraCharacteristics.LENS_FACING_BACK) &&
                        (minZoom <= 0.85 || (minFocal in 0.1f..3.5f) || fov >= 82f)

                    parsedList.add(ParsedCamera(id, facing, facingStr, minFocal, fov, minZoom, maxZoom, isUltraWide))
                } catch (_: Throwable) {}
            }

            // Post-process: nếu có nhiều camera sau mà chưa camera nào được đánh dấu ultra-wide
            val backCameras = parsedList.filter { it.facing == CameraCharacteristics.LENS_FACING_BACK }
            if (backCameras.size >= 2 && backCameras.none { it.isUltraWide }) {
                val primaryBack = backCameras.firstOrNull { it.id == "0" } ?: backCameras.first()
                val minFocalBack = backCameras.filter { it.minFocal > 0f }.minByOrNull { it.minFocal }
                if (minFocalBack != null && minFocalBack.id != primaryBack.id && minFocalBack.minFocal < primaryBack.minFocal) {
                    minFocalBack.isUltraWide = true
                } else {
                    val secondary = backCameras.firstOrNull { it.id != primaryBack.id }
                    secondary?.isUltraWide = true
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Error enumerating cameras: $e")
        }
        return parsedList.map {
            mapOf(
                "id" to it.id,
                "facing" to it.facingStr,
                "minFocal" to it.minFocal.toDouble(),
                "fov" to it.fov.toDouble(),
                "minZoom" to it.minZoom,
                "maxZoom" to it.maxZoom,
                "isUltraWide" to it.isUltraWide,
            )
        }
    }

    fun setZoom(trackId: String, zoom: Double, callback: (Map<String, Any>) -> Unit) {
        activeZoom = zoom.coerceAtLeast(0.3)
        apply(trackId, activeTargetEv) { response -> callback(response + ("zoom" to activeZoom)) }
    }

    fun switchCameraToId(
        trackId: String,
        targetCameraId: String,
        callback: (Boolean, String?) -> Unit,
    ) {
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton
                ?: return callback(false, "plugin_unavailable")
            val handler = readField(plugin, "methodCallHandler")
            val getUserMedia = readField(handler, "getUserMediaImpl") as GetUserMediaImpl
            val info = getUserMedia.getCapturerInfo(trackId)
                ?: return callback(false, "capturer_unavailable")
            val capturer = info.capturer as? CameraVideoCapturer
                ?: return callback(false, "not_camera_capturer")

            val manager = (capturer as? Camera2Capturer)?.let {
                try {
                    readField(it, "cameraManager") as? CameraManager
                } catch (_: Throwable) { null }
            }
            val isTargetFront = if (manager != null) {
                try {
                    val chars = manager.getCameraCharacteristics(targetCameraId)
                    chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
                } catch (_: Throwable) { false }
            } else false

            capturer.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
                override fun onCameraSwitchDone(isFrontFacing: Boolean) {
                    try {
                        val isFacingField = getUserMedia.javaClass.getDeclaredField("isFacing").apply { isAccessible = true }
                        isFacingField.set(getUserMedia, isTargetFront)
                    } catch (_: Throwable) {}
                    activeZoom = 1.0
                    lastCaptureHeartbeatMs = 0L
                    lifecycleHandler.post {
                        callback(true, null)
                    }
                }

                override fun onCameraSwitchError(errorDescription: String?) {
                    Log.w(TAG, "switchCameraToId failed for $targetCameraId: $errorDescription")
                    lifecycleHandler.post {
                        callback(false, errorDescription)
                    }
                }
            }, targetCameraId)
        } catch (e: Throwable) {
            Log.w(TAG, "switchCameraToId exception: $e")
            lifecycleHandler.post {
                callback(false, e.message)
            }
        }
    }


    private fun startWatchdog() {
        lifecycleHandler.removeCallbacks(captureWatchdog)
        lifecycleHandler.postDelayed(captureWatchdog, WATCHDOG_INTERVAL_MS)
    }

    private fun applyCamera2(
        trackId: String,
        capturer: Camera2Capturer,
        targetEv: Double,
        callback: (Map<String, Any>) -> Unit,
    ) {
        val session = readField(capturer, "currentSession")
        if (activeRotationDegrees != 0) {
            try {
                val helper = readField(session, "surfaceTextureHelper")
                val method = helper.javaClass.getMethod("setFrameRotation", Int::class.javaPrimitiveType)
                method.invoke(helper, activeRotationDegrees)
            } catch (_: Throwable) {}
        }
        val captureSession = readField(session, "captureSession") as CameraCaptureSession
        val cameraDevice = readField(session, "cameraDevice") as CameraDevice
        val surface = readField(session, "surface") as Surface
        val cameraThread = readField(session, "cameraThreadHandler") as Handler
        val captureFormat = readField(
            session,
            "captureFormat",
        ) as CameraEnumerationAndroid.CaptureFormat
        val fpsUnitFactor = readField(session, "fpsUnitFactor") as Int
        val cameraManager = readField(capturer, "cameraManager") as CameraManager
        val characteristics = cameraManager.getCameraCharacteristics(cameraDevice.id)
        val compensationRange = characteristics.get(
            CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE,
        )
        val compensationStep = characteristics.get(
            CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP,
        )?.toDouble() ?: 0.0
        val compensation = if (compensationRange != null && compensationStep > 0.0) {
            (targetEv / compensationStep).roundToInt().coerceIn(
                compensationRange.lower,
                compensationRange.upper,
            )
        } else 0
        val generation = ++requestGeneration
        cameraThread.post {
            if (activeTrackId != trackId || requestGeneration != generation) {
                callback(result(false, reason = "request_cancelled"))
                return@post
            }
            try {
                val request = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    addTarget(surface)
                    set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                    set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                    if (compensationRange != null && compensationStep > 0.0) {
                        set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, compensation)
                    }
                    set(
                        CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                        Range(
                            captureFormat.framerate.min / fpsUnitFactor,
                            captureFormat.framerate.max / fpsUnitFactor,
                        ),
                    )
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                    set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
                    // Zoom: ưu tiên CONTROL_ZOOM_RATIO (Android 11+) cho phép
                    // giá trị < 1.0 (ultra-wide). Fallback SCALER_CROP_REGION
                    // cho Android cũ hơn.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val zoomRange = characteristics.get(
                            CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE
                        )
                        if (zoomRange != null) {
                            val zoom = activeZoom.coerceIn(
                                zoomRange.lower.toDouble(),
                                zoomRange.upper.toDouble(),
                            )
                            set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom.toFloat())
                            activeZoom = zoom
                        } else {
                            applyLegacyCropZoom(this, characteristics)
                        }
                    } else {
                        applyLegacyCropZoom(this, characteristics)
                    }
                    setFirstSupportedMode(
                        this,
                        CaptureRequest.NOISE_REDUCTION_MODE,
                        characteristics.get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES),
                        CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY,
                    )
                    setFirstSupportedMode(
                        this,
                        CaptureRequest.EDGE_MODE,
                        characteristics.get(CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES),
                        CaptureRequest.EDGE_MODE_HIGH_QUALITY,
                    )
                    setFirstSupportedMode(
                        this,
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                        characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES),
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON,
                    )
                }
                captureSession.setRepeatingRequest(
                    request.build(),
                    object : CameraCaptureSession.CaptureCallback() {
                        override fun onCaptureCompleted(
                            session: CameraCaptureSession,
                            request: CaptureRequest,
                            result: TotalCaptureResult,
                        ) {
                            if (activeTrackId == trackId && requestGeneration == generation) {
                                lastCaptureHeartbeatMs = SystemClock.elapsedRealtime()
                            }
                        }
                    },
                    cameraThread,
                )
                lastCaptureHeartbeatMs = SystemClock.elapsedRealtime()
                callback(result(true, compensation, compensation * compensationStep))
            } catch (error: Throwable) {
                Log.w(TAG, "Cannot apply Camera2 exposure boost", error)
                callback(result(false, reason = error.javaClass.simpleName))
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun applyCamera1(capturer: Camera1Capturer, targetEv: Double): Map<String, Any> {
        val session = readField(capturer, "currentSession")
        val camera = readField(session, "camera") as Camera
        val parameters = camera.parameters
        val step = parameters.exposureCompensationStep.toDouble()
        val compensation = if (step > 0.0) {
            (targetEv / step).roundToInt().coerceIn(
                parameters.minExposureCompensation,
                parameters.maxExposureCompensation,
            )
        } else 0
        if (step > 0.0) parameters.exposureCompensation = compensation
        if (parameters.isZoomSupported) {
            val target = (activeZoom * 100).roundToInt()
            val index = parameters.zoomRatios.indices.minByOrNull { kotlin.math.abs(parameters.zoomRatios[it] - target) } ?: 0
            parameters.zoom = index
            activeZoom = parameters.zoomRatios[index] / 100.0
        }
        camera.parameters = parameters
        return result(true, compensation, compensation * step)
    }

    private fun readField(instance: Any, name: String): Any {
        var type: Class<*>? = instance.javaClass
        while (type != null) {
            try {
                return type.getDeclaredField(name).run {
                    isAccessible = true
                    get(instance) ?: error("$name is null")
                }
            } catch (_: NoSuchFieldException) {
                type = type.superclass
            }
        }
        error("Field $name not found in ${instance.javaClass.name}")
    }

    private fun setFirstSupportedMode(
        request: CaptureRequest.Builder,
        key: CaptureRequest.Key<Int>,
        availableModes: IntArray?,
        preferredMode: Int,
    ) {
        if (availableModes?.contains(preferredMode) == true) {
            request.set(key, preferredMode)
        }
    }

    /** Legacy zoom bằng SCALER_CROP_REGION – chỉ hỗ trợ zoom >= 1.0. */
    private fun applyLegacyCropZoom(
        request: CaptureRequest.Builder,
        characteristics: CameraCharacteristics,
    ) {
        val sensor = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val maxZoom = characteristics.get(
            CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM
        ) ?: 1f
        if (sensor != null && maxZoom > 1f) {
            val zoom = activeZoom.coerceIn(1.0, maxZoom.toDouble())
            val width = (sensor.width() / zoom).roundToInt()
            val height = (sensor.height() / zoom).roundToInt()
            val left = sensor.centerX() - width / 2
            val top = sensor.centerY() - height / 2
            request.set(
                CaptureRequest.SCALER_CROP_REGION,
                Rect(left, top, left + width, top + height),
            )
            activeZoom = zoom
        }
    }

    @Volatile
    private var activeRotationDegrees = 0

    fun setCaptureRotation(degrees: Int): Boolean {
        val normalized = ((degrees % 360) + 360) % 360
        activeRotationDegrees = normalized
        val trackId = activeTrackId ?: return false
        return applyCaptureRotation(trackId, normalized)
    }

    fun applyCaptureRotation(trackId: String, degrees: Int): Boolean {
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return false
            val handler = readField(plugin, "methodCallHandler")
            val getUserMedia = readField(handler, "getUserMediaImpl") as GetUserMediaImpl
            val info = getUserMedia.getCapturerInfo(trackId) ?: return false
            val capturer = info.capturer ?: return false
            val session = try { readField(capturer, "currentSession") } catch (_: Throwable) { null } ?: return false
            val helper = try { readField(session, "surfaceTextureHelper") } catch (_: Throwable) { null } ?: return false
            val method = helper.javaClass.getMethod("setFrameRotation", Int::class.javaPrimitiveType)
            method.invoke(helper, degrees)
            Log.i(TAG, "Applied capture frame rotation to WebRTC: $degrees°")
            return true
        } catch (e: Throwable) {
            Log.w(TAG, "Cannot set capture rotation to $degrees°: $e")
            return false
        }
    }

    private fun result(
        applied: Boolean,
        compensation: Int = 0,
        appliedEv: Double = 0.0,
        reason: String? = null,
    ): Map<String, Any> = buildMap {
        put("applied", applied)
        put("compensation", compensation)
        put("appliedEv", appliedEv)
        if (reason != null) put("reason", reason)
    }
}
