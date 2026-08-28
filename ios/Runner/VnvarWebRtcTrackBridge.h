#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface VnvarWebRtcTrackBridge : NSObject

+ (RTCVideoTrack * _Nullable)videoTrackForId:(NSString *)trackId;
+ (CVPixelBufferRef _Nullable)copyPixelBufferForFrame:(RTCVideoFrame *)frame
    CF_RETURNS_RETAINED;

@end

typedef void (^VnvarAudioPcmHandler)(NSData *pcm, NSInteger sampleRate,
    NSInteger channels, NSInteger bitsPerSample);

@interface VnvarWebRtcAudioSink : NSObject
@property(nonatomic, copy, nullable) VnvarAudioPcmHandler onPcm;
- (instancetype _Nullable)initWithTrackId:(NSString *)trackId;
- (void)close;
@end

NS_ASSUME_NONNULL_END
