package vn.vnvar.cameraStation

import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Quy tắc "tăng sáng khi thiếu sáng" (thuần Kotlin, không phụ thuộc Android để
 * kiểm thử được bằng JUnit). CameraExposureController giữ trạng thái và gửi
 * request; lớp này chỉ tính toán.
 *
 * Bối cảnh: app khoá cứng 30 FPS nên AE chỉ phơi tối đa ~30 ms. Trong phòng/sân
 * tối, kéo EV lên không sáng thêm vì máy (vài HAL MediaTek) không tự tăng ISO.
 * Khi đó app tự điều khiển cảm biến: phơi 30 ms (đúng 3 chu kỳ 10 ms của đèn
 * 50 Hz nên không nhấp nháy) và tăng ISO theo vòng lặp độ sáng, giữ 30 FPS.
 * Máy không cho chỉnh tay cảm biến thì nới dải FPS của AE (vd 24–30) để AE
 * được phơi lâu hơn.
 */
internal object LowLightBoostPolicy {
    /** Thời gian phơi khi chỉnh tay: 3 × 10 ms (đèn 50 Hz nhấp nháy 100 lần/giây). */
    const val MANUAL_EXPOSURE_NS = 30_000_000L

    /** Trần ISO để hạn chế nhiễu hạt. */
    const val ISO_CAP = 800

    /** ISO khởi đầu khi máy không báo (hoặc báo quá thấp) ISO AE đang dùng. */
    const val START_ISO = 200

    /** Độ sáng trung bình mong muốn (0..255) ở EV 0 và trần độ sáng mong muốn. */
    const val BASE_TARGET_LUMA = 110.0
    const val MAX_TARGET_LUMA = 200.0

    /**
     * AE coi là "hết đường" khi phơi ≥ tỉ lệ này của thời lượng khung. Máy có
     * chống nhấp nháy 50 Hz giới hạn ở 30 ms / 33,3 ms = 0,9, nên dùng 0,85.
     */
    const val SATURATED_EXPOSURE_RATIO = 0.85

    /** Hình tối hơn mục tiêu quá tỉ lệ này mới bật tăng sáng. */
    const val ENTER_DARK_RATIO = 0.9

    /** Đang chỉnh tay, ISO đã thấp nhất mà hình sáng hơn mục tiêu tỉ lệ này → trả về AE. */
    const val EXIT_BRIGHT_RATIO = 1.3

    /** Đang nới FPS mà AE phơi dưới tỉ lệ này của khung 30 FPS → cảnh đã sáng. */
    const val FPS_RELAX_EXIT_EXPOSURE_RATIO = 0.75

    /** Điều kiện vào/ra phải đúng liên tục chừng này. */
    const val ENTER_AFTER_MS = 2_000L
    const val EXIT_AFTER_MS = 2_000L

    /** Giữ chế độ tăng sáng ít nhất chừng này (không bật/tắt liên tục). */
    const val MIN_DWELL_MS = 5_000L

    /** Mỗi bước chỉnh ISO cách nhau ít nhất chừng này (bộ đo sáng làm mượt ~1 s). */
    const val ISO_STEP_INTERVAL_MS = 1_000L

    /** Mỗi bước ISO đổi tối đa ±25% để hình không nhảy sáng/tối. */
    const val ISO_STEP_MIN = 0.8
    const val ISO_STEP_MAX = 1.25

    /** Lệch mục tiêu dưới tỉ lệ này thì giữ ISO (tránh dao động). */
    const val ISO_DEADBAND = 0.08

    /**
     * Đã ở trần ISO chừng này mà độ sáng không tăng ít nhất [EFFECTIVE_GAIN] so
     * với lúc bật → máy bỏ qua ISO chỉnh tay (HAL báo hỗ trợ nhưng không làm).
     */
    const val INEFFECTIVE_AFTER_MS = 3_000L
    const val EFFECTIVE_GAIN = 1.15

    /** FPS thấp nhất chấp nhận khi nới dải FPS (dưới mức này chuyển động bị giật). */
    const val MIN_RELAXED_FPS = 24

    /** Độ sáng mong muốn theo EV: mỗi +1 EV sáng hơn ~1,4 lần (√2), tối đa 200. */
    fun targetLuma(ev: Double): Double =
        (BASE_TARGET_LUMA * 2.0.pow(ev / 2.0)).coerceIn(1.0, MAX_TARGET_LUMA)

    /** AE đã phơi hết mức cho phép của khung hình. Thiếu số liệu thì coi như chưa. */
    fun isExposureSaturated(exposureNs: Long?, frameDurationNs: Long?): Boolean {
        if (exposureNs == null || frameDurationNs == null) return false
        if (exposureNs <= 0L || frameDurationNs <= 0L) return false
        return exposureNs >= frameDurationNs * SATURATED_EXPOSURE_RATIO
    }

    /** Điều kiện (tức thời) để bắt đầu đếm giờ bật tăng sáng. */
    fun wantsBoost(ev: Double, saturated: Boolean, luma: Double): Boolean =
        ev > 0.0 && saturated && luma < targetLuma(ev) * ENTER_DARK_RATIO

    /** Trần ISO của máy này: nhỏ hơn giữa [ISO_CAP] và ISO tối đa, không dưới ISO tối thiểu. */
    fun isoCap(isoMin: Int, isoMax: Int): Int =
        minOf(ISO_CAP, isoMax).coerceAtLeast(isoMin)

    /**
     * ISO khởi đầu: ISO AE đang dùng (nếu máy báo hợp lý) nhưng không dưới
     * [START_ISO], vì lúc này AE đã hết đường nên ISO thật thường đã cao hơn.
     */
    fun startIso(reportedIso: Int?, isoMin: Int, cap: Int): Int {
        val base = maxOf(reportedIso ?: 0, START_ISO)
        return base.coerceIn(isoMin, cap)
    }

    /** ISO bước kế tiếp để độ sáng tiến về [target]. */
    fun nextIso(currentIso: Int, luma: Double, target: Double, isoMin: Int, cap: Int): Int {
        if (luma <= 0.0 || target <= 0.0) return currentIso.coerceIn(isoMin, cap)
        val error = (target - luma) / target
        if (kotlin.math.abs(error) < ISO_DEADBAND) return currentIso.coerceIn(isoMin, cap)
        val ratio = (target / luma).coerceIn(ISO_STEP_MIN, ISO_STEP_MAX)
        return (currentIso * ratio).roundToInt().coerceIn(isoMin, cap)
    }

    /** Đang chỉnh tay: ISO đã thấp nhất mà vẫn quá sáng → cảnh đã sáng, trả về AE. */
    fun manualSceneBright(iso: Int, isoMin: Int, luma: Double, target: Double): Boolean =
        iso <= isoMin && luma > target * EXIT_BRIGHT_RATIO

    /** Đang nới FPS: AE đã phơi ngắn hơn hẳn khung 30 FPS → cảnh đã sáng. */
    fun relaxedSceneBright(exposureNs: Long?, fixedFrameDurationNs: Long): Boolean {
        if (exposureNs == null || exposureNs <= 0L || fixedFrameDurationNs <= 0L) return false
        return exposureNs < fixedFrameDurationNs * FPS_RELAX_EXIT_EXPOSURE_RATIO
    }

    /** Đã ở trần ISO mà độ sáng gần như không tăng so với lúc bật → máy bỏ qua ISO. */
    fun manualIneffective(entryLuma: Double, luma: Double): Boolean =
        entryLuma > 0.0 && luma < entryLuma * EFFECTIVE_GAIN

    /**
     * Chọn dải FPS AE nới ra trong [ranges] (cặp lower/upper thô, có máy báo
     * theo đơn vị 1/1000 FPS): cùng FPS tối đa [maxFps], FPS thấp nhất trong
     * khoảng [MIN_RELAXED_FPS]..maxFps-1, chọn lower nhỏ nhất (phơi lâu nhất).
     * null = máy không có dải phù hợp.
     */
    fun chooseRelaxedFpsRange(ranges: List<Pair<Int, Int>>, maxFps: Int): Pair<Int, Int>? {
        fun norm(value: Int) = if (value >= 1000) value / 1000 else value
        return ranges
            .filter { (lower, upper) ->
                norm(upper) == maxFps && norm(lower) in MIN_RELAXED_FPS until maxFps
            }
            .minByOrNull { norm(it.first) }
    }
}
