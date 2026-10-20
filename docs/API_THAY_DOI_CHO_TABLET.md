# Thay đổi API Camera Station — dành cho đội app Tablet

Cập nhật: 20/10/2026. Bổ sung cho `VNVAR_Camera_Station_API_Specification.docx` (v2.1).
Mọi endpoint, đường dẫn và trường cũ **vẫn giữ nguyên**; dưới đây chỉ là phần thêm hoặc mã lỗi rõ hơn.
API vẫn **không có xác thực** (theo quyết định dự án).

## 1. CheckVAR (`POST /checkvar` và các alias)

**Thành công:** giữ nguyên. Thêm trường:

| Trường | Kiểu | Ý nghĩa |
| --- | --- | --- |
| `joinedPrecedingSegment` | bool | Clip có ghép thêm đoạn từ segment liền trước (khi bấm sát ranh giới segment). Chỉ ghép khi hai segment cùng codec, kích thước, góc xoay. |

**Lỗi:** trước đây trả `500` chung. Nay trả JSON có mã lỗi ổn định, và lỗi cũng được lưu để
`GET /checkvar/jobs/{requestId}` trả lại đúng nội dung:

```json
{ "success": false, "requestId": "...", "status": "FAILED",
  "errorCode": "NO_SEGMENT", "retryable": false, "httpStatus": 409,
  "message": "...", "requestedAt": "...", "timestamp": 1792470000000 }
```

| `errorCode` | HTTP | `retryable` | Khi nào |
| --- | --- | --- | --- |
| `NOT_RECORDING` | 409 | true | Trạm chưa ghi / đang mở lại máy ghi |
| `NO_SEGMENT` | 409 | false | Không còn segment phù hợp để cắt |
| `TRIM_FAILED` | 422 | false | Khoảng cắt không hợp lệ |
| `TRIM_FAILED` | 409 | true | Đang có lệnh cắt khác chạy |
| `TRIM_FAILED` | 500 | true | FFmpeg cắt lỗi |
| `INTERNAL` | 500 | true | Lỗi khác |

Tablet nên: `retryable == true` → gửi lại **cùng** `X-Request-ID` sau 1–2 giây; `false` → báo người dùng.

**Rate limit:** CheckVAR có hạn mức riêng **60 lần/phút/IP** (trước dùng chung 30/phút với các lệnh khác).
ACK `POST /segments/{id}/downloaded` có hạn mức riêng **600 lần/phút/IP**.

## 2. Clip xuất theo phiên tablet

- Clip CheckVAR/trim được gắn với phiên của tablet tạo ra nó: header **`X-Peer-ID`** nếu có, nếu không thì IP.
  → Tablet nên gửi `X-Peer-ID` cố định cho mọi request.
- `POST /download/session/close` chỉ xoá clip **của phiên gọi**, không còn xoá clip của tablet khác.
- Clip chưa đóng phiên tự hết hạn **30 phút kể từ lần đọc cuối** (không phải từ lúc tạo).

## 3. Trạng thái ghi hình

`GET /status`, `POST /start`, `POST /recording/auto-start` có thêm:

| Trường | Kiểu | Ý nghĩa |
| --- | --- | --- |
| `recordingSuspended` | bool | Trạm vẫn ở chế độ ghi nhưng máy ghi tạm treo (vd thiếu dung lượng), tự thử lại |
| `recordingSuspendedReason` | string? | Lý do (chỉ ở `/status`) |

**Thay đổi ngữ nghĩa:** `POST /start` giờ trả `recording` và `status` (`RECORDING`/`READY`) **theo trạng thái thật**
sau khi bật ghi (riêng khi camera đang đổi cấu hình/khôi phục: `status: "STARTING"`, `deferred: true`,
`recording: false` như trước). Nếu có lệnh `/stop` chen vào hoặc máy ghi không mở được, phản hồi có thể là
`success: true` nhưng `recording: false`. Tablet nên kiểm `recording`, không chỉ `success`.

## 4. Mã lỗi HTTP mới

| Mã | Endpoint | Ý nghĩa |
| --- | --- | --- |
| 400 | `/webrtc/offer`, `/webrtc/ice`, `/webrtc/disconnect` | JSON sai định dạng hoặc sai kiểu (trước trả 500) |
| 409 / 422 | CheckVAR | Xem mục 1 |
| 503 + `Retry-After` | Các lệnh cần video track | Camera đang mở lại; body `{"error":"Service Unavailable","retryable":true}`; thử lại sau vài giây (trước trả 500) |

## 5. Bảng tỉ số (`/api/score`)

- JSON trạng thái có `"v": 2`, thêm `setRallies` và `sets[].synthetic` (set do tablet đặt bằng `setScore`, hiển thị "–").
  Client cũ bỏ qua trường lạ thì không ảnh hưởng.
- `reopen` khi trận đã có đội thắng đủ set → **409** `match_decided` (dùng Hoàn tác thay thế).
- Số không hữu hạn (Infinity/NaN) trong lệnh → **422** `invalid_number`.
- `tiebreakAt` phải trong `[gamesPerSet - 1, gamesPerSet]`, sai → 422.
- `setScore` đủ số set thắng → trận tự kết thúc.
- `newMatch` / `config` có `reset: true` xoá lịch sử Hoàn tác.
