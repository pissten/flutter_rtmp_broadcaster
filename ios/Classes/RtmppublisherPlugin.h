#import <Flutter/Flutter.h>

#ifdef __cplusplus
extern "C" {
#endif

void RigattaWatchdogStart(dispatch_queue_t pluginQueue);
void RigattaWatchdogStop(void);
void RigattaWatchdogTickVideoFrame(void);
void RigattaWatchdogTickAudioFrame(void);
void RigattaWatchdogTickPushVideoEnter(void);
void RigattaWatchdogTickPushVideoExit(void);
void RigattaWatchdogTickPushAudioEnter(void);
void RigattaWatchdogTickPushAudioExit(void);

#ifdef __cplusplus
}
#endif

@interface RtmppublisherPlugin : NSObject<FlutterPlugin>
@end
