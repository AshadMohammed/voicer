#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL VIInstallMeetingAudioTap(
    AVAudioInputNode *inputNode,
    AVAudioFormat *format,
    AVAudioNodeTapBlock tapBlock,
    NSError **error
);

NS_ASSUME_NONNULL_END
