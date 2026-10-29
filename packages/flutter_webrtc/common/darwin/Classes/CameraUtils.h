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

- (NSInteger)selectFpsForFormat:(nonnull AVCaptureDeviceFormat*)format targetFps:(NSInteger)targetFps;

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
