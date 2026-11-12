package vn.vnvar.cameraStation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LowLightBoostPolicyTest {
    private val p = LowLightBoostPolicy

    @Test
    fun targetLumaGrowsWithEvAndIsCapped() {
        assertEquals(110.0, p.targetLuma(0.0), 0.01)
        assertEquals(155.56, p.targetLuma(1.0), 0.01)
        assertEquals(200.0, p.targetLuma(2.0), 0.01) // 220 bị chặn ở 200
        assertTrue(p.targetLuma(-2.0) < 110.0)
    }

    @Test
    fun saturationMatchesFiftyHertzLimitedExposure() {
        // Log thật: exposureMs=29.996 frameMs=33.35 → đã hết đường.
        assertTrue(p.isExposureSaturated(29_996_000L, 33_350_000L))
        assertFalse(p.isExposureSaturated(20_000_000L, 33_350_000L))
        assertFalse(p.isExposureSaturated(null, 33_350_000L))
        assertFalse(p.isExposureSaturated(30_000_000L, null))
    }

    @Test
    fun boostOnlyWhenEvPositiveSaturatedAndDark() {
        assertTrue(p.wantsBoost(2.0, saturated = true, luma = 60.0))
        assertFalse(p.wantsBoost(0.0, saturated = true, luma = 60.0))
        assertFalse(p.wantsBoost(2.0, saturated = false, luma = 60.0))
        assertFalse(p.wantsBoost(2.0, saturated = true, luma = 190.0))
    }

    @Test
    fun isoCapRespectsDeviceRange() {
        assertEquals(800, p.isoCap(100, 3200))
        assertEquals(400, p.isoCap(100, 400))
        assertEquals(100, p.isoCap(100, 50))
    }

    @Test
    fun startIsoUsesReportedButNotBelowDefault() {
        assertEquals(200, p.startIso(115, 100, 800)) // MTK báo 115 cố định
        assertEquals(400, p.startIso(400, 100, 800))
        assertEquals(800, p.startIso(1600, 100, 800))
        assertEquals(200, p.startIso(null, 100, 800))
    }

    @Test
    fun nextIsoStepsTowardTargetWithLimits() {
        // Quá tối: tăng tối đa 25% mỗi bước.
        assertEquals(250, p.nextIso(200, 50.0, 200.0, 100, 800))
        // Quá sáng: giảm tối đa 20% mỗi bước.
        assertEquals(320, p.nextIso(400, 250.0, 100.0, 100, 800))
        // Trong vùng chết: giữ nguyên.
        assertEquals(300, p.nextIso(300, 105.0, 110.0, 100, 800))
        // Không vượt trần / sàn.
        assertEquals(800, p.nextIso(760, 20.0, 200.0, 100, 800))
        assertEquals(100, p.nextIso(110, 250.0, 100.0, 100, 800))
        // Số đo hỏng: giữ nguyên.
        assertEquals(300, p.nextIso(300, 0.0, 110.0, 100, 800))
    }

    @Test
    fun nextIsoConvergesInLinearScene() {
        // Mô hình đơn giản: độ sáng tỉ lệ với ISO (cảnh cố định).
        val lumaPerIso = 0.25
        var iso = 200
        repeat(20) { iso = p.nextIso(iso, iso * lumaPerIso, 150.0, 100, 800) }
        val luma = iso * lumaPerIso
        assertTrue("luma=$luma", kotlin.math.abs(luma - 150.0) / 150.0 < 0.1)
    }

    @Test
    fun exitConditions() {
        assertTrue(p.manualSceneBright(100, 100, 200.0, 110.0))
        assertFalse(p.manualSceneBright(150, 100, 200.0, 110.0))
        assertFalse(p.manualSceneBright(100, 100, 120.0, 110.0))
        assertTrue(p.relaxedSceneBright(15_000_000L, 33_333_333L))
        assertFalse(p.relaxedSceneBright(30_000_000L, 33_333_333L))
        assertFalse(p.relaxedSceneBright(null, 33_333_333L))
    }

    @Test
    fun ineffectiveWhenLumaDidNotRise() {
        assertTrue(p.manualIneffective(60.0, 62.0))
        assertFalse(p.manualIneffective(60.0, 80.0))
        assertFalse(p.manualIneffective(0.0, 10.0))
    }

    @Test
    fun relaxedFpsRangeSelection() {
        val ranges = listOf(15 to 15, 15 to 30, 24 to 30, 30 to 30)
        assertEquals(24 to 30, p.chooseRelaxedFpsRange(ranges, 30))
        // Chỉ có 15–30: quá thấp, không dùng.
        assertNull(p.chooseRelaxedFpsRange(listOf(15 to 30, 30 to 30), 30))
        // Đơn vị 1/1000 FPS.
        assertEquals(25000 to 30000, p.chooseRelaxedFpsRange(listOf(25000 to 30000, 30000 to 30000), 30))
        // Nhiều lựa chọn: lấy lower thấp nhất (phơi lâu nhất).
        assertEquals(24 to 30, p.chooseRelaxedFpsRange(listOf(27 to 30, 24 to 30), 30))
    }
}
