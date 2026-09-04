package vn.vnvar.cameraStation

import android.hardware.Camera
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.graphics.Rect
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
    private var activeTargetEv = 1.3
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
                    val max = manager.getCameraCharacteristics(device.id)
                        .get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)?.toDouble() ?: 1.0
                    callback(mapOf("supported" to (max > 1.0), "min" to 1.0, "max" to max.coerceAtMost(10.0), "current" to activeZoom.coerceIn(1.0, max)))
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

    fun setZoom(trackId: String, zoom: Double, callback: (Map<String, Any>) -> Unit) {
        activeZoom = zoom.coerceAtLeast(1.0)
        apply(trackId, activeTargetEv) { response -> callback(response + ("zoom" to activeZoom)) }
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
                    val sensor = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
                    val maxZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
                    if (sensor != null && maxZoom > 1f) {
                        val zoom = activeZoom.coerceIn(1.0, maxZoom.toDouble())
                        val width = (sensor.width() / zoom).roundToInt()
                        val height = (sensor.height() / zoom).roundToInt()
                        val left = sensor.centerX() - width / 2
                        val top = sensor.centerY() - height / 2
                        set(CaptureRequest.SCALER_CROP_REGION, Rect(left, top, left + width, top + height))
                        activeZoom = zoom
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
