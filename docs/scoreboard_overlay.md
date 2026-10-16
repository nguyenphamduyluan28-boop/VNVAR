# Bảng tỉ số & Overlay nội bộ (Scoreboard)

Chạy hoàn toàn trong mạng Wi-Fi nội bộ, do `CameraServer` (cổng API, mặc định 8080) phục vụ. Không cần Internet, không dùng CDN.

## Cách dùng

1. Trên app Camera Station bấm nút **Bảng tỉ số** (biểu tượng scoreboard) ở thanh trên cùng. Hub chỉ hiện mã QR, link và mã điều khiển; mọi thao tác tỉ số và overlay làm trên trang web.
2. Trọng tài quét mã QR → mở `http://<IP>:<PORT>/control` trên trình duyệt điện thoại. Mã điều khiển được nhớ trong trình duyệt.
3. Máy OBS: Sources → + → **Browser** → URL `http://<IP>:<PORT>/overlay`, Width 1920, Height 1080. Nền trong suốt.
4. Mọi thay đổi trên trang điều khiển hiện lên overlay ngay (Server-Sent Events).

Trang điều khiển có 4 tab, mỗi tab chia nhóm nhỏ (trang nhớ nhóm đang mở): **Tỉ số**; **Trận đấu** (Thông tin trận · Hai đội · Môn & luật); **Overlay** (Trực tiếp: hiện/ẩn, cảnh, thông báo, đồng hồ · Giao diện: vị trí, kích thước, màu, thông tin hiển thị · Chữ chạy · Livestream); **Hệ thống** (link, mã). Nút "Overlay: Hiện/Ẩn" luôn ở thanh trên cùng. Màn ngang: xem trước overlay cố định bên trái, thẻ chia cột.

Tham số tùy chọn của `/overlay` (ghi đè cấu hình trên server cho riêng một nguồn OBS): `scene`, `theme` (dark|light|glass), `pos` (tl|tc|tr|bl|bc|br), `scale` (0.5–2), `dot=0` (ẩn chấm báo mất kết nối).

## In bảng tỉ số thẳng vào livestream (không cần OBS)

Khi phát RTMP/RTSP từ điện thoại **Android**, app tự chồng bảng tỉ số lên video gửi đi (YouTube, Facebook, máy chủ RTMP…). Bật/tắt bằng ô **"In bảng tỉ số vào video livestream"** (tab Overlay của trang điều khiển); mặc định bật. Video ghi trên máy và luồng xem trên Tablet không bị ảnh hưởng.

- Cách hoạt động: app vẽ bảng tỉ số thành ảnh PNG trong suốt đúng kích thước video và vẽ lại khi điểm/thông tin đổi; FFmpeg đọc lại ảnh vài lần mỗi giây, chồng lên hình rồi mã hoá lại bằng bộ mã hoá phần cứng (`h264_mediacodec`). Bảng tỉ số trên livestream trễ khoảng 0,5–1 giây so với lúc bấm.
- Hỗ trợ các cảnh: thanh tỉ số, bảng lớn, giới thiệu, kết quả, ẩn, thông báo, chữ chạy.
- Chữ chạy: FFmpeg vẽ chữ (`drawtext`, font hệ thống Android) và cho chạy mượt theo từng khung hình; đổi nội dung có hiệu lực ngay. Tốc độ mới áp dụng từ lần phát/kết nối lại sau. Thanh chữ chạy trên livestream luôn nền tối, chữ trắng. Máy không có font/bộ lọc phù hợp thì app tự dùng chữ đứng yên.
- **Hiện/ẩn overlay** (nút "Overlay: Hiện/Ẩn" trên thanh trên cùng của trang điều khiển, hoặc tab Overlay): ẩn/hiện ngay cả trên OBS lẫn livestream, không khởi động lại luồng; cảnh và cấu hình được giữ nguyên.
- **Kích thước** (50–200 %) và **vị trí** thanh tỉ số chỉnh trong tab Overlay; lề và thanh chữ chạy giữ cố định.
- Tốn CPU/pin hơn phát thường (phải giải mã và mã hoá lại hình); FFmpeg giải mã đa luồng để theo kịp thời gian thực. Máy nóng thì app vẫn tự hạ độ phân giải như trước (luồng khởi động lại vài giây).
- Bitrate cố định theo phiên, không tự khởi động lại phiên khi mạng/máy chậm; mức bitrate đã hạ được dùng ở lần kết nối lại sau.
- Máy không mã hoá lại được: app tự phát tiếp **không** có bảng tỉ số và báo trên màn Livestream.
- Bật/tắt khi đang phát sẽ khởi động lại luồng vài giây.
- Chưa hỗ trợ: iPhone (FFmpeg đi kèm không có bộ mã hoá H.264) và phát WHIP. Dùng OBS với link `/overlay` cho các trường hợp này.

## API

| Method | Đường dẫn | Mã khóa | Mô tả |
|---|---|---|---|
| GET | `/control` | — | Trang điều khiển |
| GET | `/overlay` | — | Overlay cho OBS |
| GET | `/api/score` | — | Trạng thái hiện tại (JSON) |
| GET | `/api/score/events` | — | SSE: `event: state` khi đổi, `event: ping` mỗi 15 giây |
| POST | `/api/score` | Có | Gửi lệnh, trả `{ok, state}` |
| POST | `/api/score/logo?team=A` | Có | Body là ảnh PNG/JPG/WebP ≤ 512 KB |
| GET | `/api/score/logo/<id>` | — | Ảnh logo |

Mã khóa gửi bằng header `X-Score-Key: <mã>` hoặc query `?k=<mã>`. Mã nằm trong link QR; đổi mã trong Hub của app.

Lỗi: `401` sai mã, `409` xung đột (trận đã kết thúc, đổi luật khi đang có điểm), `422` dữ liệu sai, `429` gửi quá nhanh. Body lỗi: `{ok:false, error, message}`.

### Lệnh (`POST /api/score`)

Mỗi lệnh nên có `id` duy nhất; gửi lại cùng `id` (khi mạng chập chờn) không bị áp hai lần.

| `action` | Trường | Ghi chú |
|---|---|---|
| `point` | `team` A/B | Đội thắng pha bóng (áp luật môn: side-out, rally, tennis) |
| `adjust` | `team`, `delta` (−5..5) | Sửa tay; cộng vẫn kiểm tra hết set |
| `undo` | — | Hoàn tác thay đổi điểm gần nhất (tối đa 100 bước) |
| `setServe` | `team` A/B/none, `serverNumber` 1/2 | |
| `swapServe`, `swapSides` | — | |
| `endSet`, `finish`, `reopen`, `newMatch` | `newMatch.resetTeams` tùy chọn | |
| `config` | `sport`, `rules`, `reset`, `preset` | `sport`: pickleball, badminton, tennis, custom |
| `setTeam` | `team`, `name`, `short`, `color` (#RRGGBB), `players` [] | |
| `setMatchInfo` | `tournament`, `round`, `court` | |
| `overlay` | `visible`, `burnIn`, `scene`, `theme`, `accent`, `position`, `scale`, `show{sets,serve,tournament,timer}`, `ticker{enabled,text,speed}` | |
| `banner` | `text`, `seconds` (0 = đến khi tắt) | `text` rỗng để tắt |
| `timer` | `op`: start/pause/reset | |
| `removeLogo` | `team` | |
| `setScore` | `scoreA`, `scoreB`, `setsA`, `setsB`, `gamesA`, `gamesB`, `serving`, `matchFinished`, `teamA`, `teamB` | Ghi đè trực tiếp, không áp luật (tích hợp tablet) |

Body không có `action` nhưng có các trường phẳng (`scoreA`, `teamA`…) được hiểu là `setScore` (tương thích đặc tả ban đầu).

Ví dụ tablet CheckVAR:

```
POST /api/score
X-Score-Key: AB12CD
{"id":"tab-0001","action":"point","team":"A"}
```

### Trạng thái trả về (rút gọn)

`rev` tăng mỗi lần đổi; `epoch` đổi khi app khởi động lại. Các trường chính: `sport`, `rules`, `teamA/teamB {name, short, color, players, logoId}`, `match`, `points {a,b}`, `games {a,b}` (tennis), `sets [{a,b,tbA?,tbB?}]`, `setsWon`, `currentSet`, `serving`, `serverNumber`, `tiebreak`, `status` (playing|finished), `winner`, `overlay`, `timer`, `display {a, b, callout, kind}` (chuỗi hiển thị sẵn, ví dụ "AD"/"40", "5-3-2"), và các trường phẳng `teamAName`, `teamBName`, `scoreA`, `scoreB`, `setsA`, `setsB`, `matchFinished`.

## Lưu ý vận hành

- Điện thoại trọng tài và máy OBS phải cùng mạng Wi-Fi với điện thoại camera. IP điện thoại đổi thì cập nhật lại link trong OBS.
- iPhone: giữ app Camera Station mở; khi app xuống nền server tạm dừng, overlay giữ tỉ số cuối và tự cập nhật lại khi app mở.
- Trạng thái bảng tỉ số được lưu trong máy, khởi động lại app không mất điểm.
