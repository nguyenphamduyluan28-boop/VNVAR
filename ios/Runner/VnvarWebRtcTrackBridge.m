#import "VnvarWebRtcTrackBridge.h"
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/FlutterRTCAudioSink.h>
#import <math.h>

@implementation VnvarWebRtcTrackBridge

+ (RTCVideoTrack * _Nullable)videoTrackForId:(NSString *)trackId {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (plugin == nil || trackId.length == 0) {
    return nil;
  }
  RTCMediaStreamTrack *track = [plugin trackForId:trackId peerConnectionId:nil];
  if (![track isKindOfClass:[RTCVideoTrack class]]) {
    return nil;
  }
  return (RTCVideoTrack *)track;
}

+ (CVPixelBufferRef _Nullable)copyPixelBufferForFrame:(RTCVideoFrame *)frame {
  id<RTCI420Buffer> source = [frame.buffer toI420];
  if (source == nil) {
    return nil;
  }

  int width = source.width;
  int height = source.height;
  if (frame.rotation == RTCVideoRotation_90 ||
      frame.rotation == RTCVideoRotation_270) {
    width = source.height;
    height = source.width;
  }
  RTCI420Buffer *rotated = [[RTCI420Buffer alloc] initWithWidth:width
                                                        height:height];
  [RTCYUVHelper I420Rotate:source.dataY
                srcStrideY:source.strideY
                      srcU:source.dataU
                srcStrideU:source.strideU
                      srcV:source.dataV
                srcStrideV:source.strideV
                      dstY:(uint8_t *)rotated.dataY
                dstStrideY:rotated.strideY
                      dstU:(uint8_t *)rotated.dataU
                dstStrideU:rotated.strideU
                      dstV:(uint8_t *)rotated.dataV
                dstStrideV:rotated.strideV
                     width:source.width
                    height:source.height
                      mode:frame.rotation];

  NSDictionary *attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVPixelBufferRef pixelBuffer = nil;
  CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      (__bridge CFDictionaryRef)attributes,
      &pixelBuffer);
  if (status != kCVReturnSuccess || pixelBuffer == nil) {
    return nil;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
  uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
  const size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  const size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  [RTCYUVHelper I420ToNV12:rotated.dataY
                srcStrideY:rotated.strideY
                      srcU:rotated.dataU
                srcStrideU:rotated.strideU
                      srcV:rotated.dataV
                srcStrideV:rotated.strideV
                      dstY:dstY
                dstStrideY:(int)dstYStride
                     dstUV:dstUV
               dstStrideUV:(int)dstUVStride
                     width:rotated.width
                    height:rotated.height];
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  return pixelBuffer;
}

@end

@implementation VnvarWebRtcAudioSink {
  FlutterRTCAudioSink *_sink;
  BOOL _closed;
}

- (instancetype _Nullable)initWithTrackId:(NSString *)trackId {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  RTCMediaStreamTrack *track = [plugin trackForId:trackId peerConnectionId:nil];
  if (plugin == nil || trackId.length == 0 ||
      ![track isKindOfClass:[RTCAudioTrack class]]) return nil;
  self = [super init];
  if (self) {
    _sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:(RTCAudioTrack *)track];
    __weak VnvarWebRtcAudioSink *weakSelf = self;
    _sink.bufferCallback = ^(CMSampleBufferRef sampleBuffer) {
      VnvarWebRtcAudioSink *strongSelf = weakSelf;
      if (strongSelf == nil || strongSelf->_closed || strongSelf.onPcm == nil) return;
      CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
      CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
      const AudioStreamBasicDescription *format = description == nil
          ? nil : CMAudioFormatDescriptionGetStreamBasicDescription(description);
      if (block == nil || format == nil || format->mFormatID != kAudioFormatLinearPCM) return;
      size_t lengthAtOffset = 0, totalLength = 0;
      char *bytes = NULL;
      OSStatus status = CMBlockBufferGetDataPointer(
          block, 0, &lengthAtOffset, &totalLength, &bytes);
      if (status != kCMBlockBufferNoErr || bytes == NULL || totalLength == 0) return;
      strongSelf.onPcm(
          [NSData dataWithBytes:bytes length:totalLength],
          (NSInteger)llround(format->mSampleRate),
          (NSInteger)format->mChannelsPerFrame,
          (NSInteger)format->mBitsPerChannel);
    };
  }
  return self;
}

- (void)close {
  if (_closed) return;
  _closed = YES;
  _sink.bufferCallback = nil;
  [_sink close];
  _sink = nil;
  self.onPcm = nil;
}

- (void)dealloc { [self close]; }
@end
