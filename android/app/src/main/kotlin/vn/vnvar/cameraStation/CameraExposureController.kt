package vn.vnvar.cameraStation

import android.content.Context
import android.hardware.Camera
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
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
import com.cloudwebrtc.webrtc.video.camera.CameraUtils
import org.webrtc.Camera1Capturer
import org.webrtc.Camera2Capturer
import org.webrtc.CameraEnumerationAndroid
import org.webrtc.CameraVideoCapturer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
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
     * Lấy nét theo chuẩn camera: để AF liên tục của chính camera
     * (CONTROL_AF_MODE_CONTINUOUS_VIDEO, như app Camera khi quay video) tự lo.
     * App KHÔNG tự khoá ống kính ở một cự ly (AF_MODE_OFF + LENS_FOCUS_DISTANCE),
     * không tự quét tiêu cự, không lấy nét một lần. Lý do: khoá cự ly từng khoá
     * nhầm ở 11,48 dpt (~9 cm) khi lúc mở camera có vật sát ống kính, cả khung
     * mờ suốt buổi mà cơ chế canh độ nét không phát hiện ra.
     * Đặt false để bật lại cơ chế khoá cự ly cũ (chống săn nét).
     */
    private const val USE_NATIVE_CONTINUOUS_AF = true
    /**
     * AF bắt đầu quét lại chừng này lần mà chưa lần nào giữ nét đủ
     * [FOCUS_LOCK_AFTER_MS] = đang "săn nét" (màn hình/đèn LED, cảnh phẳng):
     * mỗi vòng ống kính chạy qua lại làm hình nét/mờ và co giãn ~2% (focus
     * breathing). Khi đó khoá luôn ở tiêu cự gần nhất AF báo nét.
     */
    private const val AF_HUNT_SCANS = 3
    /**
     * Máy chỉnh tay được tiêu cự mà AF chưa giữ nét ổn định sau chừng này (săn
     * nét, hoặc HAL báo sai trạng thái: vài máy MediaTek luôn báo PASSIVE_FOCUSED
     * + ống kính đứng yên dù đang săn) thì app TỰ tìm nét: quét một lượt các tiêu
     * cự, đo độ nét của khung hình, khoá ở chỗ nét nhất.
     */
    private const val FOCUS_SWEEP_AFTER_MS = 5_000L
    /** Số bước quét thô (đều theo diopter, từ vô cực tới tiêu cự gần nhất). */
    private const val FOCUS_SWEEP_COARSE_STEPS = 12
    /**
     * Tiêu cự gần nhất khi tự tìm nét (diopter; 2 dpt = 0,5 m). Camera sân
     * không cần nét gần hơn. Trước đây quét tới sát ống kính (vd 18 dpt ≈ 5 cm)
     * nên lúc dựng máy chĩa vào vật ở gần (mặt bàn, tay) là khoá nhầm ở 5 cm,
     * quay ra sân thì mờ hẳn. Thu hẹp dải còn giúp 12 bước dày hơn ở vùng xa.
     */
    private const val FOCUS_SWEEP_MAX_DIOPTER = 2.0f
    /**
     * Chờ ống kính tới tiêu cự mới trước khi đo độ nét. Vài máy MediaTek xử lý
     * lấy nét chậm ("AF execute too long") nên 250 ms đôi khi chưa đủ.
     */
    private const val FOCUS_SWEEP_SETTLE_MS = 400L
    /**
     * Ống kính phải báo đứng yên (LENS_STATE) liên tục chừng này mới đo: máy
     * MediaTek dịch ống kính chậm, còn báo MOVING sau 400 ms; đo lúc ống kính
     * đang chạy cho số đo nhảy loạn (972 → 37 → 1063 ở hai bước sát nhau).
     */
    private const val FOCUS_SWEEP_LENS_STILL_MS = 200L
    /** Chờ ống kính đứng yên tối đa chừng này (HAL không báo thì vẫn đo). */
    private const val FOCUS_SWEEP_MAX_SETTLE_MS = 1_500L
    /**
     * Ống kính điện thoại có độ sâu trường ảnh rộng (~1 diopter) nên vùng nét là
     * một "cao nguyên" nhiều bước. Khoá ở GIỮA vùng có độ nét ≥ tỉ lệ này so với
     * đỉnh, thay vì ở một số đo lẻ (dễ là số đo lệch, nằm sát mép vùng nét).
     */
    private const val FOCUS_SWEEP_PLATEAU_RATIO = 0.85
    /**
     * Lấy nét MỘT LẦN bằng AF của chính camera (AF_MODE_AUTO + AF_TRIGGER_START,
     * như chạm để lấy nét trong app Camera) rồi giữ nguyên ống kính. Ưu tiên
     * hơn tự quét: vài máy (Samsung A07 MediaTek) báo nhận LENS_FOCUS_DISTANCE
     * nhưng ống kính không hề di chuyển (độ nét đo được phẳng 74–77 ở mọi tiêu
     * cự), nên tự quét không bao giờ lấy được nét. Hết chừng này mà AF chưa
     * báo xong thì mới chuyển sang tự quét.
     */
    private const val ONE_SHOT_FOCUS_TIMEOUT_MS = 4_000L
    /** Lấy nét một lần không xong thì chờ chừng này mới thử lại cách đó. */
    private const val ONE_SHOT_FOCUS_RETRY_MS = 30_000L
    /** Sau khi khoá nét, cứ chừng này đo lại độ nét một lần. */
    private const val FOCUS_WATCH_INTERVAL_MS = 3_000L
    /** Độ nét tụt dưới tỉ lệ này so với lúc khoá... */
    private const val FOCUS_WATCH_DROP_RATIO = 0.5
    /**
     * ...chừng này lần đo liên tiếp (~9 s, không phải người đi ngang) thì tìm
     * nét lại: máy bị xoay/dời sang cảnh khác sau khi đã khoá.
     */
    private const val FOCUS_WATCH_DROPS = 3
    /** Số khung đo độ nét mỗi bước (lấy trung vị: một khung rung/lệch không làm sai). */
    private const val FOCUS_SWEEP_SAMPLES = 3
    /**
     * Điểm nét nhất phải cao hơn trung vị cả lượt quét ít nhất chừng này lần thì
     * mới tin. Cảnh ít chi tiết (tường trơn, vật một màu ở giữa khung) cho đường
     * độ nét gần phẳng: số đo chỉ còn là nhiễu hạt, chọn "đỉnh" là chọn bừa.
     */
    private const val FOCUS_SWEEP_MIN_PEAK_RATIO = 1.2
    /**
     * Không tin được lượt quét thì khoá ở tiêu cự này (diopter ≈ 1/khoảng cách
     * m): gần khoảng siêu tiêu cự của camera điện thoại, nét từ khoảng 1 m tới
     * vô cực, hợp với camera sân.
     */
    private const val FOCUS_FALLBACK_DIOPTER = 0.45f
    /** Quét thất bại (không đo được) thì chờ chừng này mới thử lại. */
    private const val FOCUS_SWEEP_RETRY_MS = 30_000L
    /** Khoảng cách giữa hai dòng log chẩn đoán lấy nét ("AF diag"). */
    private const val AF_DIAG_INTERVAL_MS = 2_000L
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
    /**
     * Tiêu cự gần nhất AF báo "đã nét" (sau khi đã quét, ống kính đứng yên).
     * Khi săn nét hoặc hết giờ, khoá ở đây thay vì ở chỗ ống kính đang đứng
     * (thường là đầu MỜ của vòng quét: khoá ở đó thì hình mờ cho tới lần đo lại).
     */
    @Volatile
    private var lastFocusedDistance: Float? = null
    /** Số lần AF bắt đầu một lượt quét kể từ lần mở phiên / nhả khoá tiêu cự. */
    @Volatile
    private var afScanStarts = 0
    @Volatile
    private var afWasScanning = false
    /** Lần ghi log chẩn đoán lấy nét gần nhất / chế độ AF đã gửi gần nhất. */
    @Volatile
    private var lastAfDiagMs = 0L
    @Volatile
    private var lastLoggedAfRequest: String? = null
    /** Lượt tự tìm nét đang chạy (main thread), null khi không quét. */
    private class FocusSweep(val trackId: String, val minFocus: Float) {
        val candidates = ArrayDeque<Float>()
        val results = mutableListOf<Pair<Float, Double>>()
        var fine = false
    }
    @Volatile
    private var focusSweep: FocusSweep? = null
    /** Tiêu cự đang thử trong lượt quét (request đặt AF_MODE_OFF ở đây). */
    @Volatile
    private var sweepDistance: Float? = null
    @Volatile
    private var focusSweepFailedAtMs = 0L
    /** Độ nét lúc khoá tiêu cự (null = lấy lần đo đầu tiên sau khi khoá). */
    private var lockedSharpness: Double? = null
    private var focusWatchDrops = 0
    /** Lượt lấy nét một lần đang chạy: mốc bắt đầu (0 = không chạy). */
    @Volatile
    private var oneShotFocusStartedAt = 0L
    /** Đã thấy AF rời trạng thái khoá cũ trong lượt lấy nét một lần này. */
    @Volatile
    private var oneShotSawScan = false
    @Volatile
    private var oneShotFocusFailedAtMs = 0L
    /** Tiêu cự đang được AF của camera giữ (AF_MODE_AUTO, không chỉnh tay). */
    @Volatile
    private var focusHeldByAf = false
    /** Ống kính đang mở có CONTROL_AF_MODE_AUTO (lấy nét một lần được). */
    @Volatile
    private var activeAfAutoAvailable = false
    /** Lần gần nhất HAL báo ống kính đang di chuyển (camera thread ghi). */
    @Volatile
    private var lastLensMovingAtMs = 0L
    private val focusWatch: Runnable = Runnable { checkFocusSharpness() }
    /** LENS_INFO_MINIMUM_FOCUS_DISTANCE của ống kính đang mở (diopter). */
    @Volatile
    private var activeMinFocusDistance = 0f
    /** API camera flutter_webrtc đang dùng ("Camera2"/"Camera1"), để log khi đổi. */
    @Volatile
    private var lastCapturerApi: String? = null
    /**
     * Camera1 (flutter_webrtc tự dùng khi máy có camera LEGACY): không có trạng
     * thái AF theo từng khung như Camera2, nên khoá nét bằng một lần autoFocus ở
     * FOCUS_MODE_AUTO (ống kính đứng yên sau đó) thay cho FOCUS_MODE_CONTINUOUS_VIDEO
     * vốn săn nét mãi với cảnh phẳng/màn hình.
     */
    @Volatile
    private var camera1Hash = 0
    @Volatile
    private var camera1OpenedMs = 0L
    @Volatile
    private var camera1FocusLocked = false
    @Volatile
    private var camera1FocusPending = false
    private val camera1FocusTimer = Runnable {
        activeTrackId?.let { apply(it, activeTargetEv) {} }
    }
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
    /**
     * Mức zoom camera THỰC SỰ áp dụng (CaptureResult, Android 11+) và ống vật lý
     * đang chạy của camera logic (Android 10+). Xin 0.6x mà kết quả vẫn 1.0x
     * nghĩa là hệ điều hành không bật ống góc rộng (thường khi đang 60 FPS).
     */
    @Volatile
    private var lastAppliedZoomRatio: Float? = null
    @Volatile
    private var lastActivePhysicalId: String? = null
    @Volatile
    private var activeCameraDeviceId: String? = null

    // ---- Tăng sáng khi thiếu sáng (xem LowLightBoostPolicy) ----
    // App khoá cứng 30 FPS nên AE chỉ phơi tối đa ~30 ms; trong chỗ tối, EV
    // dương không sáng thêm được vì vài máy không tự tăng ISO. Khi AE đã hết
    // đường mà hình còn tối hơn mức EV yêu cầu: tự đặt ISO (phơi 30 ms, giữ
    // 30 FPS); máy không cho chỉnh tay cảm biến thì nới dải FPS của AE (≥ 24).
    private enum class LowLightMode { OFF, MANUAL_ISO, FPS_RELAX }

    /** Khả năng của camera đang mở, dùng cho chế độ tăng sáng. */
    private class LowLightCaps(
        val cameraId: String,
        val manualSensor: Boolean,
        val isoMin: Int,
        val isoMax: Int,
        val exposureMinNs: Long,
        val exposureMaxNs: Long,
        /** Thời lượng một khung ở FPS cố định (vd 33,3 ms ở 30 FPS). */
        val frameDurationNs: Long,
        val maxFps: Int,
        /** Dải FPS AE nới ra (giá trị thô của máy), null = không có. */
        val relaxedRange: Pair<Int, Int>?,
    )

    /** Main thread ghi; camera thread đọc khi dựng request. */
    @Volatile
    private var lowLightMode = LowLightMode.OFF
    @Volatile
    private var lowLightIso = LowLightBoostPolicy.START_ISO
    @Volatile
    private var lowLightCaps: LowLightCaps? = null
    /** Camera đã biết là ISO chỉnh tay không làm hình sáng hơn (chỉ còn nới FPS). */
    @Volatile
    private var manualIsoIneffectiveCameraId: String? = null
    private var lowLightUnavailableLoggedFor: String? = null
    /** Số liệu kết quả chụp gần nhất (camera thread ghi). */
    @Volatile
    private var lastResultExposureNs: Long? = null
    @Volatile
    private var lastResultFrameNs: Long? = null
    @Volatile
    private var lastResultIso: Int? = null
    // Bộ đếm giờ của chế độ tăng sáng (chỉ main thread).
    private var lowLightDarkSinceMs = 0L
    private var lowLightBrightSinceMs = 0L
    private var lowLightEnteredAtMs = 0L
    private var lowLightLastStepMs = 0L
    private var lowLightAtCapSinceMs = 0L
    private var lowLightEntryLuma = 0.0

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

    fun apply(
        trackId: String,
        targetEv: Double,
        requestCallback: (Map<String, Any>) -> Unit,
    ) {
        // Apply thành công (từ bất kỳ nguồn nào) đưa watchdog về nhịp 1,5 s.
        val callback: (Map<String, Any>) -> Unit = { response ->
            if (response["applied"] == true) watchdogFailures = 0
            requestCallback(response)
        }
        if (activeTrackId != trackId) {
            requestGeneration++
            lastCaptureHeartbeatMs = 0L
            releaseAutoLock(reason = "new video track")
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
        if (targetEv <= 0.0 && lowLightMode != LowLightMode.OFF) {
            // Người dùng hạ EV về ≤ 0: không cần tăng sáng nữa, request dựng
            // ngay dưới đây quay lại AE tự động.
            exitLowLight(null, "EV $targetEv", reapply = false)
        }
        startWatchdog()
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton
                ?: return callback(result(false, reason = "plugin_unavailable"))
            if (!reflectionChecked) verifyReflectionContract(plugin, trackId)
            val handler = readField(plugin, "methodCallHandler")
            val getUserMedia = readField(handler, "getUserMediaImpl") as GetUserMediaImpl
            val info = getUserMedia.getCapturerInfo(trackId)
                ?: return callback(result(false, reason = "capturer_unavailable"))

            val capturerApi = when (info.capturer) {
                is Camera2Capturer -> "Camera2"
                is Camera1Capturer -> "Camera1"
                else -> info.capturer?.javaClass?.simpleName ?: "none"
            }
            if (capturerApi != lastCapturerApi) {
                lastCapturerApi = capturerApi
                Log.i(TAG, "Camera API in use: $capturerApi")
            }
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
        activeCameraDeviceId = null
        lastAppliedZoomRatio = null
        lastActivePhysicalId = null
        releaseAutoLock(reason = "camera cleared")
        lumaMeter.detach()
        lowLightCaps = null
        lastResultExposureNs = null
        lastResultFrameNs = null
        lastResultIso = null
        lastCaptureHeartbeatMs = 0L
        requestGeneration++
        watchdogFailures = 0
        lifecycleHandler.removeCallbacks(captureWatchdog)
    }

    /** Bật/tắt tự khoá phơi sáng sau khi hội tụ (mặc định bật). */
    fun setStableExposure(trackId: String, enabled: Boolean, callback: (Map<String, Any>) -> Unit) {
        stableExposureEnabled = enabled
        releaseAutoLock(reason = "stable exposure toggled")
        apply(trackId, activeTargetEv, requestCallback = callback)
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
    private fun releaseAutoLock(keepFocus: Boolean = false, reason: String = "") {
        autoLocked = false
        lockPending = false
        val now = SystemClock.elapsedRealtime()
        if (!keepFocus) {
            lockedFocusDistance?.let { Log.i(TAG, "Focus lock released ($reason); refocusing from $it dpt") }
            if (camera1FocusLocked) Log.i(TAG, "Camera1 focus lock released ($reason); refocusing")
            if (focusSweep != null) Log.i(TAG, "Focus sweep cancelled ($reason)")
            focusSweep = null
            sweepDistance = null
            camera1FocusLocked = false
            camera1FocusPending = false
            lifecycleHandler.removeCallbacks(camera1FocusTimer)
            lifecycleHandler.removeCallbacks(focusWatch)
            oneShotFocusStartedAt = 0L
            focusHeldByAf = false
            lockedSharpness = null
            focusWatchDrops = 0
            lockedFocusDistance = null
            resetFocusSearch()
            afScanSeen = false
            afRestartPending = true
            focusLockPending = false
            focusedSinceMs = 0L
            focusReleasedAtMs = now
            // Người gọi luôn apply() lại ngay sau đó (hoặc đang xoá camera).
            exitLowLight(null, reason.ifEmpty { "released" }, reapply = false)
        }
        aeReleasedAtMs = now
        convergedSinceMs = 0L
        lumaRefAtLock = null
        lumaDriftSinceMs = 0L
        lockedAtMs = 0L
        lockedSessionHash = null
    }

    /**
     * Camera thread: mỗi [AF_DIAG_INTERVAL_MS] ghi một dòng "AF diag" (chế độ AF
     * HAL đang chạy, trạng thái AF/ống kính, tiêu cự, số lượt quét, khoá). Dùng
     * để chẩn đoán săn nét từ logcat: `adb logcat -s CameraExposure`.
     */
    private fun logAfDiagnostics(result: TotalCaptureResult) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastAfDiagMs < AF_DIAG_INTERVAL_MS) return
        lastAfDiagMs = now
        val sinceSession = if (sessionStartedMs > 0L) now - sessionStartedMs else 0L
        val sinceRelease = if (focusReleasedAtMs > 0L) now - focusReleasedAtMs else sinceSession
        Log.i(
            TAG,
            "AF diag: mode=${result.get(CaptureResult.CONTROL_AF_MODE)} " +
                "state=${result.get(CaptureResult.CONTROL_AF_STATE)} " +
                "lens=${result.get(CaptureResult.LENS_STATE)} " +
                "dist=${result.get(CaptureResult.LENS_FOCUS_DISTANCE)} " +
                "locked=$lockedFocusDistance lastFocused=$lastFocusedDistance " +
                "sweep=${if (focusSweep != null) sweepDistance else null} " +
                "oneShot=${oneShotFocusStartedAt != 0L} heldByAf=$focusHeldByAf " +
                "scans=$afScanStarts scanSeen=$afScanSeen " +
                "focusedFor=${if (focusedSinceMs > 0L) now - focusedSinceMs else 0L}ms " +
                "sinceRelease=${min(sinceSession, sinceRelease)}ms " +
                "hasAf=$activeHasAutoFocus manual=$activeManualFocus " +
                "stable=$stableExposureEnabled camLock=$activeCameraLock aeLocked=$autoLocked " +
                // FPS thật và thời gian phơi sáng: FPS tụt khi thiếu sáng thì
                // exposure/frame dài hơn 1000/FPS ms.
                "fpsRange=${result.get(CaptureResult.CONTROL_AE_TARGET_FPS_RANGE)} " +
                "exposureMs=${result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { it / 1_000_000.0 }} " +
                "frameMs=${result.get(CaptureResult.SENSOR_FRAME_DURATION)?.let { it / 1_000_000.0 }} " +
                "iso=${result.get(CaptureResult.SENSOR_SENSITIVITY)} " +
                "measuredFps=${measuredCaptureFps()?.let { "%.1f".format(it) }} " +
                "lowLight=$lowLightMode" +
                (if (lowLightMode == LowLightMode.MANUAL_ISO) "(iso=$lowLightIso)" else ""),
        )
    }

    // ---- Tự tìm nét (contrast AF của app) ----

    /**
     * Main thread: tìm nét. Ưu tiên lấy nét một lần bằng AF của camera; máy
     * không có AF_MODE_AUTO, hoặc lần đó vừa thất bại, thì tự quét.
     */
    private fun startFocusSearch(trackId: String, minFocus: Float, why: String) {
        val now = SystemClock.elapsedRealtime()
        if (activeAfAutoAvailable && now - oneShotFocusFailedAtMs >= ONE_SHOT_FOCUS_RETRY_MS) {
            oneShotSawScan = false
            focusHeldByAf = false
            oneShotFocusStartedAt = now
            afRestartPending = true
            Log.i(TAG, "One-shot autofocus started: $why")
            apply(trackId, activeTargetEv) {}
            return
        }
        startFocusSweep(trackId, minFocus, why)
    }

    /** Camera thread: theo dõi lượt lấy nét một lần tới khi AF khoá hoặc hết giờ. */
    private fun observeOneShotFocus(trackId: String, startedAt: Long, result: TotalCaptureResult) {
        val state = result.get(CaptureResult.CONTROL_AF_STATE)
        val locked = state == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED ||
            state == CaptureResult.CONTROL_AF_STATE_NOT_FOCUSED_LOCKED
        // Bỏ kết quả của request trước trigger (còn trạng thái khoá cũ).
        if (!locked) oneShotSawScan = true
        val elapsed = SystemClock.elapsedRealtime() - startedAt
        val done = locked && (oneShotSawScan || elapsed >= 1_500L)
        if (!done && elapsed < ONE_SHOT_FOCUS_TIMEOUT_MS) return
        val focused = state == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED
        val distance = result.get(CaptureResult.LENS_FOCUS_DISTANCE)
        lifecycleHandler.post { finishOneShotFocus(trackId, startedAt, done, focused, distance) }
    }

    /** Main thread: kết thúc lượt lấy nét một lần (bỏ qua các lần gọi trùng). */
    private fun finishOneShotFocus(
        trackId: String,
        startedAt: Long,
        locked: Boolean,
        focused: Boolean,
        distance: Float?,
    ) {
        if (oneShotFocusStartedAt != startedAt || activeTrackId != trackId) return
        oneShotFocusStartedAt = 0L
        if (!locked) {
            oneShotFocusFailedAtMs = SystemClock.elapsedRealtime()
            Log.w(TAG, "One-shot autofocus did not finish in ${ONE_SHOT_FOCUS_TIMEOUT_MS}ms")
            if (activeManualFocus && activeMinFocusDistance > 0f && lumaMeter.isAttachedTo(trackId)) {
                startFocusSweep(trackId, activeMinFocusDistance, "one-shot autofocus timed out")
            } else {
                apply(trackId, activeTargetEv) {}
            }
            return
        }
        // Giữ ống kính đúng chỗ AF vừa chọn (AF_MODE_AUTO không trigger), kể cả
        // khi AF báo không nét được: đó vẫn là vị trí tốt nhất camera tìm được.
        focusHeldByAf = true
        lockedFocusDistance = distance ?: 0f
        Log.i(
            TAG,
            "One-shot autofocus ${if (focused) "focused" else "could not confirm focus"}; " +
                "holding lens at ${distance ?: "?"} dpt",
        )
        apply(trackId, activeTargetEv) {}
        startFocusWatch(null)
    }

    /**
     * Main thread: bắt đầu quét tiêu cự 0 (vô cực) → min([minFocus],
     * [FOCUS_SWEEP_MAX_DIOPTER]) diopter.
     */
    private fun startFocusSweep(trackId: String, minFocus: Float, why: String) {
        val nearest = min(minFocus, FOCUS_SWEEP_MAX_DIOPTER)
        val sweep = FocusSweep(trackId, nearest)
        val steps = FOCUS_SWEEP_COARSE_STEPS
        for (i in 0 until steps) sweep.candidates.add(nearest * i / (steps - 1))
        focusSweep = sweep
        Log.i(
            TAG,
            "Focus sweep started: $why; 0..$nearest dpt in $steps steps " +
                "(lens closest $minFocus dpt)",
        )
        nextSweepStep(sweep)
    }

    private fun nextSweepStep(sweep: FocusSweep) {
        if (focusSweep !== sweep || activeTrackId != sweep.trackId) return
        // Không còn bước tinh: độ sâu trường ảnh (~1 diopter) rộng hơn nhiều
        // bước thô (0,18 diopter), và nhảy ngược ống kính về giữa dải chỉ làm
        // thêm số đo lúc ống kính đang chạy.
        val next = sweep.candidates.removeFirstOrNull()
        if (next == null) {
            finishFocusSweep(sweep)
            return
        }
        val distance = next
        sweepDistance = distance
        apply(sweep.trackId, activeTargetEv) {}
        val requestedAt = SystemClock.elapsedRealtime()
        lifecycleHandler.postDelayed(
            { measureWhenLensSettled(sweep, distance, requestedAt) },
            FOCUS_SWEEP_SETTLE_MS,
        )
    }

    /** Đợi ống kính báo đứng yên [FOCUS_SWEEP_LENS_STILL_MS] rồi mới đo. */
    private fun measureWhenLensSettled(sweep: FocusSweep, distance: Float, requestedAt: Long) {
        if (focusSweep !== sweep) return
        val now = SystemClock.elapsedRealtime()
        val stillFor = now - lastLensMovingAtMs
        if (stillFor < FOCUS_SWEEP_LENS_STILL_MS &&
            now - requestedAt < FOCUS_SWEEP_MAX_SETTLE_MS
        ) {
            lifecycleHandler.postDelayed(
                { measureWhenLensSettled(sweep, distance, requestedAt) },
                50L,
            )
            return
        }
        measureSweepStep(sweep, distance)
    }

    /**
     * Đo độ nét [FOCUS_SWEEP_SAMPLES] khung ở tiêu cự [distance] (lấy trung vị)
     * rồi sang bước kế.
     */
    private fun measureSweepStep(
        sweep: FocusSweep,
        distance: Float,
        samples: MutableList<Double> = mutableListOf(),
    ) {
        if (focusSweep !== sweep) return
        var done = false
        val record = {
            if (samples.isNotEmpty()) {
                val sorted = samples.sorted()
                sweep.results.add(distance to sorted[sorted.size / 2])
            }
            nextSweepStep(sweep)
        }
        val timeout = Runnable {
            if (done) return@Runnable
            done = true
            record()
        }
        lifecycleHandler.postDelayed(timeout, 1_000L)
        lumaMeter.measureSharpness { value ->
            lifecycleHandler.post {
                if (done || focusSweep !== sweep) return@post
                done = true
                lifecycleHandler.removeCallbacks(timeout)
                if (value != null) samples.add(value)
                if (samples.size < FOCUS_SWEEP_SAMPLES && value != null) {
                    measureSweepStep(sweep, distance, samples)
                } else {
                    record()
                }
            }
        }
    }

    private fun finishFocusSweep(sweep: FocusSweep) {
        if (focusSweep !== sweep) return
        focusSweep = null
        sweepDistance = null
        val best = sweep.results.maxByOrNull { it.second }
        if (best == null || sweep.results.size < 3) {
            focusSweepFailedAtMs = SystemClock.elapsedRealtime()
            Log.w(TAG, "Focus sweep failed (${sweep.results.size} readings); back to continuous AF")
            apply(sweep.trackId, activeTargetEv) {}
            return
        }
        val sorted = sweep.results.sortedBy { it.first }
        val readings = sorted
            .joinToString(" ") { "%.2f=%d".format(it.first, it.second.roundToInt()) }
        // Lọc trung vị 3 điểm liền kề: một số đo lẻ vọt lên/tụt xuống (đo lệch)
        // không thể tạo đỉnh giả; vùng nét thật rộng nhiều bước nên vẫn giữ.
        val values = sorted.map { it.second }
        val filtered = values.indices.map { i ->
            val window = listOfNotNull(values.getOrNull(i - 1), values[i], values.getOrNull(i + 1))
                .sorted()
            if (window.size == 3) window[1] else window.first()
        }
        val peakIndex = filtered.indices.maxByOrNull { filtered[it] }!!
        val peak = filtered[peakIndex]
        val median = filtered.sorted()[filtered.size / 2]
        if (peak < median * FOCUS_SWEEP_MIN_PEAK_RATIO) {
            // Đường độ nét gần phẳng (cảnh ít chi tiết): không chọn bừa, khoá ở
            // tiêu cự an toàn cho camera sân và không theo dõi độ nét (không có
            // mốc tin được để so).
            val fallback = min(FOCUS_FALLBACK_DIOPTER, sweep.minFocus)
            lockedFocusDistance = fallback
            Log.i(
                TAG,
                "Focus sweep inconclusive (peak ${peak.roundToInt()} vs median " +
                    "${median.roundToInt()}); locking at fallback $fallback dpt: $readings",
            )
            apply(sweep.trackId, activeTargetEv) {}
            return
        }
        // Giữa vùng nét quanh đỉnh: nét đều cho cả vật gần lẫn xa trong vùng.
        var low = peakIndex
        while (low > 0 && filtered[low - 1] >= peak * FOCUS_SWEEP_PLATEAU_RATIO) low--
        var high = peakIndex
        while (high < filtered.lastIndex && filtered[high + 1] >= peak * FOCUS_SWEEP_PLATEAU_RATIO) high++
        val chosen = (sorted[low].first + sorted[high].first) / 2f
        lockedFocusDistance = chosen
        Log.i(
            TAG,
            "Focus sweep: locking at $chosen dpt (in-focus band ${sorted[low].first}.." +
                "${sorted[high].first} dpt, filtered peak ${peak.roundToInt()}, " +
                "median ${median.roundToInt()}, ${sweep.results.size} readings): $readings",
        )
        apply(sweep.trackId, activeTargetEv) {}
        // Mốc so độ nét đo lại ở chính tiêu cự đã khoá (không lấy số đo lúc quét).
        startFocusWatch(null)
    }

    /** Main thread: theo dõi độ nét sau khi khoá tiêu cự ([baseline] null = đo lần đầu). */
    private fun startFocusWatch(baseline: Double?) {
        lockedSharpness = baseline
        focusWatchDrops = 0
        lifecycleHandler.removeCallbacks(focusWatch)
        lifecycleHandler.postDelayed(focusWatch, FOCUS_WATCH_INTERVAL_MS)
    }

    /**
     * Main thread: độ nét tụt mạnh và kéo dài so với lúc khoá (máy bị xoay
     * sang cảnh khác, hoặc lúc khoá ống kính đang chĩa vào vật ở gần) thì nhả
     * khoá để tự tìm nét lại.
     */
    private fun checkFocusSharpness() {
        val trackId = activeTrackId ?: return
        if (lockedFocusDistance == null || focusSweep != null || activeCameraLock ||
            !lumaMeter.isAttachedTo(trackId)
        ) return
        // Hẹn lần sau trước: camera không ra khung (callback không về) vẫn đo tiếp.
        lifecycleHandler.postDelayed(focusWatch, FOCUS_WATCH_INTERVAL_MS)
        lumaMeter.measureSharpness { value ->
            lifecycleHandler.post {
                if (value == null || activeTrackId != trackId ||
                    lockedFocusDistance == null || focusSweep != null
                ) return@post
                val baseline = lockedSharpness
                if (baseline == null || baseline <= 0.0) {
                    lockedSharpness = value
                    focusWatchDrops = 0
                    return@post
                }
                if (value >= baseline * FOCUS_WATCH_DROP_RATIO) {
                    focusWatchDrops = 0
                    return@post
                }
                focusWatchDrops++
                if (focusWatchDrops < FOCUS_WATCH_DROPS) return@post
                Log.i(
                    TAG,
                    "Sharpness dropped (${value.roundToInt()} < ${baseline.roundToInt()} " +
                        "at lock) for ${FOCUS_WATCH_DROPS} checks; refocusing",
                )
                releaseAutoLock(reason = "sharpness dropped")
                apply(trackId, activeTargetEv) {}
            }
        }
    }

    /** Bắt đầu lại việc theo dõi một lượt tìm nét mới (phiên mới / nhả khoá). */
    private fun resetFocusSearch() {
        lastFocusedDistance = null
        afScanStarts = 0
        afWasScanning = false
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
        logAfDiagnostics(result)
        if (result.get(CaptureResult.LENS_STATE) == CaptureResult.LENS_STATE_MOVING) {
            lastLensMovingAtMs = SystemClock.elapsedRealtime()
        }
        if (!stableExposureEnabled || activeCameraLock) return
        val oneShotStartedAt = oneShotFocusStartedAt
        if (oneShotStartedAt != 0L) {
            observeOneShotFocus(trackId, oneShotStartedAt, result)
            return
        }
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
        if (afScanning && !afWasScanning) afScanStarts++
        afWasScanning = afScanning
        val afFocusTrusted = afFocused && afScanSeen
        val sinceSessionMs = if (sessionStartedMs > 0L) now - sessionStartedMs else 0L
        val sinceFocusReleaseMs =
            if (focusReleasedAtMs > 0L) now - focusReleasedAtMs else sinceSessionMs
        val afTimedOut = min(sinceSessionMs, sinceFocusReleaseMs) >= AF_FOCUS_TIMEOUT_MS

        // ---- 1. Khoá tiêu cự ----
        // Lấy nét theo chuẩn camera (USE_NATIVE_CONTINUOUS_AF): bỏ qua toàn bộ
        // bước khoá cự ly; request giữ CONTINUOUS_VIDEO vì lockedFocusDistance,
        // sweepDistance luôn null và không có lượt lấy nét một lần nào.
        if (!USE_NATIVE_CONTINUOUS_AF &&
            lockedFocusDistance == null && focusSweep == null && oneShotFocusStartedAt == 0L &&
            activeHasAutoFocus && !focusLockPending && sinceSessionMs >= MIN_LOCK_AFTER_SESSION_MS
        ) {
            val lensStill = result.get(CaptureResult.LENS_STATE) !=
                CaptureResult.LENS_STATE_MOVING
            // Máy không chỉnh tay được tiêu cự thường không báo LENS_FOCUS_DISTANCE;
            // khi đó khoá bằng AF_MODE_AUTO (không dùng giá trị) nên dùng 0f làm dấu.
            val distance = result.get(CaptureResult.LENS_FOCUS_DISTANCE)
                ?: if (!activeManualFocus) 0f else null
            if (afFocusTrusted && lensStill) {
                if (focusedSinceMs == 0L) focusedSinceMs = now
                if (distance != null) lastFocusedDistance = distance
            } else {
                focusedSinceMs = 0L
            }
            val focusedLongEnough = focusedSinceMs > 0L &&
                now - focusedSinceMs >= FOCUS_LOCK_AFTER_MS
            // Săn nét: AF quét đi quét lại, mỗi lần chỉ nét < FOCUS_LOCK_AFTER_MS.
            // Chỉnh tay được: đặt thẳng tiêu cự nét gần nhất. Không chỉnh tay được
            // (khoá = giữ ống kính tại chỗ): chỉ khoá đúng lúc AF đang báo nét.
            val hunting = afScanStarts >= AF_HUNT_SCANS && !afScanning && lensStill &&
                (if (activeManualFocus) lastFocusedDistance != null else afFocusTrusted)
            val gaveUp = afTimedOut && afScanSeen && !afScanning && lensStill
            // Chỉnh tay được mà AF chưa giữ nét sau FOCUS_SWEEP_AFTER_MS (săn nét,
            // hết giờ, hoặc HAL không bao giờ báo đang quét): tự tìm nét theo độ nét
            // đo trên khung hình, chính xác hơn khoá theo trạng thái AF.
            val searchMs = min(sinceSessionMs, sinceFocusReleaseMs)
            if (activeManualFocus && !focusedLongEnough && activeMinFocusDistance > 0f &&
                searchMs >= FOCUS_SWEEP_AFTER_MS &&
                now - focusSweepFailedAtMs >= FOCUS_SWEEP_RETRY_MS &&
                lumaMeter.isAttachedTo(trackId)
            ) {
                val minFocus = activeMinFocusDistance
                focusLockPending = true
                lifecycleHandler.post {
                    focusLockPending = false
                    if (activeTrackId != trackId || requestGeneration != generation ||
                        activeCameraLock || !stableExposureEnabled ||
                        lockedFocusDistance != null || focusSweep != null ||
                        oneShotFocusStartedAt != 0L
                    ) return@post
                    val why = when {
                        afScanStarts >= AF_HUNT_SCANS -> "AF hunting ($afScanStarts scans)"
                        !afScanSeen -> "AF never reported scanning"
                        else -> "AF not settled"
                    }
                    startFocusSearch(trackId, minFocus, why)
                }
                return
            }
            val lockDistance = when {
                focusedLongEnough -> distance
                // Máy không chỉnh tay được: không tự quét được, khoá theo trạng thái AF.
                !activeManualFocus && (hunting || gaveUp) -> distance
                else -> null
            }
            if (lockDistance != null) {
                val why = when {
                    focusedLongEnough -> "settled"
                    hunting -> "hunting after $afScanStarts scans"
                    else -> "search timed out" +
                        (if (activeManualFocus && lastFocusedDistance == null) ", no in-focus reading" else "")
                }
                focusLockPending = true
                lifecycleHandler.post {
                    focusLockPending = false
                    if (activeTrackId != trackId || requestGeneration != generation ||
                        activeCameraLock || !stableExposureEnabled ||
                        lockedFocusDistance != null
                    ) return@post
                    lockedFocusDistance = lockDistance
                    Log.i(TAG, "Focus $why; locking focus at $lockDistance dpt")
                    apply(trackId, activeTargetEv) {}
                    startFocusWatch(null)
                }
                return
            }
        }

        // ---- 2. Khoá AE/AWB ----
        // Đang tăng sáng: app tự điều khiển phơi sáng (hoặc dải FPS), không khoá AE.
        if (lowLightMode != LowLightMode.OFF) {
            convergedSinceMs = 0L
            return
        }
        if (autoLocked || lockPending) return
        // Không có bộ đo sáng thì không phát hiện được ánh sáng đổi để mở khoá:
        // giữ AE/AWB tự động (khoá tiêu cự ở trên không cần bộ đo sáng).
        if (!lumaMeter.isAttachedTo(trackId)) return
        val ae = result.get(CaptureResult.CONTROL_AE_STATE) ?: return
        val sinceAeReleaseMs =
            if (aeReleasedAtMs > 0L) now - aeReleasedAtMs else sinceSessionMs
        val timedOut = min(sinceSessionMs, sinceAeReleaseMs) >= AE_SETTLE_TIMEOUT_MS
        val aeSettled = ae == CaptureResult.CONTROL_AE_STATE_CONVERGED ||
            ae == CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED ||
            (timedOut && ae != CaptureResult.CONTROL_AE_STATE_PRECAPTURE)
        // Chờ tiêu cự khoá trước (hoặc hết hạn) để lần khoá AE không bị request
        // khoá tiêu cự thay ngay sau đó.
        // AF liên tục chuẩn camera không bao giờ khoá tiêu cự: không chờ.
        val focusReady = focusSweep == null && (
            USE_NATIVE_CONTINUOUS_AF ||
                !activeHasAutoFocus || af == null || lockedFocusDistance != null || afTimedOut
            )
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
        if (activeTrackId == trackId && updateLowLightBoost(trackId, luma)) return
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
    /** Bắt đầu lại cửa sổ đo FPS (vừa đổi ống kính/zoom: bỏ số đo cũ). */
    fun resetCaptureFps() {
        lumaMeter.resetFps()
    }

    /**
     * Trạng thái ống kính thực tế cho Dart kiểm tra sau khi đổi sang 0.5x:
     * FPS đo được, zoom xin / zoom thực áp dụng, camera và ống vật lý đang chạy.
     * Giá trị null = máy không báo / chưa có.
     */
    fun lensStatus(): Map<String, Any?> = mapOf(
        "fps" to measuredCaptureFps(),
        "requestedZoom" to activeZoom,
        "appliedZoom" to lastAppliedZoomRatio?.toDouble(),
        "cameraId" to activeCameraDeviceId,
        "activePhysicalId" to lastActivePhysicalId,
    )

    /**
     * FPS camera thật sự xuất ra (đo trên track, sau giới hạn do nhiệt); null
     * khi chưa đo được hoặc số đo đã cũ (> 10 s).
     */
    fun measuredCaptureFps(): Double? {
        val fps = lumaMeter.measuredFps ?: return null
        val age = SystemClock.elapsedRealtime() - lumaMeter.measuredAtMs
        return if (age <= 10_000L) fps else null
    }

    /**
     * FPS tối đa camera [characteristics] thật sự mở được ở [width]x[height]
     * qua WebRTC: Camera2Session chọn dải trong CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
     * gần nhất với FPS yêu cầu (repeating request cũng đặt đúng dải đó), nên FPS
     * thật = min(khả năng cảm biến ở kích thước này, dải AE cao nhất). Trước đây
     * chỉ xét cảm biến nên nhiều máy hiện "60 FPS" nhưng chạy 30. 0 = không có
     * kích thước này. Trần 60.
     */
    fun maxCaptureFps(characteristics: CameraCharacteristics, width: Int, height: Int): Int {
        val configuration = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return 0
        val size = configuration.getOutputSizes(SurfaceTexture::class.java)
            ?.firstOrNull { it.width == width && it.height == height }
            ?: return 0
        val minFrameDurationNs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            configuration.getOutputMinFrameDuration(SurfaceTexture::class.java, size)
        } else 0L
        val sensorFps = if (minFrameDurationNs > 0L) {
            Math.round(1_000_000_000.0 / minFrameDurationNs).toInt().coerceAtLeast(1)
        } else Int.MAX_VALUE
        val aeRanges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        val aeUpperRaw = aeRanges?.maxOfOrNull { it.upper } ?: 30
        // Vài máy báo dải theo đơn vị 1/1000 FPS (WebRTC: fpsUnitFactor).
        val aeFps = if (aeUpperRaw >= 1000) aeUpperRaw / 1000 else aeUpperRaw
        return min(sensorFps, aeFps).coerceIn(1, 60)
    }

    /** FPS tối đa theo kích thước của [characteristics] ("1920x1080" → 60). */
    private fun maxFpsBySize(characteristics: CameraCharacteristics): Map<String, Int> {
        val result = mutableMapOf<String, Int>()
        for ((width, height) in listOf(1280 to 720, 1920 to 1080)) {
            val fps = try { maxCaptureFps(characteristics, width, height) } catch (_: Throwable) { 0 }
            if (fps > 0) result["${width}x$height"] = fps
        }
        return result
    }

    fun setMeteringPoint(trackId: String, x: Double, y: Double, callback: (Map<String, Any>) -> Unit) {
        activeMeteringPoint = Pair(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0))
        activeCameraLock = false
        releaseAutoLock(reason = "tap to meter")
        apply(trackId, activeTargetEv, requestCallback = callback)
    }

    fun setLock(trackId: String, locked: Boolean, callback: (Map<String, Any>) -> Unit) {
        if (activeCameraLock != locked) releaseAutoLock(reason = "camera lock toggled")
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
        val maxFps: Map<String, Int>,
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

                    parsedList.add(
                        ParsedCamera(
                            id, facing, facingStr, minFocal, fov, minZoom, maxZoom, isUltraWide,
                            maxFpsBySize(chars),
                        ),
                    )
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
                // FPS thật mở được theo kích thước: Dart dùng để biết ống 0.5x
                // có chạy 60 FPS không.
                "maxFps" to it.maxFps,
            )
        }
    }

    fun setZoom(trackId: String, zoom: Double, callback: (Map<String, Any>) -> Unit) {
        val newZoom = zoom.coerceIn(0.3, 5.0)
        // Đổi khung hình: đo sáng/lấy nét lại rồi tự khoá lại.
        if (abs(newZoom - activeZoom) > 0.01) {
            releaseAutoLock(reason = "zoom $activeZoom -> $newZoom")
        }
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
                        releaseAutoLock(reason = "camera switched")
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
            resetFocusSearch()
            focusSweep = null
            sweepDistance = null
            oneShotFocusStartedAt = 0L
            // Phiên chụp mới (đổi ống kính/độ phân giải, camera dựng lại): tiêu
            // cự đã khoá thuộc phiên cũ, có thể của ống kính khác → lấy nét lại.
            // (Trước đây chỉ nhả khi AE cũng đang khoá.)
            if (lockedFocusDistance != null) {
                Log.i(TAG, "Focus lock released (new capture session); refocusing")
                lockedFocusDistance = null
                focusHeldByAf = false
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
            releaseAutoLock(reason = "capture session rebuilt")
        }
        val cameraManager = readField(capturer, "cameraManager") as CameraManager
        val characteristics = cameraManager.getCameraCharacteristics(cameraDevice.id)
        if (activeCameraDeviceId != cameraDevice.id) {
            activeCameraDeviceId = cameraDevice.id
            lastAppliedZoomRatio = null
            lastActivePhysicalId = null
        }
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
        activeAfAutoAvailable = availableAfModes?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true
        activeMinFocusDistance = characteristics.get(
            CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE,
        ) ?: 0f
        val compensationRange = characteristics.get(
            CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE,
        )
        val compensationStep = characteristics.get(
            CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP,
        )?.toDouble() ?: 0.0
        val rawMaxFps = captureFormat.framerate.max / fpsUnitFactor
        updateLowLightCaps(
            cameraDevice.id,
            characteristics,
            if (rawMaxFps >= 1000) rawMaxFps / 1000 else rawMaxFps,
        )
        // Chụp trạng thái một lần: request và appliedKey dùng cùng giá trị.
        val lowLight = lowLightMode
        val lowLightCapsNow = lowLightCaps
        val manualIso = lowLight == LowLightMode.MANUAL_ISO && lowLightCapsNow?.manualSensor == true
        val manualIsoValue = lowLightIso
        val relaxedFps = if (lowLight == LowLightMode.FPS_RELAX) lowLightCapsNow?.relaxedRange else null
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
            sweepDistance,
            oneShotFocusStartedAt != 0L,
            focusHeldByAf,
            activeZoom,
            activeMeteringPoint,
            activeRotationDegrees,
            lowLight,
            if (manualIso) manualIsoValue else 0,
            relaxedFps,
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
                    if (manualIso && lowLightCapsNow != null) {
                        // Tăng sáng khi thiếu sáng: app tự đặt cảm biến. Phơi 30 ms
                        // (3 chu kỳ đèn 50 Hz: không nhấp nháy), khung giữ 30 FPS,
                        // ISO theo vòng lặp độ sáng (updateLowLightBoost).
                        val caps = lowLightCapsNow
                        var exposureNs = min(LowLightBoostPolicy.MANUAL_EXPOSURE_NS, caps.frameDurationNs)
                        if (caps.exposureMaxNs > 0L) exposureNs = min(exposureNs, caps.exposureMaxNs)
                        exposureNs = max(exposureNs, caps.exposureMinNs)
                        set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
                        set(CaptureRequest.SENSOR_EXPOSURE_TIME, exposureNs)
                        set(CaptureRequest.SENSOR_FRAME_DURATION, caps.frameDurationNs)
                        set(
                            CaptureRequest.SENSOR_SENSITIVITY,
                            manualIsoValue.coerceIn(caps.isoMin, max(caps.isoMin, caps.isoMax)),
                        )
                    } else {
                        set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                        if (compensationRange != null && compensationStep > 0.0) {
                            set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, compensation)
                        }
                    }
                    // Giữ đủ FPS đã chọn (ví dụ 30–30) thay vì dải WebRTC chọn
                    // (ví dụ 10–30): thiếu sáng camera không được tự hạ FPS
                    // (đã gặp 12,5 FPS). Đánh đổi: hình tối/nhiễu hơn khi tối.
                    // Thiếu sáng mà máy không chỉnh tay được cảm biến: nới dải FPS
                    // (vd 24–30) để AE phơi lâu hơn; hết tối thì trả về dải cố định.
                    set(
                        CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                        if (relaxedFps != null) {
                            Range(relaxedFps.first, relaxedFps.second)
                        } else {
                            CameraUtils.preferredAeFpsRange(
                                characteristics,
                                captureFormat.framerate.min / fpsUnitFactor,
                                captureFormat.framerate.max / fpsUnitFactor,
                            )
                        },
                    )
                    // Đang tự tìm nét: giữ nguyên phơi sáng để số đo độ nét
                    // giữa các tiêu cự so được với nhau (AE đổi ISO làm nhiễu
                    // hạt đổi theo, số đo nhảy loạn dù tiêu cự không đổi).
                    val locked = !manualIso && (activeCameraLock || autoLocked || focusSweep != null)
                    val aeLockAvailable = characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true
                    if (aeLockAvailable) {
                        set(CaptureRequest.CONTROL_AE_LOCK, locked)
                    }
                    val awbLockAvailable = characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true
                    if (awbLockAvailable) {
                        set(CaptureRequest.CONTROL_AWB_LOCK, locked)
                    }
                    val afModes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
                    // Đang tự tìm nét: đặt thẳng tiêu cự đang thử.
                    val focusDistance = lockedFocusDistance ?: sweepDistance
                    val manualFocus = (characteristics.get(
                        CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE,
                    ) ?: 0f) > 0f && afModes?.contains(CaptureRequest.CONTROL_AF_MODE_OFF) == true
                    // Giữ tiêu cự cả khi đang đo lại độ sáng (lockedFocusDistance
                    // còn giữ sau releaseAutoLock(keepFocus = true)).
                    if (oneShotFocusStartedAt != 0L && !activeCameraLock &&
                        afModes?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true
                    ) {
                        // Lấy nét một lần: AUTO + CANCEL/START (gửi ở afRestartPending
                        // bên dưới), camera tự tìm nét rồi giữ ống kính (LOCKED).
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                        afAutoScanMode = true
                    } else if (focusDistance != null && manualFocus && !activeCameraLock &&
                        !focusHeldByAf
                    ) {
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
                    // Khử nhiễu và làm nét chất lượng cao (máy không hỗ trợ thì giữ mặc định).
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
                    afScanStarts = 0
                    afWasScanning = false
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
                                recordLensState(result)
                                recordExposureResult(result)
                                observeConvergence(trackId, generation, result)
                            }
                        }
                    },
                    cameraThread,
                )
                lastCaptureHeartbeatMs = SystemClock.elapsedRealtime()
                lastAppliedKey = appliedKey
                val afRequest = "mode=${request.get(CaptureRequest.CONTROL_AF_MODE)} " +
                    "focus=${request.get(CaptureRequest.LENS_FOCUS_DISTANCE)}"
                if (afRequest != lastLoggedAfRequest) {
                    lastLoggedAfRequest = afRequest
                    Log.i(TAG, "AF request: $afRequest (lockedFocus=$lockedFocusDistance)")
                }
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
        val now = SystemClock.elapsedRealtime()
        val cameraHash = System.identityHashCode(camera)
        if (cameraHash != camera1Hash) {
            // Camera vừa mở / mở lại (đổi camera, độ phân giải): lấy nét lại.
            camera1Hash = cameraHash
            camera1OpenedMs = now
            camera1FocusLocked = false
            camera1FocusPending = false
        }
        // Lấy nét theo chuẩn camera: không khoá nét, giữ CONTINUOUS_VIDEO.
        val canLockFocus = !USE_NATIVE_CONTINUOUS_AF && stableExposureEnabled &&
            supportedFocus.contains(Camera.Parameters.FOCUS_MODE_AUTO)
        var startAutoFocus = false
        if (activeCameraLock) {
            if (supportedFocus.contains(Camera.Parameters.FOCUS_MODE_FIXED)) {
                parameters.focusMode = Camera.Parameters.FOCUS_MODE_FIXED
            } else if (supportedFocus.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                parameters.focusMode = Camera.Parameters.FOCUS_MODE_AUTO
            }
        } else if (canLockFocus && (camera1FocusLocked || camera1FocusPending)) {
            // Đã (đang) quét một lần: FOCUS_MODE_AUTO giữ ống kính đứng yên.
            parameters.focusMode = Camera.Parameters.FOCUS_MODE_AUTO
        } else if (canLockFocus && now - camera1OpenedMs >= MIN_LOCK_AFTER_SESSION_MS) {
            parameters.focusMode = Camera.Parameters.FOCUS_MODE_AUTO
            startAutoFocus = true
        } else {
            if (supportedFocus.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
                parameters.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
            }
            if (canLockFocus) {
                // Camera1 không có watchdog theo khung: hẹn lần apply để khoá nét.
                lifecycleHandler.removeCallbacks(camera1FocusTimer)
                lifecycleHandler.postDelayed(
                    camera1FocusTimer,
                    (MIN_LOCK_AFTER_SESSION_MS - (now - camera1OpenedMs)).coerceAtLeast(100L),
                )
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
        if (startAutoFocus) startCamera1AutoFocus(session, camera, cameraHash)
        return result(true, compensation, compensation * step)
    }

    /**
     * Camera1: quét nét MỘT lần (FOCUS_MODE_AUTO + autoFocus). Xong thì ống kính
     * đứng yên ở vị trí đó cho tới khi nhả khoá (chạm lấy nét, zoom, đổi camera).
     * Chạy trên thread camera của WebRTC (thread mở Camera) nếu đọc được.
     */
    private fun startCamera1AutoFocus(session: Any, camera: Camera, cameraHash: Int) {
        camera1FocusPending = true
        val handler = try {
            readField(session, "cameraThreadHandler") as? Handler
        } catch (_: Throwable) {
            null
        }
        val run = Runnable {
            try {
                camera.autoFocus { success, _ ->
                    if (camera1Hash != cameraHash || !camera1FocusPending) return@autoFocus
                    camera1FocusPending = false
                    camera1FocusLocked = true
                    Log.i(
                        TAG,
                        "Camera1 focus " + (if (success) "settled" else "search ended without sharp focus") +
                            "; holding lens (FOCUS_MODE_AUTO)",
                    )
                }
            } catch (error: Throwable) {
                camera1FocusPending = false
                Log.w(TAG, "Camera1 autoFocus failed; keeping continuous focus", error)
            }
        }
        if (handler == null || !handler.post(run)) run.run()
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

    /** Camera thread: zoom thực áp dụng + ống vật lý đang chạy (nếu máy báo). */
    /** Camera thread: số liệu phơi sáng thật của khung vừa chụp (cho tăng sáng). */
    private fun recordExposureResult(result: TotalCaptureResult) {
        lastResultExposureNs = result.get(CaptureResult.SENSOR_EXPOSURE_TIME)
        lastResultFrameNs = result.get(CaptureResult.SENSOR_FRAME_DURATION)
        lastResultIso = result.get(CaptureResult.SENSOR_SENSITIVITY)
    }

    /**
     * Main thread (từ applyCamera2): đọc khả năng camera cho chế độ tăng sáng
     * và ghi một dòng log "Camera caps" mỗi khi đổi camera/FPS.
     */
    private fun updateLowLightCaps(cameraId: String, characteristics: CameraCharacteristics, maxFps: Int) {
        val current = lowLightCaps
        if (current != null && current.cameraId == cameraId && current.maxFps == maxFps) return
        val fps = maxFps.coerceAtLeast(1)
        val capabilities = characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
        val manualSensor =
            capabilities?.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR) == true
        val isoRange = characteristics.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val exposureRange = characteristics.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val analogMax = characteristics.get(CameraCharacteristics.SENSOR_MAX_ANALOG_SENSITIVITY)
        val aeRanges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.map { it.lower to it.upper }
            ?: emptyList()
        val caps = LowLightCaps(
            cameraId = cameraId,
            manualSensor = manualSensor && isoRange != null && exposureRange != null,
            isoMin = isoRange?.lower ?: 0,
            isoMax = isoRange?.upper ?: 0,
            exposureMinNs = exposureRange?.lower ?: 0L,
            exposureMaxNs = exposureRange?.upper ?: 0L,
            frameDurationNs = 1_000_000_000L / fps,
            maxFps = fps,
            relaxedRange = LowLightBoostPolicy.chooseRelaxedFpsRange(aeRanges, fps),
        )
        if (current != null && lowLightMode != LowLightMode.OFF) {
            // Đổi camera/FPS giữa chừng: trạng thái tăng sáng thuộc camera cũ.
            exitLowLight(null, "camera changed", reapply = false)
        }
        lowLightCaps = caps
        Log.i(
            TAG,
            "Camera caps ($cameraId): manualSensor=$manualSensor iso=$isoRange analogMax=$analogMax " +
                "exposureMs=[${exposureRange?.lower?.let { "%.3f".format(it / 1e6) }}, " +
                "${exposureRange?.upper?.let { "%.1f".format(it / 1e6) }}] maxFps=$fps " +
                "aeFpsRanges=${aeRanges.joinToString { "[${it.first},${it.second}]" }} " +
                "relaxedFps=${caps.relaxedRange}",
        )
    }

    /**
     * Main thread, mỗi lần bộ đo sáng có số mới (~500 ms): bật/tắt và điều
     * chỉnh chế độ tăng sáng. Trả true khi đang tăng sáng (bỏ logic khoá AE).
     */
    private fun updateLowLightBoost(trackId: String, luma: Double): Boolean {
        val caps = lowLightCaps
        if (caps == null || !activeCamera2 || activeCameraLock || !lumaMeter.isAttachedTo(trackId)) {
            lowLightDarkSinceMs = 0L
            if (lowLightMode != LowLightMode.OFF) exitLowLight(trackId, "unavailable")
            return false
        }
        return when (lowLightMode) {
            LowLightMode.OFF -> {
                maybeEnterLowLight(trackId, caps, luma)
                lowLightMode != LowLightMode.OFF
            }
            LowLightMode.MANUAL_ISO -> updateManualIso(trackId, caps, luma)
            LowLightMode.FPS_RELAX -> updateFpsRelax(trackId, caps)
        }
    }

    private fun maybeEnterLowLight(trackId: String, caps: LowLightCaps, luma: Double) {
        val now = SystemClock.elapsedRealtime()
        val ev = activeTargetEv
        val saturated = LowLightBoostPolicy.isExposureSaturated(
            lastResultExposureNs,
            lastResultFrameNs ?: caps.frameDurationNs,
        )
        if (!LowLightBoostPolicy.wantsBoost(ev, saturated, luma)) {
            lowLightDarkSinceMs = 0L
            return
        }
        if (lowLightDarkSinceMs == 0L) {
            lowLightDarkSinceMs = now
            return
        }
        if (now - lowLightDarkSinceMs < LowLightBoostPolicy.ENTER_AFTER_MS) return
        lowLightDarkSinceMs = 0L
        val target = LowLightBoostPolicy.targetLuma(ev)
        val mode = when {
            caps.manualSensor && manualIsoIneffectiveCameraId != caps.cameraId -> LowLightMode.MANUAL_ISO
            caps.relaxedRange != null -> LowLightMode.FPS_RELAX
            else -> null
        }
        if (mode == null) {
            if (lowLightUnavailableLoggedFor != caps.cameraId) {
                lowLightUnavailableLoggedFor = caps.cameraId
                Log.i(
                    TAG,
                    "Low-light boost unavailable on camera ${caps.cameraId}: no manual sensor " +
                        "control and no AE FPS range >= ${LowLightBoostPolicy.MIN_RELAXED_FPS}",
                )
            }
            return
        }
        // Bỏ khoá AE: từ đây app tự điều khiển phơi sáng / dải FPS.
        releaseAutoLock(keepFocus = true)
        lowLightMode = mode
        lowLightEnteredAtMs = now
        lowLightLastStepMs = now
        lowLightBrightSinceMs = 0L
        lowLightAtCapSinceMs = 0L
        lowLightEntryLuma = luma
        if (mode == LowLightMode.MANUAL_ISO) {
            lowLightIso = LowLightBoostPolicy.startIso(
                lastResultIso,
                caps.isoMin,
                LowLightBoostPolicy.isoCap(caps.isoMin, caps.isoMax),
            )
            Log.i(
                TAG,
                "Low-light ISO boost ON (exp=${LowLightBoostPolicy.MANUAL_EXPOSURE_NS / 1_000_000}ms " +
                    "iso=$lowLightIso luma=${luma.roundToInt()}->${target.roundToInt()} EV=$ev)",
            )
        } else {
            Log.i(
                TAG,
                "Low-light FPS relax ON (AE fps ${caps.relaxedRange}, " +
                    "luma=${luma.roundToInt()}->${target.roundToInt()} EV=$ev)",
            )
        }
        apply(trackId, activeTargetEv) {}
    }

    private fun updateManualIso(trackId: String, caps: LowLightCaps, luma: Double): Boolean {
        val now = SystemClock.elapsedRealtime()
        val ev = activeTargetEv
        if (ev <= 0.0) {
            exitLowLight(trackId, "EV $ev")
            return false
        }
        val target = LowLightBoostPolicy.targetLuma(ev)
        val cap = LowLightBoostPolicy.isoCap(caps.isoMin, caps.isoMax)
        // Máy báo hỗ trợ chỉnh tay nhưng bỏ qua ISO: ở trần đủ lâu mà hình
        // không sáng hơn lúc bật → chuyển hẳn sang nới FPS cho camera này.
        if (lowLightIso >= cap) {
            if (lowLightAtCapSinceMs == 0L) {
                lowLightAtCapSinceMs = now
            } else if (now - lowLightAtCapSinceMs >= LowLightBoostPolicy.INEFFECTIVE_AFTER_MS &&
                LowLightBoostPolicy.manualIneffective(lowLightEntryLuma, luma)
            ) {
                manualIsoIneffectiveCameraId = caps.cameraId
                Log.w(
                    TAG,
                    "Low-light ISO boost gave no gain on camera ${caps.cameraId} " +
                        "(luma ${lowLightEntryLuma.roundToInt()}->${luma.roundToInt()} at iso $lowLightIso); " +
                        "using FPS relax next time",
                )
                exitLowLight(trackId, "no gain")
                return false
            }
        } else {
            lowLightAtCapSinceMs = 0L
        }
        if (LowLightBoostPolicy.manualSceneBright(lowLightIso, caps.isoMin, luma, target)) {
            if (lowLightBrightSinceMs == 0L) lowLightBrightSinceMs = now
            if (now - lowLightBrightSinceMs >= LowLightBoostPolicy.EXIT_AFTER_MS &&
                now - lowLightEnteredAtMs >= LowLightBoostPolicy.MIN_DWELL_MS
            ) {
                exitLowLight(trackId, "scene brighter")
                return false
            }
        } else {
            lowLightBrightSinceMs = 0L
        }
        if (now - lowLightLastStepMs >= LowLightBoostPolicy.ISO_STEP_INTERVAL_MS) {
            lowLightLastStepMs = now
            val next = LowLightBoostPolicy.nextIso(lowLightIso, luma, target, caps.isoMin, cap)
            if (next != lowLightIso) {
                Log.i(
                    TAG,
                    "Low-light ISO boost iso=$lowLightIso->$next " +
                        "(luma ${luma.roundToInt()} target ${target.roundToInt()})",
                )
                lowLightIso = next
                apply(trackId, activeTargetEv) {}
            }
        }
        return true
    }

    private fun updateFpsRelax(trackId: String, caps: LowLightCaps): Boolean {
        val now = SystemClock.elapsedRealtime()
        val ev = activeTargetEv
        if (ev <= 0.0) {
            exitLowLight(trackId, "EV $ev")
            return false
        }
        if (LowLightBoostPolicy.relaxedSceneBright(lastResultExposureNs, caps.frameDurationNs)) {
            if (lowLightBrightSinceMs == 0L) lowLightBrightSinceMs = now
            if (now - lowLightBrightSinceMs >= LowLightBoostPolicy.EXIT_AFTER_MS &&
                now - lowLightEnteredAtMs >= LowLightBoostPolicy.MIN_DWELL_MS
            ) {
                exitLowLight(trackId, "scene brighter")
                return false
            }
        } else {
            lowLightBrightSinceMs = 0L
        }
        return true
    }

    /**
     * Thoát chế độ tăng sáng. [reapply]: tự mở khoá AE và gửi lại request (AE
     * đo lại rồi khoá như thường); false khi người gọi sẽ tự apply() ngay.
     */
    private fun exitLowLight(trackId: String?, reason: String, reapply: Boolean = true) {
        val was = lowLightMode
        lowLightDarkSinceMs = 0L
        if (was == LowLightMode.OFF) return
        lowLightMode = LowLightMode.OFF
        lowLightBrightSinceMs = 0L
        lowLightAtCapSinceMs = 0L
        lowLightEnteredAtMs = 0L
        Log.i(
            TAG,
            (if (was == LowLightMode.MANUAL_ISO) "Low-light ISO boost OFF" else "Low-light FPS relax OFF") +
                " ($reason)",
        )
        if (reapply && trackId != null && activeTrackId == trackId) {
            releaseAutoLock(keepFocus = true)
            apply(trackId, activeTargetEv) {}
        }
    }

    private fun recordLensState(result: TotalCaptureResult) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            result.get(CaptureResult.CONTROL_ZOOM_RATIO)?.let { lastAppliedZoomRatio = it }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            result.get(CaptureResult.LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID)?.let {
                lastActivePhysicalId = it
            }
        }
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
    /** Yêu cầu đo độ nét ở khung kế tiếp (tự tìm nét); null = không có. */
    private val sharpnessRequest = AtomicReference<((Double?) -> Unit)?>(null)

    /**
     * Đo độ nét (năng lượng gradient độ sáng, vùng giữa khung) ở khung hình kế
     * tiếp. [callback] chạy trên luồng nền, nhận null nếu không đo được.
     */
    fun measureSharpness(callback: (Double?) -> Unit) {
        sharpnessRequest.getAndSet(callback)?.invoke(null)
    }
    @Volatile private var lastSampleMs = 0L
    @Volatile private var track: VideoTrack? = null
    @Volatile private var trackId: String? = null
    @Volatile var current: Double? = null
        private set
    // Đếm khung hình thật sự đi ra từ camera (sau giới hạn FPS do nhiệt).
    // onFrame chạy trên một luồng camera nên không cần khoá.
    @Volatile private var fpsWindowStartMs = 0L
    @Volatile private var fpsFrames = 0
    @Volatile var measuredFps: Double? = null
        private set
    @Volatile var measuredAtMs = 0L
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
        sharpnessRequest.getAndSet(null)?.invoke(null)
        val previous = track
        track = null
        trackId = null
        current = null
        fpsWindowStartMs = 0L
        fpsFrames = 0
        measuredFps = null
        measuredAtMs = 0L
        if (previous != null) {
            try { previous.removeSink(this) } catch (_: Throwable) {}
        }
    }

    override fun onFrame(frame: VideoFrame) {
        val id = trackId ?: return
        val now = SystemClock.elapsedRealtime()
        countFrame(now)
        val sharpnessCallback = sharpnessRequest.getAndSet(null)
        if (sharpnessCallback != null) {
            frame.retain()
            try {
                executor.execute {
                    val value = try {
                        sharpness(frame)
                    } catch (_: Throwable) {
                        null
                    } finally {
                        frame.release()
                    }
                    sharpnessCallback(value)
                }
            } catch (_: Throwable) {
                frame.release()
                sharpnessCallback(null)
            }
        }
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

    fun resetFps() {
        fpsWindowStartMs = 0L
        fpsFrames = 0
        measuredFps = null
        measuredAtMs = 0L
    }

    /** FPS đo trên cửa sổ 3 s. */
    private fun countFrame(now: Long) {
        if (fpsWindowStartMs == 0L) {
            fpsWindowStartMs = now
            fpsFrames = 0
            return
        }
        fpsFrames++
        val elapsed = now - fpsWindowStartMs
        if (elapsed >= 3_000L) {
            measuredFps = fpsFrames * 1000.0 / elapsed
            measuredAtMs = now
            fpsWindowStartMs = now
            fpsFrames = 0
        }
    }

    /**
     * Độ nét = trung bình bình phương gradient ngang + dọc của kênh Y, trên vùng
     * giữa 80% × 80% khung thu về 320×180. Vùng rộng để có đủ chi tiết (vùng
     * giữa nhỏ dễ chỉ có tường/vật trơn); thu nhỏ ~5 lần làm mịn nhiễu hạt để
     * số đo phản ánh cạnh thật. Càng nét càng lớn; chỉ dùng để so sánh các
     * tiêu cự của cùng một cảnh.
     */
    private fun sharpness(frame: VideoFrame): Double? {
        val buffer = frame.buffer
        val w: Int = buffer.width
        val h: Int = buffer.height
        if (w < 64 || h < 64) return null
        val cropW = (w * 4 / 5) and 1.inv()
        val cropH = (h * 4 / 5) and 1.inv()
        val outW = minOf(320, cropW)
        val outH = minOf(180, cropH)
        val scaled = buffer.cropAndScale(
            ((w - cropW) / 2) and 1.inv(),
            ((h - cropH) / 2) and 1.inv(),
            cropW,
            cropH,
            outW,
            outH,
        )
        try {
            val i420 = scaled.toI420() ?: return null
            try {
                val plane = i420.dataY
                val stride = i420.strideY
                var sum = 0.0
                var n = 0
                for (row in 0 until i420.height - 1) {
                    val base = row * stride
                    for (col in 0 until i420.width - 1) {
                        val p = plane.get(base + col).toInt() and 0xFF
                        val dx = (plane.get(base + col + 1).toInt() and 0xFF) - p
                        val dy = (plane.get(base + stride + col).toInt() and 0xFF) - p
                        sum += (dx * dx + dy * dy).toDouble()
                        n++
                    }
                }
                return if (n > 0) sum / n else null
            } finally {
                i420.release()
            }
        } finally {
            scaled.release()
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
