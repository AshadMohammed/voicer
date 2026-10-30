#import "MeetingAudioExceptionCatcher.h"

BOOL VIInstallMeetingAudioTap(
    AVAudioInputNode *inputNode,
    AVAudioFormat *format,
    AVAudioNodeTapBlock tapBlock,
    NSError **error
) {
    @try {
        [inputNode installTapOnBus:0 bufferSize:4096 format:format block:tapBlock];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"Voicer.MeetingAudio" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
