package vn.vnvar.cameraStation

import android.content.Context
import android.hardware.Camera
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.MeteringRectangle
import android.graphics.Rect
import android.graphics.SurfaceTexture
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
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Applies a conservative exposure bias to flutter_webrtc's active camera. */
object CameraExposureController {
    private const val TAG = "CameraExposure"
    private val lifecycleHandler = Handler(Looper.getMainLooper())
    private const val WATCHDOG_INTERVAL_MS = 1_500L
    /** Trần giãn cách thử lại của watchdog khi plugin/capturer liên tục không có. */
    private const val WATCHDOG_MAX_BACKOFF_MS = 30_000L
    private const val CAPTURE_HEARTBEAT_TIMEOUT_MS = 3_000L
    private const val METERING_REGION_FRACTION = 0.3
    /** AE/AF phải ổn định liên tục chừng này trước khi tự khoá. */
    private const val STABLE_LOCK_AFTER_MS = 2_000L
    /** Không khoá trong chừng này sau khi phiên chụp mở (AF/AE còn đang chạy lần đầu). */
    private const val MIN_LOCK_AFTER_SESSION_MS = 3_000L
    /**
     * AF không báo "đã nét" sau chừng này (cảnh quá tối/phẳng) thì khoá tiêu cự ở
     * vị trí hiện tại (sau khi AF đã quét) và cho phép khoá AE/AWB.
     */
    private const val AF_FOCUS_TIMEOUT_MS = 8_000L
    /** AF báo nét (sau khi đã quét) liên tục chừng này thì khoá tiêu cự. */
    private const val FOCUS_LOCK_AFTER_MS = 1_000L
    /**
     * AE không bao giờ báo CONVERGED (đèn LED/màn hình nhấp nháy, cảnh rất
     * tương phản) thì sau chừng này vẫn khoá AE/AWB để hình hết "thở" sáng/màu;
     * bộ đo độ lệch sáng vẫn mở khoá đo lại khi ánh sáng thật sự đổi.
     */
    private const val AE_SETTLE_TIMEOUT_MS = 8_000L
    /** Độ sáng khung hình lệch khỏi lúc khoá quá ngưỡng này... */
    private const val RELOCK_LUMA_DRIFT = 0.20
    /** ...liên tục chừng này (ánh sáng thật sự đổi, không phải người đi ngang) thì đo lại. */
    private const val RELOCK_AFTER_MS = 5_000L
    /**
     * Hình đang khoá mà quá sáng/quá tối rõ rệt (độ sáng trung bình 0..255) thì
     * đo lại sớm hơn, kể cả khi độ lệch tương đối chưa tới [RELOCK_LUMA_DRIFT]
     * (ví dụ khung đã gần trắng nên không còn "chỗ" để lệch thêm).
     */
    private const val OVEREXPOSED_LUMA = 195.0
    private const val UNDEREXPOSED_LUMA = 35.0
    private const val EXTREME_MIN_DRIFT = 0.10
    private const val EXTREME_RELOCK_AFTER_MS = 3_000L
    /**
     * Khoá lâu (ánh sáng đổi chậm: nắng lên/xuống) thì kiểm tra định kỳ; CHỈ đo
     * lại khi hình đã lệch rõ ([PERIODIC_MIN_DRIFT]). Hình còn đúng thì giữ khoá,
     * không đụng tới camera (không chớp khi đang livestream/Check VAR).
     */
    private const val PERIODIC_REMETER_MS = 10 * 60 * 1_000L
    private const val PERIODIC_MIN_DRIFT = 0.10

    @Volatile
    private var activeTrackId: String? = null
    @Volatile
    private var activeTargetEv = 0.0
    @Volatile private var activeZoom = 1.0
    @Volatile
    private var activeCameraLock = false
    @Volatile
    private var activeCamera2 = false
    @Volatile
    private var lastCaptureHeartbeatMs = 0L
    @Volatile
    private var requestGeneration = 0
    /** Điểm đo sáng do người dùng chạm (toạ độ chuẩn hoá trên preview); null = vùng giữa. */
    @Volatile
    private var activeMeteringPoint: Pair<Double, Double>? = null
    /** Cấu hình của repeating request đang chạy, để bỏ qua các lần áp dụng trùng lặp. */
    @Volatile
    private var lastAppliedKey: String? = null

    // Chế độ "ổn định": sau khi AE/AF hội tụ, khoá phơi sáng, cân bằng trắng và
    // lấy nét để hình không "thở" sáng/tối hay mờ khi người chơi đi qua. Chỉ mở
    // khoá đo lại khi độ sáng cả khung hình đổi lâu (bật/tắt đèn, mây che).
    @Volatile
    private var stableExposureEnabled = true
    @Volatile
    private var autoLocked = false
    @Volatile
    private var lockPending = false
    @Volatile
    private var lockedFocusDistance: Float? = null
    /** Ống kính hiện tại có lấy nét tự động (không phải ống fixed-focus). */
    @Volatile
    private var activeHasAutoFocus = false
    /** Ống kính cho chỉnh tay tiêu cự (AF_MODE_OFF + LENS_FOCUS_DISTANCE). */
    @Volatile
    private var activeManualFocus = false
    /** Capture session đang theo dõi và thời điểm nó bắt đầu (elapsedRealtime). */
    @Volatile
    private var sessionStartHash = 0
    @Volatile
    private var sessionStartedMs = 0L
    /**
     * AF đã thật sự quét (PASSIVE_SCAN/ACTIVE_SCAN) kể từ lần mở phiên / nhả
     * khoá tiêu cự gần nhất. Một số máy (Samsung) báo PASSIVE_FOCUSED ngay khi
     * vừa thay request dù ống kính chưa quét → khoá nhầm tiêu cự mờ, phải zoom
     * vào/ra mới nét. Chỉ tin trạng thái "đã nét" sau khi đã thấy quét.
     */
    @Volatile
    private var afScanSeen = false
    /** Cần "đá" AF quét lại (START rồi CANCEL) ở request kế tiếp. */
    @Volatile
    private var afRestartPending = true
    /** Khoá tiêu cự tách khỏi khoá AE (xem observeConvergence). */
    @Volatile
    private var focusLockPending = false
    @Volatile
    private var focusedSinceMs = 0L
    /** Lần nhả khoá tiêu cự / khoá AE gần nhất (elapsedRealtime). */
    @Volatile
    private var focusReleasedAtMs = 0L
    @Volatile
    private var aeReleasedAtMs = 0L
    @Volatile
    private var convergedSinceMs = 0L
    @Volatile
    private var lumaRefAtLock: Double? = null
    @Volatile
    private var lumaDriftSinceMs = 0L
    @Volatile
    private var lockedAtMs = 0L
    /** Capture session của request đang chạy / lúc khoá phơi sáng. */
    @Volatile
    private var currentSessionHash = 0
    @Volatile
    private var lockedSessionHash: Int? = null
    /**
     * Số lần liên tiếp watchdog khôi phục request thất bại (plugin/capturer
     * chưa có, camera thread dừng...). Dùng để giãn dần khoảng thử
     * (1,5 s → tối đa 30 s) và chỉ ghi log lần đầu. Về 0 khi apply thành công.
     */
    @Volatile
    private var watchdogFailures = 0
    /** Đã tự kiểm tra các trường private của flutter_webrtc dùng qua reflection. */
    @Volatile
    private var reflectionChecked = false
    private val lumaMeter = LumaMeter { trackId, luma ->
        lifecycleHandler.post { onLuma(trackId, luma) }
    }

    private val captureWatchdog = object : Runnable {
        override fun run() {
            val trackId = activeTrackId ?: return
            if (activeCamera2 &&
                SystemClock.elapsedRealtime() - lastCaptureHeartbeatMs > CAPTURE_HEARTBEAT_TIMEOUT_MS
            ) {
                // Chỉ ghi log ở lần đầu của một chuỗi thất bại (không spam log
                // mỗi 1,5 s khi plugin/capturer đã mất hẳn).
                if (watchdogFailures == 0) {
                    Log.i(TAG, "Capture request heartbeat lost; restoring exposure")
                }
                apply(trackId, activeTargetEv) { response ->
                    if (response["applied"] != true &&
                        response["reason"] != "request_cancelled"
                    ) {
                        onWatchdogRetryFailed(trackId, response["reason"])
                    }
                }
                // apply() restarts the watchdog from a single fresh schedule
                // (giãn cách lại trong onWatchdogRetryFailed khi thất bại).
                return
            }
            if (!lumaMeter.isAttachedTo(trackId)) lumaMeter.attach(trackId)
            lifecycleHandler.postDelayed(this, WATCHDOG_INTERVAL_MS)
        }
    }

    /**
     * Watchdog không khôi phục được request: thay lịch 1,5 s mà apply() vừa đặt
     * bằng khoảng thử giãn dần (1,5 s × 2^n, tối đa 30 s). Gọi từ main hoặc
     * camera thread (Handler an toàn đa luồng).
     */
    private fun onWatchdogRetryFailed(trackId: String, reason: Any?) {
        if (activeTrackId != trackId) return
        val failures = watchdogFailures + 1
        watchdogFailures = failures
        val shift = (failures).coerceAtMost(5)
        val delayMs = (WATCHDOG_INTERVAL_MS shl shift).coerceAtMost(WATCHDOG_MAX_BACKOFF_MS)
        if (failures == 1) {
            Log.w(TAG, "Exposure watchdog retry failed: $reason; backing off (max ${WATCHDOG_MAX_BACKOFF_MS / 1000} s, further failures not logged)")
        }
        lifecycleHandler.removeCallbacks(captureWatchdog)
        lifecycleHandler.postDelayed(captureWatchdog, delayMs)
    }

    fun apply(trackId: String, targetEv: Double, requestCallback: (Map<String, Any>) -> Unit) {
        // Apply thành công (từ bất kỳ nguồn nào) đưa watchdog về nhịp 1,5 s.
        val callback: (Map<String, Any>) -> Unit = { response ->
            if (response["applied"] == true) watchdogFailures = 0
            requestCallback(response)
        }
        if (activeTrackId != trackId) {
            requestGeneration++
            lastCaptureHeartbeatMs = 0L
            releaseAutoLock()
            lumaMeter.attach(trackId)
        }
        if (autoLocked && abs(targetEv - activeTargetEv) > 1e-6) {
            // Người dùng đổi độ sáng (EV) khi đang khoá: đo lại NGAY với mức mới
            // rồi khoá lại. Trước đây vẫn giữ khoá + mốc sáng cũ nên ~5 s sau bộ
            // đo độ lệch sáng coi là "cảnh đổi" và đo lại, làm hình nhảy sáng/tối.
            releaseAutoLock(keepFocus = true)
        }
        activeTrackId = trackId
        activeTargetEv = targetEv
        startWatchdog()
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton
                ?: return callback(result(false, reason = "plugin_unavailable"))
            if (!reflectionChecked) verifyReflectionContract(plugin, trackId)
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
            // Watchdog đang thử lại liên tục: không ghi lại stack trace mỗi lần.
            if (watchdogFailures == 0) Log.w(TAG, "Exposure boost unavailable", error)
            callback(result(false, reason = error.javaClass.simpleName))
        }
    }

    private fun hasField(type: Class<*>?, name: String): Boolean {
        var current = type
        while (current != null) {
            try {
                current.getDeclaredField(name)
                return true
            } catch (_: NoSuchFieldException) {
                current = current.superclass
            }
        }
        return false
    }

    /**
     * Tự kiểm tra một lần các trường private của flutter_webrtc mà controller
     * đọc qua reflection; log rõ trường nào thiếu (bản flutter_webrtc khác) thay
     * vì chỉ thấy lỗi chung chung ở mỗi lần apply. Không bao giờ ném lỗi. Chỉ
     * đánh dấu "đã kiểm" khi đã kiểm được tới tầng session (hoặc đã thiếu sớm).
     */
    private fun verifyReflectionContract(plugin: Any, trackId: String) {
        try {
            val missing = mutableListOf<String>()
            fun check(owner: Any?, label: String, vararg names: String) {
                if (owner == null) return
                for (name in names) {
                    if (!hasField(owner.javaClass, name)) missing += "$label.$name"
                }
            }
            fun readOrNull(owner: Any?, name: String): Any? =
                if (owner == null) null else try { readField(owner, name) } catch (_: Throwable) { null }

            check(plugin, plugin.javaClass.simpleName, "methodCallHandler")
            val handler = readOrNull(plugin, "methodCallHandler")
            check(handler, handler?.javaClass?.simpleName ?: "MethodCallHandler", "getUserMediaImpl")
            val getUserMedia = readOrNull(handler, "getUserMediaImpl")
            check(getUserMedia, "GetUserMediaImpl", "isFacing")
            val capturer = try {
                (getUserMedia as? GetUserMediaImpl)?.getCapturerInfo(trackId)?.capturer
            } catch (_: Throwable) {
                null
            }
            var complete = handler == null || getUserMedia == null
            when (capturer) {
                is Camera2Capturer -> {
                    check(capturer, "Camera2Capturer", "currentSession", "cameraManager")
                    val session = readOrNull(capturer, "currentSession")
                    if (session != null) {
                        check(
                            session,
                            session.javaClass.simpleName,
                            "cameraDevice",
                            "captureSession",
                            "surface",
                            "cameraThreadHandler",
                            "captureFormat",
                            "fpsUnitFactor",
                            "surfaceTextureHelper",
                        )
                        complete = true
                    }
                }
                is Camera1Capturer -> {
                    check(capturer, "Camera1Capturer", "currentSession")
                    val session = readOrNull(capturer, "currentSession")
                    if (session != null) {
                        check(session, session.javaClass.simpleName, "camera", "surfaceTextureHelper")
                        complete = true
                    }
                }
                null -> {}
                else -> complete = true
            }
            if (missing.isNotEmpty()) {
                reflectionChecked = true
                Log.e(
                    TAG,
                    "flutter_webrtc reflection self-check: missing private field(s) " +
                        missing.joinToString() + " — exposure/zoom/rotation control may not work",
                )
            } else if (complete) {
                reflectionChecked = true
                Log.i(TAG, "flutter_webrtc reflection self-check OK")
            }
        } catch (error: Throwable) {
            reflectionChecked = true
            Log.w(TAG, "flutter_webrtc reflection self-check failed", error)
        }
    }

    fun reapplyAfterLifecycleChange(reason: String) {
        val trackId = activeTrackId ?: return
        // Không ép thay repeating request khi request của app vẫn đang chạy:
        // mỗi lần thay request (tắt màn hình, kéo thanh thông báo) có thể làm
        // AE/AF hội tụ lại và gây chớp sáng trên livestream. apply() tự bỏ qua
        // khi cấu hình không đổi và heartbeat còn tươi; nếu session đã bị dựng
        // lại thì heartbeat cũ và request được áp dụng lại ngay.
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
        activeCameraLock = false
        activeMeteringPoint = null
        lastAppliedKey = null
        releaseAutoLock()
        lumaMeter.detach()
        lastCaptureHeartbeatMs = 0L
        requestGeneration++
        watchdogFailures = 0
        lifecycleHandler.removeCallbacks(captureWatchdog)
    }

    /** Bật/tắt tự khoá phơi sáng sau khi hội tụ (mặc định bật). */
    fun setStableExposure(trackId: String, enabled: Boolean, callback: (Map<String, Any>) -> Unit) {
        stableExposureEnabled = enabled
        releaseAutoLock()
        apply(trackId, activeTargetEv, callback)
    }

    /**
     * Giảm FPS đầu ra ngay tại VideoSource (bỏ bớt khung) mà không mở lại camera,
     * nên livestream/ghi hình không bị ngắt. [fps] null/<=0 trả về FPS gốc.
     */
    fun setCaptureFpsCap(trackId: String, fps: Int?): Boolean {
        return try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return false
            val handler = readField(plugin, "methodCallHandler")
            val getUserMedia = readField(handler, "getUserMediaImpl") as GetUserMediaImpl
            val info = getUserMedia.getCapturerInfo(trackId) ?: return false
            val source = info.videoSource ?: return false
            if (info.width <= 0 || info.height <= 0 || info.fps <= 0) return false
            val target = if (fps == null || fps <= 0) info.fps else min(fps, info.fps)
            source.adaptOutputFormat(info.width, info.height, target)
            Log.i(TAG, "Capture output limited to $target fps (camera ${info.fps} fps)")
            true
        } catch (error: Throwable) {
            Log.w(TAG, "Cannot limit capture fps", error)
            false
        }
    }

    /**
     * Mở khoá phơi sáng để AE đo lại. [keepFocus]: giữ ống kính ở tiêu cự đã
     * khoá (chỉ đo lại độ sáng, không "săn nét" lại).
     */
    private fun releaseAutoLock(keepFocus: Boolean = false) {
        autoLocked = false
        lockPending = false
        val now = SystemClock.elapsedRealtime()
        if (!keepFocus) {
            lockedFocusDistance = null
            afScanSeen = false
            afRestartPending = true
            focusLockPending = false
            focusedSinceMs = 0L
            focusReleasedAtMs = now
        }
        aeReleasedAtMs = now
        convergedSinceMs = 0L
        lumaRefAtLock = null
        lumaDriftSinceMs = 0L
        lockedAtMs = 0L
        lockedSessionHash = null
    }

    /**
     * Gọi trên camera thread với mỗi kết quả của request hiện tại.
     *
     * Hai khoá ĐỘC LẬP (máy đặt cố định trên chân):
     * 1. Tiêu cự: AF đã quét rồi báo nét ~1 s (ống kính đứng yên) → khoá đúng
     *    tiêu cự đó (AF OFF). AF quét mãi không nét (cảnh phẳng/tối) thì sau
     *    [AF_FOCUS_TIMEOUT_MS] khoá ở vị trí tốt nhất AF tìm được. Trước đây
     *    tiêu cự chỉ khoá CÙNG lúc khoá AE: cảnh có màn hình/đèn LED làm AE không
     *    bao giờ "hội tụ" nên AF chạy liên tục → ống kính săn nét, hình như
     *    zoom ra/vào (focus breathing) và mờ/nét liên tục.
     * 2. AE/AWB: hội tụ ổn định 2 s, hoặc sau [AE_SETTLE_TIMEOUT_MS] dù AE chưa
     *    báo hội tụ → khoá để hết nhảy sáng/màu.
     */
    private fun observeConvergence(trackId: String, generation: Int, result: TotalCaptureResult) {
        if (!stableExposureEnabled || activeCameraLock) return
        val now = SystemClock.elapsedRealtime()
        val af = result.get(CaptureResult.CONTROL_AF_STATE)
        // Chỉ coi là "đã nét" khi AF thật sự báo nét SAU khi đã quét: INACTIVE lúc
        // mới mở camera nghĩa là AF chưa chạy; vài máy (Samsung) báo
        // PASSIVE_FOCUSED ngay khi vừa thay request dù ống kính chưa quét.
        val afFocused = af == CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED ||
            af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED
        val afScanning = af == CaptureResult.CONTROL_AF_STATE_PASSIVE_SCAN ||
            af == CaptureResult.CONTROL_AF_STATE_ACTIVE_SCAN
        if (afScanning) afScanSeen = true
        val afFocusTrusted = afFocused && afScanSeen
        val sinceSessionMs = if (sessionStartedMs > 0L) now - sessionStartedMs else 0L
        val sinceFocusReleaseMs =
            if (focusReleasedAtMs > 0L) now - focusReleasedAtMs else sinceSessionMs
        val afTimedOut = min(sinceSessionMs, sinceFocusReleaseMs) >= AF_FOCUS_TIMEOUT_MS

        // ---- 1. Khoá tiêu cự ----
        if (lockedFocusDistance == null && activeHasAutoFocus && !focusLockPending &&
            sinceSessionMs >= MIN_LOCK_AFTER_SESSION_MS
        ) {
            val lensStill = result.get(CaptureResult.LENS_STATE) !=
                CaptureResult.LENS_STATE_MOVING
            if (afFocusTrusted && lensStill) {
                if (focusedSinceMs == 0L) focusedSinceMs = now
            } else {
                focusedSinceMs = 0L
            }
            val focusedLongEnough = focusedSinceMs > 0L &&
                now - focusedSinceMs >= FOCUS_LOCK_AFTER_MS
            val gaveUp = afTimedOut && afScanSeen && !afScanning && lensStill
            // Máy không chỉnh tay được tiêu cự thường không báo LENS_FOCUS_DISTANCE;
            // khi đó khoá bằng AF_MODE_AUTO (không dùng giá trị) nên dùng 0f làm dấu.
            val distance = result.get(CaptureResult.LENS_FOCUS_DISTANCE)
                ?: if (!activeManualFocus) 0f else null
            if ((focusedLongEnough || gaveUp) && distance != null) {
                focusLockPending = true
                lifecycleHandler.post {
                    focusLockPending = false
                    if (activeTrackId != trackId || requestGeneration != generation ||
                        activeCameraLock || !stableExposureEnabled ||
                        lockedFocusDistance != null
                    ) return@post
                    lockedFocusDistance = distance
                    Log.i(TAG, "Focus " + (if (focusedLongEnough) "settled" else "search timed out") +
                        "; locking focus at $distance dpt")
                    apply(trackId, activeTargetEv) {}
                }
                return
            }
        }

        // ---- 2. Khoá AE/AWB ----
        if (autoLocked || lockPending) return
        // Không có bộ đo sáng thì không phát hiện được ánh sáng đổi để mở khoá:
        // giữ AE/AWB tự động (khoá tiêu cự ở trên không cần bộ đo sáng).
        if (!lumaMeter.isAttachedTo(trackId)) return
        val ae = result.get(CaptureResult.CONTROL_AE_STATE) ?: return
        val sinceAeReleaseMs =
            if (aeReleasedAtMs > 0L) now - aeReleasedAtMs else sinceSessionMs
        val aeSettled = ae == CaptureResult.CONTROL_AE_STATE_CONVERGED ||
            ae == CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED ||
            (min(sinceSessionMs, sinceAeReleaseMs) >= AE_SETTLE_TIMEOUT_MS &&
                ae != CaptureResult.CONTROL_AE_STATE_PRECAPTURE)
        // Chờ tiêu cự khoá trước (hoặc hết hạn) để lần khoá AE không bị request
        // khoá tiêu cự thay ngay sau đó.
        val focusReady = !activeHasAutoFocus || af == null ||
            lockedFocusDistance != null || afTimedOut
        if (!aeSettled || !focusReady || sinceSessionMs < MIN_LOCK_AFTER_SESSION_MS) {
            convergedSinceMs = 0L
            return
        }
        if (convergedSinceMs == 0L) {
            convergedSinceMs = now
            return
        }
        if (now - convergedSinceMs < STABLE_LOCK_AFTER_MS) return
        lockPending = true
        lifecycleHandler.post {
            lockPending = false
            if (activeTrackId != trackId || requestGeneration != generation ||
                autoLocked || activeCameraLock || !stableExposureEnabled
            ) return@post
            autoLocked = true
            lumaRefAtLock = lumaMeter.current
            lumaDriftSinceMs = 0L
            lockedAtMs = SystemClock.elapsedRealtime()
            lockedSessionHash = currentSessionHash
            Log.i(TAG, "Exposure settled; locking AE/AWB")
            apply(trackId, activeTargetEv) {}
        }
    }

    /** Main thread: độ sáng trung bình khung hình (0..255, đã làm mượt). */
    private fun onLuma(trackId: String, luma: Double) {
        if (activeTrackId != trackId || !autoLocked) {
            lumaDriftSinceMs = 0L
            return
        }
        val reference = lumaRefAtLock
        if (reference == null) {
            lumaRefAtLock = luma
            return
        }
        val drift = abs(luma - reference) / max(reference, 24.0)
        val now = SystemClock.elapsedRealtime()
        if (lockedAtMs > 0L && now - lockedAtMs >= PERIODIC_REMETER_MS) {
            if (drift < PERIODIC_MIN_DRIFT) {
                // Hình vẫn đúng sáng: giữ nguyên, hẹn kiểm tra lần sau.
                lockedAtMs = now
            } else {
                Log.i(TAG, "Periodic re-meter after ${(now - lockedAtMs) / 60_000} min locked")
                releaseAutoLock(keepFocus = true)
                apply(trackId, activeTargetEv) {}
                return
            }
        }
        val extreme = (luma >= OVEREXPOSED_LUMA || luma <= UNDEREXPOSED_LUMA) &&
            drift >= EXTREME_MIN_DRIFT
        if (drift < RELOCK_LUMA_DRIFT && !extreme) {
            lumaDriftSinceMs = 0L
            return
        }
        if (lumaDriftSinceMs == 0L) {
            lumaDriftSinceMs = now
            return
        }
        val waitMs = if (extreme) EXTREME_RELOCK_AFTER_MS else RELOCK_AFTER_MS
        if (now - lumaDriftSinceMs < waitMs) return
        Log.i(TAG, "Scene brightness changed (${reference.roundToInt()} -> ${luma.roundToInt()}); re-metering")
        // Tiêu cự không đổi khi chỉ ánh sáng đổi: giữ nét, chỉ đo lại độ sáng.
        releaseAutoLock(keepFocus = true)
        apply(trackId, activeTargetEv) {}
    }

    /**
     * Đo sáng theo điểm chạm mà vẫn giữ nguyên toàn bộ cấu hình request của app
     * (EV, FPS, zoom, NR/EIS). Thay cho Helper.setExposurePoint của flutter_webrtc,
     * vốn thay request bằng TEMPLATE_RECORD trần (sáng/zoom nhảy rồi watchdog trả lại).
     */
    fun setMeteringPoint(trackId: String, x: Double, y: Double, callback: (Map<String, Any>) -> Unit) {
        activeMeteringPoint = Pair(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0))
        activeCameraLock = false
        releaseAutoLock()
        apply(trackId, activeTargetEv, callback)
    }

    fun setLock(trackId: String, locked: Boolean, callback: (Map<String, Any>) -> Unit) {
        if (activeCameraLock != locked) releaseAutoLock()
        activeCameraLock = locked
        apply(trackId, activeTargetEv) { res ->
            callback(mapOf(
                "applied" to (res["applied"] == true),
                "locked" to locked,
                "trackId" to trackId,
            ))
        }
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
                            val maxZoom = zoomRange.upper.toDouble().coerceIn(1.0, 5.0)
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
                        "max" to max.coerceIn(1.0, 5.0),
                        "current" to activeZoom.coerceIn(1.0, max.coerceIn(1.0, 5.0)),
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

                    // Kiểm tra khả năng xuất video qua SurfaceTexture
                    val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: continue
                    val surfaceSizes = map.getOutputSizes(SurfaceTexture::class.java)
                    if (surfaceSizes.isNullOrEmpty()) continue

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
                            maxZoom = zoomRange.upper.toDouble().coerceIn(1.0, 5.0)
                        }
                    }
                    if (maxZoom <= 1.0) {
                        val maxDigital = chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)?.toDouble() ?: 1.0
                        maxZoom = maxDigital.coerceIn(1.0, 5.0)
                    }

                    // Ultra-wide criteria:
                    // 1) Facing back
                    // 2) Auxiliary camera (id != "0") - ID "0" is always the primary main camera
                    // 3) AND (minZoom <= 0.85 OR (minFocal in 0.1f..3.5f) OR fov >= 82f)
                    val isUltraWide = (id != "0") && (facing == CameraCharacteristics.LENS_FACING_BACK) &&
                        (minZoom <= 0.85 || (minFocal in 0.1f..3.5f) || fov >= 82f)

                    parsedList.add(ParsedCamera(id, facing, facingStr, minFocal, fov, minZoom, maxZoom, isUltraWide))
                } catch (_: Throwable) {}
            }

            // Post-process: nếu có nhiều camera sau mà chưa camera nào được đánh dấu ultra-wide
            // Chỉ đánh dấu camera phụ là ultra-wide NẾU tiêu cự của nó ngắn hơn rõ rệt (< 85%) so với camera chính.
            // Tuyệt đối không dùng fallback mù sang camera phụ vì có thể đó là ống kính Telephoto (zoom xa).
            val backCameras = parsedList.filter { it.facing == CameraCharacteristics.LENS_FACING_BACK }
            if (backCameras.size >= 2 && backCameras.none { it.isUltraWide }) {
                val primaryBack = backCameras.firstOrNull { it.id == "0" } ?: backCameras.first()
                val minFocalBack = backCameras.filter { it.minFocal > 0f && it.id != primaryBack.id }.minByOrNull { it.minFocal }
                if (minFocalBack != null && primaryBack.minFocal > 0f && minFocalBack.minFocal < primaryBack.minFocal * 0.85f) {
                    minFocalBack.isUltraWide = true
                }
                // Nếu không thể xác định ultra-wide dựa trên tiêu cự,
                // KHÔNG đánh dấu mù vì camera phụ có thể là Telephoto.
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
        val newZoom = zoom.coerceIn(0.3, 5.0)
        // Đổi khung hình: đo sáng/lấy nét lại rồi tự khoá lại.
        if (abs(newZoom - activeZoom) > 0.01) releaseAutoLock()
        activeZoom = newZoom
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

            val previousCameraId = (capturer as? Camera2Capturer)?.let {
                try {
                    val session = readField(it, "currentSession")
                    val dev = readField(session, "cameraDevice") as? CameraDevice
                    dev?.id
                } catch (_: Throwable) { null }
            } ?: "0"

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
                    activeCameraLock = false
                    activeMeteringPoint = null
                    lastAppliedKey = null
                    lastCaptureHeartbeatMs = 0L
                    lifecycleHandler.post {
                        releaseAutoLock()
                        callback(true, null)
                    }
                }

                override fun onCameraSwitchError(errorDescription: String?) {
                    Log.w(TAG, "switchCameraToId failed for $targetCameraId: $errorDescription. Auto-reverting to $previousCameraId")
                    try {
                        capturer.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
                            override fun onCameraSwitchDone(isFrontFacing: Boolean) {
                                lifecycleHandler.post { callback(false, errorDescription) }
                            }
                            override fun onCameraSwitchError(err: String?) {
                                lifecycleHandler.post { callback(false, errorDescription) }
                            }
                        }, previousCameraId)
                    } catch (_: Throwable) {
                        lifecycleHandler.post {
                            callback(false, errorDescription)
                        }
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
        val sessionHash = System.identityHashCode(captureSession)
        currentSessionHash = sessionHash
        if (sessionStartHash != sessionHash) {
            sessionStartHash = sessionHash
            sessionStartedMs = SystemClock.elapsedRealtime()
            afScanSeen = false
            afRestartPending = true
            focusedSinceMs = 0L
            // Phiên chụp mới (đổi ống kính/độ phân giải, camera dựng lại): tiêu
            // cự đã khoá thuộc phiên cũ, có thể của ống kính khác → lấy nét lại.
            // (Trước đây chỉ nhả khi AE cũng đang khoá.)
            if (lockedFocusDistance != null) {
                lockedFocusDistance = null
                focusLockPending = false
                focusReleasedAtMs = sessionStartedMs
            }
        }
        val lockedOn = lockedSessionHash
        if (autoLocked && lockedOn != null && lockedOn != sessionHash) {
            // Camera vừa dựng lại phiên chụp (lỗi camera, hệ thống, đổi định
            // dạng, đổi ống kính...): khoá phơi sáng cũ sẽ "đóng băng" mức sáng lúc
            // phiên mới vừa mở. Đo sáng VÀ lấy nét lại (tiêu cự cũ có thể thuộc
            // ống kính khác), hội tụ xong mới khoá.
            Log.i(TAG, "Capture session rebuilt while exposure locked; re-metering")
            releaseAutoLock()
        }
        val cameraManager = readField(capturer, "cameraManager") as CameraManager
        val characteristics = cameraManager.getCameraCharacteristics(cameraDevice.id)
        val availableAfModes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
        activeHasAutoFocus = (characteristics.get(
            CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE,
        ) ?: 0f) > 0f && availableAfModes?.any {
            it == CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO ||
                it == CaptureRequest.CONTROL_AF_MODE_AUTO
        } == true
        activeManualFocus = (characteristics.get(
            CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE,
        ) ?: 0f) > 0f && availableAfModes?.contains(CaptureRequest.CONTROL_AF_MODE_OFF) == true
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
        val appliedKey = listOf(
            trackId,
            sessionHash,
            compensation,
            activeCameraLock,
            autoLocked,
            lockedFocusDistance,
            activeZoom,
            activeMeteringPoint,
            activeRotationDegrees,
        ).joinToString("|")
        if (appliedKey == lastAppliedKey &&
            SystemClock.elapsedRealtime() - lastCaptureHeartbeatMs < CAPTURE_HEARTBEAT_TIMEOUT_MS
        ) {
            // Request đang chạy đã đúng cấu hình: thay lại chỉ làm AE hội tụ lại.
            callback(result(true, compensation, compensation * compensationStep))
            return
        }
        val generation = ++requestGeneration
        val posted = cameraThread.post {
            if (activeTrackId != trackId || requestGeneration != generation) {
                callback(result(false, reason = "request_cancelled"))
                return@post
            }
            try {
                // AF_MODE_AUTO dùng để QUÉT (máy không có CONTINUOUS_VIDEO), khác
                // AF_MODE_AUTO dùng để GIỮ tiêu cự (đã khoá / khoá camera).
                var afAutoScanMode = false
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
                    val locked = activeCameraLock || autoLocked
                    val aeLockAvailable = characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true
                    if (aeLockAvailable) {
                        set(CaptureRequest.CONTROL_AE_LOCK, locked)
                    }
                    val awbLockAvailable = characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true
                    if (awbLockAvailable) {
                        set(CaptureRequest.CONTROL_AWB_LOCK, locked)
                    }
                    val afModes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
                    val focusDistance = lockedFocusDistance
                    val manualFocus = (characteristics.get(
                        CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE,
                    ) ?: 0f) > 0f && afModes?.contains(CaptureRequest.CONTROL_AF_MODE_OFF) == true
                    // Giữ tiêu cự cả khi đang đo lại độ sáng (lockedFocusDistance
                    // còn giữ sau releaseAutoLock(keepFocus = true)).
                    if (focusDistance != null && manualFocus && !activeCameraLock) {
                        // Giữ ống kính đúng tiêu cự đã hội tụ: không "săn nét" khi
                        // người chơi đi gần/xa (máy đặt cố định trên chân).
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                        set(CaptureRequest.LENS_FOCUS_DISTANCE, focusDistance)
                    } else if (focusDistance != null && !activeCameraLock &&
                        afModes?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true
                    ) {
                        // Máy không cho chỉnh tay tiêu cự: AF_MODE_AUTO không kèm
                        // trigger giữ ống kính đứng yên ở vị trí vừa quét được.
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                    } else if (activeCameraLock) {
                        if (afModes?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true) {
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                        } else if (afModes?.contains(CaptureRequest.CONTROL_AF_MODE_OFF) == true) {
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                        } else {
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        }
                    } else {
                        if (afModes?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) == true) {
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        } else {
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                            // AF_MODE_AUTO chỉ quét khi có AF_TRIGGER_START.
                            afAutoScanMode = afModes?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true
                        }
                    }
                    set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
                    // Đèn sân 50 Hz + FPS cố định: bật chống nhấp nháy để AE không
                    // dao động sáng/tối theo tần số lưới điện.
                    setFirstSupportedMode(
                        this,
                        CaptureRequest.CONTROL_AE_ANTIBANDING_MODE,
                        characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_ANTIBANDING_MODES),
                        CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO,
                    )
                    // Zoom: ưu tiên CONTROL_ZOOM_RATIO (Android 11+) cho phép
                    // giá trị < 1.0 (ultra-wide). Fallback SCALER_CROP_REGION
                    // cho Android cũ hơn.
                    // Toạ độ vùng đo sáng: với CONTROL_ZOOM_RATIO là active array
                    // sau zoom; với crop zoom kiểu cũ phải nằm trong vùng crop.
                    val activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
                    var meteringBounds: Rect? = activeArray?.let { Rect(0, 0, it.width(), it.height()) }
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
                            applyLegacyCropZoom(this, characteristics)?.let { meteringBounds = it }
                        }
                    } else {
                        applyLegacyCropZoom(this, characteristics)?.let { meteringBounds = it }
                    }
                    val maxAeRegions = characteristics.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0
                    val bounds = meteringBounds
                    // Chưa chạm: giữ đo sáng mặc định của HAL (toàn khung hình, ổn định nhất).
                    val point = activeMeteringPoint
                    if (point != null && maxAeRegions > 0 && bounds != null &&
                        bounds.width() > 0 && bounds.height() > 0
                    ) {
                        val mirror = characteristics.get(CameraCharacteristics.LENS_FACING) ==
                            CameraCharacteristics.LENS_FACING_FRONT
                        val region = meteringRectFor(point.first, point.second, activeRotationDegrees, mirror, bounds)
                        set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(region))
                        // Chạm vào hình: lấy nét luôn tại điểm đó (khi AF đang tự động).
                        val maxAfRegions = characteristics.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0
                        if (maxAfRegions > 0 && get(CaptureRequest.CONTROL_AF_MODE) !=
                            CaptureRequest.CONTROL_AF_MODE_OFF
                        ) {
                            set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(region))
                        }
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
                    // Trạm đặt cố định trên chân máy: chống rung điện tử (EIS) chỉ cắt
                    // bớt khung hình và làm giảm độ nét/gây trôi hình nhẹ. Tắt EIS;
                    // chống rung quang học (OIS) của ống kính không bị ảnh hưởng.
                    setFirstSupportedMode(
                        this,
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                        characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES),
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
                    )
                }
                if (afRestartPending) {
                    // Xoá dấu "đã quét" NGAY trên camera thread trước khi request mới
                    // chạy: kết quả của request cũ (đang xử lý trên thread này giữa
                    // releaseAutoLock() và ++requestGeneration ở main thread) có thể
                    // đã đặt lại afScanSeen/focusedSinceMs → tin nhầm PASSIVE_FOCUSED.
                    afScanSeen = false
                    focusedSinceMs = 0L
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
                                observeConvergence(trackId, generation, result)
                            }
                        }
                    },
                    cameraThread,
                )
                lastCaptureHeartbeatMs = SystemClock.elapsedRealtime()
                lastAppliedKey = appliedKey
                if (afRestartPending) {
                    // Xoá cờ ở MỌI chế độ AF sau khi xử lý: trước đây cờ chỉ được
                    // xoá ở CONTINUOUS_VIDEO, nên ở các chế độ khác mỗi lần apply
                    // lại xoá afScanSeen (khoá tiêu cự không bao giờ tin được "nét").
                    afRestartPending = false
                    val afMode = request.get(CaptureRequest.CONTROL_AF_MODE)
                    if (activeHasAutoFocus &&
                        afMode == CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                    ) {
                        // Ép AF liên tục quét lại từ đầu: ở CONTINUOUS_VIDEO, START khoá
                        // tức thì (không di chuyển ống kính), CANCEL sau đó nhả khoá và
                        // "Restart AF scan" theo bảng trạng thái Camera2. Không dùng thì
                        // vài máy giữ ống kính đứng yên tới khi khung hình đổi (zoom).
                        try {
                            request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
                            captureSession.capture(request.build(), null, cameraThread)
                            request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_CANCEL)
                            captureSession.capture(request.build(), null, cameraThread)
                        } catch (error: Throwable) {
                            Log.w(TAG, "Cannot restart autofocus scan", error)
                        }
                    } else if (activeHasAutoFocus && afAutoScanMode &&
                        afMode == CaptureRequest.CONTROL_AF_MODE_AUTO
                    ) {
                        // Máy không có CONTINUOUS_VIDEO: AF_MODE_AUTO đứng yên nếu
                        // không có trigger → không bao giờ lấy nét. CANCEL (về
                        // INACTIVE) rồi START một lần để quét; ống kính giữ vị trí
                        // nét (FOCUSED_LOCKED) cho tới lần nhả khoá kế tiếp.
                        try {
                            request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_CANCEL)
                            captureSession.capture(request.build(), null, cameraThread)
                            request.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
                            captureSession.capture(request.build(), null, cameraThread)
                        } catch (error: Throwable) {
                            Log.w(TAG, "Cannot trigger autofocus scan", error)
                        }
                    }
                }
                callback(result(true, compensation, compensation * compensationStep))
            } catch (error: Throwable) {
                lastAppliedKey = null
                Log.w(TAG, "Cannot apply Camera2 exposure boost", error)
                callback(result(false, reason = error.javaClass.simpleName))
            }
        }
        if (!posted) {
            // Looper của camera đã dừng (camera đóng/đổi phiên): khối trên sẽ
            // không bao giờ chạy, nên trả lỗi ngay để Future phía Dart không treo.
            lastAppliedKey = null
            Log.w(TAG, "Camera thread is not running; exposure request dropped")
            callback(result(false, reason = "camera_thread_unavailable"))
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
        if (parameters.isAutoExposureLockSupported) {
            parameters.autoExposureLock = activeCameraLock
        }
        if (parameters.isAutoWhiteBalanceLockSupported) {
            parameters.autoWhiteBalanceLock = activeCameraLock
        }
        val supportedFocus = parameters.supportedFocusModes ?: emptyList()
        if (activeCameraLock) {
            if (supportedFocus.contains(Camera.Parameters.FOCUS_MODE_FIXED)) {
                parameters.focusMode = Camera.Parameters.FOCUS_MODE_FIXED
            } else if (supportedFocus.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                parameters.focusMode = Camera.Parameters.FOCUS_MODE_AUTO
            }
        } else {
            if (supportedFocus.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
                parameters.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
            }
        }
        val point = activeMeteringPoint
        if (point != null && parameters.maxNumMeteringAreas > 0) {
            try {
                val area = meteringRectFor(
                    point.first,
                    point.second,
                    activeRotationDegrees,
                    false,
                    Rect(0, 0, 2000, 2000),
                )
                parameters.meteringAreas = listOf(
                    Camera.Area(
                        Rect(area.x - 1000, area.y - 1000, area.x + area.width - 1000, area.y + area.height - 1000),
                        1000,
                    ),
                )
            } catch (_: Throwable) {}
        }
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

    /** Legacy zoom bằng SCALER_CROP_REGION – chỉ hỗ trợ zoom >= 1.0. Trả về vùng crop đã đặt. */
    private fun applyLegacyCropZoom(
        request: CaptureRequest.Builder,
        characteristics: CameraCharacteristics,
    ): Rect? {
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
            val crop = Rect(left, top, left + width, top + height)
            request.set(CaptureRequest.SCALER_CROP_REGION, crop)
            activeZoom = zoom
            return crop
        }
        return null
    }

    /**
     * Chuyển điểm chạm trên preview (0..1, khung đã xoay [rotationDegrees] theo
     * chiều kim đồng hồ so với sensor) thành vùng đo sáng ~30% khung hình trong
     * [bounds]. Vùng lớn (thay vì spot 10% của flutter_webrtc) giúp AE không giật
     * khi người chơi/đèn đi ngang điểm đo.
     */
    internal fun meteringRectFor(
        x: Double,
        y: Double,
        rotationDegrees: Int,
        mirror: Boolean,
        bounds: Rect,
    ): MeteringRectangle {
        var px = x.coerceIn(0.0, 1.0)
        val py = y.coerceIn(0.0, 1.0)
        if (mirror) px = 1.0 - px
        val (sx, sy) = when (((rotationDegrees % 360) + 360) % 360) {
            90 -> Pair(py, 1.0 - px)
            180 -> Pair(1.0 - px, 1.0 - py)
            270 -> Pair(1.0 - py, px)
            else -> Pair(px, py)
        }
        val width = (bounds.width() * METERING_REGION_FRACTION).roundToInt().coerceIn(1, bounds.width())
        val height = (bounds.height() * METERING_REGION_FRACTION).roundToInt().coerceIn(1, bounds.height())
        val centerX = bounds.left + (sx * bounds.width()).roundToInt()
        val centerY = bounds.top + (sy * bounds.height()).roundToInt()
        val left = (centerX - width / 2).coerceIn(bounds.left, bounds.right - width)
        val top = (centerY - height / 2).coerceIn(bounds.top, bounds.bottom - height)
        return MeteringRectangle(left, top, width, height, MeteringRectangle.METERING_WEIGHT_MAX)
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

/**
 * Đo độ sáng trung bình khung hình 2 lần/giây trên ảnh thu nhỏ 32x18 (rất nhẹ),
 * xử lý ngoài thread camera của WebRTC.
 */
private class LumaMeter(private val onLuma: (String, Double) -> Unit) : VideoSink {
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    @Volatile private var lastSampleMs = 0L
    @Volatile private var track: VideoTrack? = null
    @Volatile private var trackId: String? = null
    @Volatile var current: Double? = null
        private set

    fun attach(id: String) {
        detach()
        val videoTrack = try {
            FlutterWebRTCPlugin.sharedSingleton?.getTrackForId(id, null) as? VideoTrack
        } catch (_: Throwable) { null } ?: return
        try {
            videoTrack.addSink(this)
            track = videoTrack
            trackId = id
        } catch (error: Throwable) {
            Log.w("CameraExposure", "Cannot attach brightness meter", error)
        }
    }

    fun isAttachedTo(id: String): Boolean = trackId == id && track != null

    fun detach() {
        val previous = track
        track = null
        trackId = null
        current = null
        if (previous != null) {
            try { previous.removeSink(this) } catch (_: Throwable) {}
        }
    }

    override fun onFrame(frame: VideoFrame) {
        val id = trackId ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - lastSampleMs < 500L || !busy.compareAndSet(false, true)) return
        lastSampleMs = now
        frame.retain()
        try {
            executor.execute {
                try {
                    sample(id, frame)
                } catch (_: Throwable) {
                } finally {
                    frame.release()
                    busy.set(false)
                }
            }
        } catch (_: Throwable) {
            frame.release()
            busy.set(false)
        }
    }

    private fun sample(id: String, frame: VideoFrame) {
        val buffer = frame.buffer
        if (buffer.width <= 0 || buffer.height <= 0) return
        val scaled = buffer.cropAndScale(0, 0, buffer.width, buffer.height, 32, 18)
        try {
            val i420 = scaled.toI420() ?: return
            try {
                val plane = i420.dataY
                val stride = i420.strideY
                var sum = 0L
                for (row in 0 until i420.height) {
                    val base = row * stride
                    for (col in 0 until i420.width) {
                        sum += plane.get(base + col).toInt() and 0xFF
                    }
                }
                val average = sum.toDouble() / (i420.width * i420.height)
                val previous = current
                val smoothed = if (previous == null) average else previous * 0.6 + average * 0.4
                if (trackId != id) return
                current = smoothed
                onLuma(id, smoothed)
            } finally {
                i420.release()
            }
        } finally {
            scaled.release()
        }
    }
}
