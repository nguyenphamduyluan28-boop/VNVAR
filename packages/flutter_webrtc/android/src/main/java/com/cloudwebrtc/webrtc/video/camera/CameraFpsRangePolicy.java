package com.cloudwebrtc.webrtc.video.camera;

/**
 * VNVAR patch: chọn dải FPS cho chế độ tự phơi sáng (CONTROL_AE_TARGET_FPS_RANGE)
 * để camera giữ đủ FPS đã chọn.
 *
 * WebRTC thường chọn dải có cận dưới thấp (ví dụ 10–30). Chỗ thiếu sáng, camera
 * kéo dài thời gian phơi sáng nên FPS tụt (đã gặp 12,5 FPS ở 30 FPS), làm video
 * ghi, clip Check VAR và hình gửi tablet đều giật. Với video thể thao, chuyển
 * động mượt quan trọng hơn độ sáng: ưu tiên dải cố định (30–30), không có thì
 * dải cùng cận trên có cận dưới cao nhất. Đánh đổi: thiếu sáng thì hình tối và
 * nhiễu hơn.
 *
 * Lớp thuần Java (không phụ thuộc Android) để kiểm thử được.
 */
public final class CameraFpsRangePolicy {
  private CameraFpsRangePolicy() {}

  /**
   * @param available các dải máy hỗ trợ, mỗi phần tử {cận dưới, cận trên}
   *     (cùng đơn vị với [min], [max]; có máy dùng FPS x1000).
   * @param min cận dưới WebRTC đã chọn.
   * @param max cận trên WebRTC đã chọn (FPS mong muốn).
   * @return {cận dưới, cận trên} nên dùng; không có dải tốt hơn thì trả lại
   *     đúng {min, max}.
   */
  public static int[] choose(int[][] available, int min, int max) {
    int[] best = null;
    if (available != null) {
      for (int[] range : available) {
        if (range == null || range.length < 2) continue;
        // Chỉ nhận dải cùng cận trên (không đổi FPS mong muốn) và không hạ
        // cận dưới so với dải WebRTC đã chọn.
        if (range[1] != max || range[0] < min || range[0] > range[1]) continue;
        if (best == null || range[0] > best[0]) best = range;
      }
    }
    return best == null ? new int[] {min, max} : new int[] {best[0], best[1]};
  }
}
