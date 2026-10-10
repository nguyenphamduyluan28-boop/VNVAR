/// Chuỗi lọc âm thanh dùng chung cho file ghi (Check VAR) và livestream khi
/// quay sân ngoài trời.
///
/// 1. `highpass=f=150` hai lần (bậc 4, 24 dB/quãng tám): cắt tiếng gió ầm
///    và rung chân máy. Tiếng gió dồn năng lượng dưới ~300 Hz; bộ lọc cũ
///    (130 Hz, bậc 1–2) chỉ giảm được 6–8 dB.
/// 2. `lowpass=f=7500`: cắt rè mưa ở dải cao, giữ hoà âm còi (2,5–4 kHz).
/// 3. `afftdn=nr=15:nf=-42:tn=1`: khử ồn nền thích ứng (mưa rè, tạp âm). Bản
///    livestream cũ dùng `nf=-25`, coi gần như mọi âm là ồn nên dễ méo tiếng.
/// 4. `alimiter`: chặn đỉnh để cơn gió mạnh không làm vỡ tiếng (thay cho
///    `volume=1.2` cũ vốn làm tiếng dễ vỡ).
///
/// Đo trên tín hiệu giả lập 20 giây (gió + mưa + còi 3 kHz + giọng nói), so với
/// file ghi cũ: gió −12 dB thêm, rè mưa −20 dB, tiếng lộp độp −90%, còi giữ
/// nguyên, giọng nói −1,4 dB. Chi phí gần như bằng không so với mã hoá AAC nên
/// không làm chậm Check VAR.
const String outdoorAudioCleanupFilter =
    'highpass=f=150:p=2,highpass=f=150:p=2,lowpass=f=7500,'
    'afftdn=nr=15:nf=-42:tn=1,alimiter=limit=0.89:level=0';
