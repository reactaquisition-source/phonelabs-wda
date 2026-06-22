/**
 * PhoneLabs — on-device hardware H.264 screen stream for WebDriverAgent.
 *
 * Mirrors FBMjpegServer, but instead of sending JPEG frames it captures the
 * screen, encodes it with VideoToolbox (hardware H.264) and streams a raw
 * Annex-B H.264 elementary stream (start codes 00 00 00 01, SPS/PPS prepended
 * on every keyframe) to every connected TCP client. The PhoneLabs engine
 * forwards the socket (go-ios) and feeds the bytes to jMuxer in the browser.
 *
 * Enabled only when --h264-server-port (or env H264_SERVER_PORT) is set.
 */

#import <Foundation/Foundation.h>
#import "FBTCPSocket.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBH264Server : NSObject <FBTCPSocketDelegate>

- (void)stopStreaming;

@end

NS_ASSUME_NONNULL_END
