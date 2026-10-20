# VNVAR Camera Station (SportO-Cam)

Ứng dụng Flutter biến điện thoại thành trạm camera cho sân thể thao: ghi hình theo segment, cắt clip
CheckVAR cho tablet trọng tài, phát RTSP nội bộ, livestream RTMP/WHIP, và bảng tỉ số in lên livestream.

## Thành phần chính

| Thư mục | Nội dung |
| --- | --- |
| `lib/services/camera_station_runtime.dart` | Điều phối vòng đời camera, ghi hình, nhiệt, mạng |
| `lib/services/recording_service.dart` | Ghi segment, chuyển TS, cắt clip, dọn dung lượng |
| `lib/services/camera_server.dart` | HTTP API cổng 8080 + discovery 40404 |
| `lib/services/webrtc_service.dart` | Camera dùng chung, WebRTC cho tablet, RTSP 8554 |
| `lib/services/rtsp_publisher_service.dart`, `whip_publisher_service.dart` | Livestream RTMP/RTSP (FFmpeg) và WHIP |
| `lib/services/scoreboard_*.dart`, `lib/models/scoreboard_state.dart` | Bảng tỉ số, luật điểm, burn-in |
| `lib/screens/` | Màn hình trạm, cài đặt, livestream, kho video |
| `android/app/src/main/kotlin/...` | Native Android: RTSP server, encoder, âm thanh, foreground service |
| `ios/Runner/` | Native iOS: RTSP server, VideoToolbox encoder, âm thanh |

## Build

```
flutter pub get
flutter analyze
flutter test
flutter build apk --release          # cần android/key.properties hoặc biến VNVAR_KEYSTORE_*
cd ios && pod install && cd ..
flutter build ios --release
```

Ký Android: Gradle đọc biến môi trường `VNVAR_KEYSTORE_PATH`, `VNVAR_KEYSTORE_PASSWORD`, `VNVAR_KEY_ALIAS`,
`VNVAR_KEY_PASSWORD`, nếu không có thì đọc `android/key.properties` (không commit file này).
Bản thử nghiệm ký debug key: đặt `VNVAR_ALLOW_DEBUG_SIGNING=true`.

## Tài liệu

- `DAC_TA_KY_THUAT_NANG_CAP_VNVAR.md` — đặc tả nâng cấp 2.1.0
- `VNVAR_Camera_Station_API_Specification.docx` — đặc tả API
- `docs/API_THAY_DOI_CHO_TABLET.md` — thay đổi API gần đây cho app tablet
- `docs/SUA_LOI_2026-10-20.md` — nhật ký sửa lỗi
- `docs/scoreboard_overlay.md`, `docs/ios_validation_checklist.md`
