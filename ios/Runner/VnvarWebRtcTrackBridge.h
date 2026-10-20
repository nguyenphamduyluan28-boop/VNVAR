#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface VnvarWebRtcTrackBridge : NSObject

+ (RTCVideoTrack * _Nullable)videoTrackForId:(NSString *)trackId
    NS_SWIFT_NAME(videoTrack(forId:));
+ (CVPixelBufferRef _Nullable)copyPixelBufferForFrame:(RTCVideoFrame *)frame
    CF_RETURNS_RETAINED
    NS_SWIFT_NAME(copyPixelBuffer(for:));
/// Canvas RTSP của khung (cùng quy tắc giới hạn 1080p/letterbox như
/// copyPixelBufferForFrame) dưới dạng CIImage chưa render, extent gốc (0,0).
/// Dùng cho luồng RTSP overlay: chồng ảnh rồi render đúng một lần.
+ (CIImage * _Nullable)canvasImageForFrame:(RTCVideoFrame *)frame
    NS_SWIFT_NAME(canvasImage(for:));
/// Nhả pool CVPixelBuffer dùng cho copyPixelBufferForFrame (gọi khi dừng RTSP).
+ (void)releaseConversionResources
    NS_SWIFT_NAME(releaseConversionResources());
+ (AVCaptureDevice * _Nullable)activeVideoDeviceForTrackId:(NSString *)trackId
    NS_SWIFT_NAME(activeVideoDevice(forTrackId:));
+ (void)switchCameraForTrackId:(NSString *)trackId
                    toDeviceId:(NSString *)deviceId
                    completion:(void (^)(BOOL success, NSString * _Nullable error))completion
    NS_SWIFT_NAME(switchCamera(forTrackId:toDeviceId:completion:));
/// Bù sáng (EV) cho camera đang mở; trả về mức đã áp dụng hoặc NAN khi lỗi.
+ (float)setExposureBiasForTrackId:(NSString *)trackId
                              bias:(float)bias
    NS_SWIFT_NAME(setExposureBias(forTrackId:bias:));

+ (BOOL)setCameraLockForTrackId:(NSString *)trackId
                         locked:(BOOL)locked
    NS_SWIFT_NAME(setCameraLock(forTrackId:locked:));

@end

typedef void (^VnvarAudioPcmHandler)(NSData *pcm, NSInteger sampleRate,
    NSInteger channels, NSInteger bitsPerSample);

@interface VnvarWebRtcAudioSink : NSObject
@property(nonatomic, copy, nullable) VnvarAudioPcmHandler onPcm;
- (instancetype _Nullable)initWithTrackId:(NSString *)trackId;
- (void)close;
@end

NS_ASSUME_NONNULL_END
