#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and turns any NSException into an NSError.
/// AVAudioEngine reports some format errors by throwing an exception, which
/// Swift cannot catch: without this guard, the app would crash.
BOOL VFTryObjC(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

/// Loads the native Cocoa view of an Audio Unit v2 (kAudioUnitProperty_CocoaUI).
/// Returns nil if the plugin does not provide one.
NSView * _Nullable VFCreateCocoaViewForAudioUnit(AudioUnit unit, NSSize preferredSize);

/// Tells whether the AU v2 declares a Cocoa view.
BOOL VFAudioUnitHasCocoaView(AudioUnit unit);

NS_ASSUME_NONNULL_END
