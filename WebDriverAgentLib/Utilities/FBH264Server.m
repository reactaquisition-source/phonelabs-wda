/**
 * PhoneLabs — on-device hardware H.264 screen stream for WebDriverAgent.
 * See FBH264Server.h.
 */

#import "FBH264Server.h"

#import <mach/mach_time.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
@import UniformTypeIdentifiers;

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "XCUIScreen.h"

static const NSUInteger H264_FPS = 30;          // capture/encode target fps
static const NSUInteger H264_BITRATE = 3000000; // ~3 Mbps
static const NSUInteger H264_GOP = 30;          // keyframe every ~1s
static const NSTimeInterval FRAME_TIMEOUT = 1.0;
static const NSTimeInterval CAPTURE_QUALITY = 0.85;

@interface FBH264Server ()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) long long mainScreenID;
@property (atomic, assign) BOOL isStreaming;
@property (atomic, assign) BOOL forceKeyframe;
@property (nonatomic, assign) VTCompressionSessionRef session;
@property (nonatomic, assign) size_t encWidth;
@property (nonatomic, assign) size_t encHeight;
@property (nonatomic, assign) int64_t frameIndex;

- (void)sendAnnexB:(NSData *)data;

@end

// Forward declaration: VideoToolbox encode callback (raw NALUs -> Annex-B).
static void FBH264OutputCallback(void *outputRefCon, void *sourceRefCon,
                                 OSStatus status, VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer);

@implementation FBH264Server

- (instancetype)init
{
  if ((self = [super init])) {
    _isStreaming = YES;
    _forceKeyframe = NO;
    _session = NULL;
    _encWidth = 0;
    _encHeight = 0;
    _frameIndex = 0;
    _listeningClients = [NSMutableArray array];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    dispatch_queue_attr_t attrs = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _backgroundQueue = dispatch_queue_create("H264 Screen Provider Queue", attrs);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  }
  return self;
}

#pragma mark - Capture loop

- (void)scheduleNextFrameWithInterval:(uint64_t)interval timeStarted:(uint64_t)started
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started;
  int64_t delta = (int64_t)interval - (int64_t)elapsed;
  __weak typeof(self) weakSelf = self;
  if (delta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delta), self.backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  } else {
    dispatch_async(self.backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  }
}

- (void)streamFrame
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t interval = (uint64_t)(1.0 / (double)H264_FPS * NSEC_PER_SEC);
  uint64_t started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextFrameWithInterval:interval timeStarted:started];
      return;
    }
  }

  NSError *error;
  NSData *jpeg = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                compressionQuality:CAPTURE_QUALITY
                                                               uti:UTTypeJPEG
                                                           timeout:FRAME_TIMEOUT
                                                             error:&error];
  if (nil == jpeg) {
    [FBLogger logFmt:@"[H264] screenshot failed: %@", error.description];
    [self scheduleNextFrameWithInterval:interval timeStarted:started];
    return;
  }

  CVPixelBufferRef pixelBuffer = [self pixelBufferFromJPEG:jpeg];
  if (NULL != pixelBuffer) {
    [self encodePixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
  }

  [self scheduleNextFrameWithInterval:interval timeStarted:started];
}

#pragma mark - JPEG -> CVPixelBuffer

- (CVPixelBufferRef)pixelBufferFromJPEG:(NSData *)jpeg CF_RETURNS_RETAINED
{
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
  if (NULL == src) {
    return NULL;
  }
  CGImageRef image = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  CFRelease(src);
  if (NULL == image) {
    return NULL;
  }
  size_t w = CGImageGetWidth(image);
  size_t h = CGImageGetHeight(image);
  // libx264/VideoToolbox-friendly even dimensions are not required for VT, but
  // keep it tidy. VT handles odd sizes; we keep native resolution.

  NSDictionary *attrs = @{
    (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVPixelBufferRef pb = NULL;
  CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                    kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)attrs, &pb);
  if (rc != kCVReturnSuccess || NULL == pb) {
    CGImageRelease(image);
    return NULL;
  }
  CVPixelBufferLockBaseAddress(pb, 0);
  void *base = CVPixelBufferGetBaseAddress(pb);
  size_t bpr = CVPixelBufferGetBytesPerRow(pb);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                           kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  if (NULL != ctx) {
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);
  }
  CGColorSpaceRelease(cs);
  CVPixelBufferUnlockBaseAddress(pb, 0);
  CGImageRelease(image);
  return pb;
}

#pragma mark - VideoToolbox encode

- (void)ensureSessionForWidth:(size_t)w height:(size_t)h
{
  if (NULL != self.session && self.encWidth == w && self.encHeight == h) {
    return;
  }
  [self teardownSession];

  VTCompressionSessionRef session = NULL;
  OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                           (int32_t)w, (int32_t)h,
                                           kCMVideoCodecType_H264,
                                           NULL, NULL, NULL,
                                           FBH264OutputCallback,
                                           (__bridge void *)self,
                                           &session);
  if (st != noErr || NULL == session) {
    [FBLogger logFmt:@"[H264] VTCompressionSessionCreate failed: %d", (int)st];
    return;
  }
  VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(H264_GOP));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(H264_BITRATE));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(H264_FPS));
  VTCompressionSessionPrepareToEncodeFrames(session);

  self.session = session;
  self.encWidth = w;
  self.encHeight = h;
  self.forceKeyframe = YES; // first frame of a new session must be a keyframe
  [FBLogger logFmt:@"[H264] encoder ready %zux%zu", w, h];
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
{
  size_t w = CVPixelBufferGetWidth(pixelBuffer);
  size_t h = CVPixelBufferGetHeight(pixelBuffer);
  [self ensureSessionForWidth:w height:h];
  if (NULL == self.session) {
    return;
  }

  CMTime pts = CMTimeMake(self.frameIndex, (int32_t)H264_FPS);
  self.frameIndex++;

  NSDictionary *frameProps = nil;
  if (self.forceKeyframe) {
    self.forceKeyframe = NO;
    frameProps = @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
  }

  VTEncodeInfoFlags flags;
  OSStatus st = VTCompressionSessionEncodeFrame(self.session, pixelBuffer, pts,
                                                kCMTimeInvalid,
                                                (__bridge CFDictionaryRef)frameProps,
                                                NULL, &flags);
  if (st != noErr) {
    [FBLogger logFmt:@"[H264] encode frame failed: %d", (int)st];
  }
}

- (void)teardownSession
{
  if (NULL != self.session) {
    VTCompressionSessionCompleteFrames(self.session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(self.session);
    CFRelease(self.session);
    self.session = NULL;
  }
}

#pragma mark - Send to clients

- (void)sendAnnexB:(NSData *)data
{
  @synchronized (self.listeningClients) {
    if (!self.isStreaming || 0 == self.listeningClients.count) {
      return;
    }
    for (GCDAsyncSocket *client in self.listeningClients) {
      [client writeData:data withTimeout:FRAME_TIMEOUT tag:0];
    }
  }
}

#pragma mark - FBTCPSocketDelegate

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"[H264] client connected %@:%d", newClient.connectedHost, newClient.connectedPort];
  // Begin only once the client sends any byte (mirrors MJPEG server).
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      return;
    }
    [self.listeningClients addObject:client];
  }
  // New client: force the next encoded frame to be a keyframe so it gets
  // SPS/PPS + an IDR immediately (otherwise jMuxer cannot start decoding).
  self.forceKeyframe = YES;
  [FBLogger logFmt:@"[H264] streaming to client at %@:%d", client.connectedHost, client.connectedPort];
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  [FBLogger log:@"[H264] client disconnected"];
}

- (void)stopStreaming
{
  self.isStreaming = NO;
  @synchronized (self.listeningClients) {
    NSArray<GCDAsyncSocket *> *clients = self.listeningClients.copy;
    [self.listeningClients removeAllObjects];
    for (GCDAsyncSocket *client in clients) {
      [client disconnect];
    }
  }
  [self teardownSession];
}

- (void)dealloc
{
  [self stopStreaming];
  [FBLogger verboseLog:@"FBH264Server deallocated"];
}

@end

#pragma mark - VideoToolbox output callback

static void FBH264OutputCallback(void *outputRefCon, void *sourceRefCon,
                                 OSStatus status, VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer)
{
  if (status != noErr || NULL == sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }
  FBH264Server *server = (__bridge FBH264Server *)outputRefCon;

  static const uint8_t startCode[4] = {0x00, 0x00, 0x00, 0x01};
  static const int AVCC_LEN = 4;
  NSMutableData *out = [NSMutableData data];

  // Keyframe? (sync sample) -> prepend SPS/PPS so late joiners can decode.
  BOOL keyframe = NO;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (NULL != attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    keyframe = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
  }
  if (keyframe) {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (NULL != fmt) {
      size_t paramCount = 0, naluHeaderLen = 0;
      const uint8_t *sps = NULL; size_t spsLen = 0;
      const uint8_t *pps = NULL; size_t ppsLen = 0;
      if (noErr == CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsLen, &paramCount, &naluHeaderLen)
          && noErr == CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsLen, NULL, NULL)) {
        [out appendBytes:startCode length:4];
        [out appendBytes:sps length:spsLen];
        [out appendBytes:startCode length:4];
        [out appendBytes:pps length:ppsLen];
      }
    }
  }

  // AVCC (length-prefixed) -> Annex-B (start codes).
  CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (NULL != bb) {
    size_t totalLen = 0;
    char *dataPtr = NULL;
    if (noErr == CMBlockBufferGetDataPointer(bb, 0, NULL, &totalLen, &dataPtr)) {
      size_t offset = 0;
      while (offset + AVCC_LEN <= totalLen) {
        uint32_t naluLen = 0;
        memcpy(&naluLen, dataPtr + offset, AVCC_LEN);
        naluLen = CFSwapInt32BigToHost(naluLen);
        if (offset + AVCC_LEN + naluLen > totalLen) {
          break;
        }
        [out appendBytes:startCode length:4];
        [out appendBytes:(dataPtr + offset + AVCC_LEN) length:naluLen];
        offset += AVCC_LEN + naluLen;
      }
    }
  }

  if (out.length > 0) {
    [server sendAnnexB:out];
  }
}
