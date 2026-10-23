#import "VFObjC.h"
#import <AudioUnit/AUCocoaUIView.h>

BOOL VFTryObjC(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"VoxFlowAir.ObjCException"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason,
                                                @"ExceptionName": exception.name}];
        }
        return NO;
    }
}

static BOOL VFGetCocoaInfo(AudioUnit unit, AudioUnitCocoaViewInfo **outInfo, UInt32 *outCount) {
    UInt32 dataSize = 0;
    Boolean writable = false;
    OSStatus st = AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &dataSize, &writable);
    if (st != noErr || dataSize < sizeof(AudioUnitCocoaViewInfo)) { return NO; }
    AudioUnitCocoaViewInfo *info = (AudioUnitCocoaViewInfo *)malloc(dataSize);
    st = AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, info, &dataSize);
    if (st != noErr) { free(info); return NO; }
    *outInfo = info;
    *outCount = (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef);
    return YES;
}

BOOL VFAudioUnitHasCocoaView(AudioUnit unit) {
    AudioUnitCocoaViewInfo *info = NULL; UInt32 count = 0;
    if (!VFGetCocoaInfo(unit, &info, &count)) { return NO; }
    if (info->mCocoaAUViewBundleLocation) CFRelease(info->mCocoaAUViewBundleLocation);
    for (UInt32 i = 0; i < count; i++) { if (info->mCocoaAUViewClass[i]) CFRelease(info->mCocoaAUViewClass[i]); }
    free(info);
    return count > 0;
}

NSView * _Nullable VFCreateCocoaViewForAudioUnit(AudioUnit unit, NSSize preferredSize) {
    AudioUnitCocoaViewInfo *info = NULL; UInt32 count = 0;
    if (!VFGetCocoaInfo(unit, &info, &count)) { return nil; }
    NSView *view = nil;
    @try {
        NSURL *bundleURL = (__bridge NSURL *)info->mCocoaAUViewBundleLocation;
        NSString *className = (__bridge NSString *)info->mCocoaAUViewClass[0];
        NSBundle *bundle = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
        Class factoryClass = [bundle classNamed:className];
        if (factoryClass && [factoryClass conformsToProtocol:@protocol(AUCocoaUIBase)]) {
            id<AUCocoaUIBase> factory = [[factoryClass alloc] init];
            view = [factory uiViewForAudioUnit:unit withSize:preferredSize];
        }
    } @catch (NSException *e) {
        view = nil;
    }
    if (info->mCocoaAUViewBundleLocation) CFRelease(info->mCocoaAUViewBundleLocation);
    for (UInt32 i = 0; i < count; i++) { if (info->mCocoaAUViewClass[i]) CFRelease(info->mCocoaAUViewClass[i]); }
    free(info);
    return view;
}
