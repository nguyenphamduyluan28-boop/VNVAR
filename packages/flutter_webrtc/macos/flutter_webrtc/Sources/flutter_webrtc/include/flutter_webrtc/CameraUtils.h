#import <Foundation/Foundation.h>
#import "FlutterWebRTCPlugin.h"

@interface FlutterWebRTCPlugin (CameraUtils)

- (void)mediaStreamTrackHasTorch:(nonnull RTCMediaStreamTrack*)track result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSetTorch:(nonnull RTCMediaStreamTrack*)track
                           torch:(BOOL)torch
                          result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSetZoom:(nonnull RTCMediaStreamTrack*)track
                           zoomLevel:(double)zoomLevel
                          result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSetFocusMode:(nonnull RTCMediaStreamTrack*)track
                           focusMode:(nonnull NSString*)focusMode
                          result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSetFocusPoint:(nonnull RTCMediaStreamTrack*)track
                           focusPoint:(nonnull NSDictionary*)focusPoint
                          result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSetExposureMode:(nonnull RTCMediaStreamTrack*)track
                           exposureMode:(nonnull NSString*)exposureMode
                          result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSetExposurePoint:(nonnull RTCMediaStreamTrack*)track
                           exposurePoint:(nonnull NSDictionary*)exposurePoint
                            result:(nonnull FlutterResult)result;

- (void)mediaStreamTrackSwitchCamera:(nonnull RTCMediaStreamTrack*)track result:(nonnull FlutterResult)result;

/// VNVAR: FPS hợp lệ cho [format]: [targetFps] (<= 0 thì mặc định 30) nếu khung
/// 1/targetFps giây nằm trong một khoảng FPS định dạng hỗ trợ; nếu không thì FPS
/// nguyên hợp lệ gần nhất. Trả 0 khi [format] nil hoặc không có FPS hợp lệ nào
/// (người gọi phải báo lỗi, không được mở camera với FPS 0).
- (NSInteger)selectFpsForFormat:(nullable AVCaptureDeviceFormat*)format targetFps:(NSInteger)targetFps;

/// VNVAR: YES nếu khung 1/[fps] giây nằm trong một khoảng FPS mà [format] hỗ trợ
/// (so bằng CMTime giống cách iOS kiểm tra).
- (BOOL)isFps:(NSInteger)fps supportedByFormat:(nullable AVCaptureDeviceFormat*)format;

/// VNVAR: khoá FPS cố định (min = max frame duration = 1/[fps] giây) để camera
/// không tự giảm FPS khi thiếu sáng. Chỉ gọi SAU KHI capturer đã chạy định dạng
/// mới (trong completionHandler của startCaptureWithDevice). Bỏ qua và trả NO,
/// không ném lỗi, khi: camera chưa chạy đúng [expectedFormat] (nil = không kiểm
/// tra), [fps] ngoài khoảng của định dạng đang chạy, hoặc không khoá được cấu
/// hình. Tăng FPS thì đặt activeVideoMinFrameDuration trước, giảm FPS thì đặt
/// activeVideoMaxFrameDuration trước để luôn giữ min <= max.
- (BOOL)lockFrameRate:(NSInteger)fps
            forDevice:(nullable AVCaptureDevice*)device
       expectedFormat:(nullable AVCaptureDeviceFormat*)expectedFormat;

- (nullable AVCaptureDeviceFormat*)selectFormatForDevice:(nonnull AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight;

/// VNVAR: chọn định dạng gần kích thước nhất, rồi ưu tiên 8-bit 4:2:0, rồi
/// định dạng đạt [targetFps] (lấy bản FPS tối đa thấp nhất vẫn đạt, tránh định
/// dạng quay chậm), rồi pixel format capturer ưa dùng. Phiên multi-cam chỉ xét
/// định dạng hỗ trợ multi-cam.
- (nullable AVCaptureDeviceFormat*)selectFormatForDevice:(nonnull AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight
                                      targetFps:(NSInteger)targetFps;

- (nullable AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position;


@end
