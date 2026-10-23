// VoxFlowAir Driver — VoxFlowAir's virtual audio device (AudioServerPlugIn).
//
// Written for VoxFlowAir from the contract documented in <CoreAudio/AudioServerPlugIn.h>
// (macOS 27 SDK). No third-party code is reused.
//
// Two devices share a virtual clock and an audio ring:
//   "VoxFlowAir Source (internal)" (hidden, output)   ← VoxFlowAir writes the processed signal
//   "VoxFlowAir Micro"             (visible, input)   → OBS, FaceTime… read it as a microphone
// When VoxFlowAir is not writing, the microphone produces silence (old audio is never replayed).
//
// Objects:
//   1 plug-in · 2 mic · 3 mic input stream · 4 source · 5 source output stream

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/log.h>
#include <stdatomic.h>
#include <string.h>

#include "VoxFlowAirDriverShared.h"
#include "vf_ring.h"

enum {
    kObj_PlugIn = kAudioObjectPlugInObject,
    kObj_Mic = 2,
    kObj_MicStream = 3,
    kObj_Feed = 4,
    kObj_FeedStream = 5,
};

static const Float64 kRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
static const UInt32 kRateCount = sizeof(kRates) / sizeof(kRates[0]);
static const Float64 kDefaultRate = 48000.0;
static const UInt32 kSafetyOffsetFrames = 0;   // virtual clock: no hardware constraint
static const UInt32 kLatencyFrames = 0;
#define kStorageKey_SampleRate CFSTR("NominalSampleRate")
#define kStorageKey_MicName CFSTR("MicName")
static const CFIndex kMaxNameLength = 63;

// ------------------------------------------------------------------ state

static os_log_t gLog;
static AudioServerPlugInHostRef gHost = NULL;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;   // non-real-time state
static os_unfair_lock gClockLock = OS_UNFAIR_LOCK_INIT;   // clock (very short sections)
static _Atomic UInt32 gRefCount = 0;

static Float64 gSampleRate = 48000.0;
static CFStringRef gMicName = NULL;      // mic display name, settable by VoxFlowAir (under gStateLock)
static UInt32 gIOCount[6] = { 0 };       // indexed by device ID
static UInt32 gTotalIO = 0;

static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimestampCount = 0;
static UInt64 gClockSeed = 1;

static vf_ring gRing;

// Diagnostic counters, readable by VoxFlowAir through a custom mic property.
static _Atomic UInt64 gFramesWritten = 0;
static _Atomic UInt64 gFramesRead = 0;
static _Atomic UInt64 gFramesValid = 0;

// Custom property: stream status, CFDictionary (read-only) on the mic and the source.
#define kVFPropertyStatus 'vfst'
// Custom property: mic display name (CFString, settable). The HAL does not forward writes
// of kAudioObjectPropertyName to drivers (checked: 'nope'), hence this property.
#define kVFPropertyMicName 'vfnm'

// ------------------------------------------------------------------ COM interface

static HRESULT VF_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG VF_AddRef(void *inDriver);
static ULONG VF_Release(void *inDriver);
static OSStatus VF_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus VF_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus VF_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus VF_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus VF_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus VF_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus VF_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean VF_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus VF_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus VF_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus VF_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus VF_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus VF_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus VF_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus VF_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus VF_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus VF_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus VF_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus VF_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    VF_QueryInterface, VF_AddRef, VF_Release,
    VF_Initialize, VF_CreateDevice, VF_DestroyDevice,
    VF_AddDeviceClient, VF_RemoveDeviceClient,
    VF_PerformDeviceConfigurationChange, VF_AbortDeviceConfigurationChange,
    VF_HasProperty, VF_IsPropertySettable, VF_GetPropertyDataSize, VF_GetPropertyData, VF_SetPropertyData,
    VF_StartIO, VF_StopIO, VF_GetZeroTimeStamp,
    VF_WillDoIOOperation, VF_BeginIOOperation, VF_DoIOOperation, VF_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// Entry point declared in Info.plist (CFPlugInFactories).
__attribute__((visibility("default")))
void *VoxFlowAirDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT VF_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = 0;
    }
    CFRelease(requested);
    return result;
}

static ULONG VF_AddRef(void *inDriver)
{
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG VF_Release(void *inDriver)
{
    if (inDriver != gDriverRef) return 0;
    UInt32 prev = atomic_load(&gRefCount);
    while (prev > 0 && !atomic_compare_exchange_weak(&gRefCount, &prev, prev - 1)) { }
    return prev > 0 ? prev - 1 : 0;
}

// ------------------------------------------------------------------ helpers

static Boolean IsDevice(AudioObjectID o) { return o == kObj_Mic || o == kObj_Feed; }
static Boolean IsStream(AudioObjectID o) { return o == kObj_MicStream || o == kObj_FeedStream; }
static Boolean IsSupportedRate(Float64 r)
{
    for (UInt32 i = 0; i < kRateCount; i++) if (kRates[i] == r) return true;
    return false;
}

static void UpdateTicksPerFrame(void)
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = ticksPerSecond / gSampleRate;
}

static void FillFormat(AudioStreamBasicDescription *f, Float64 rate)
{
    memset(f, 0, sizeof(*f));
    f->mSampleRate = rate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket = 4 * kVFDriver_Channels;
    f->mFramesPerPacket = 1;
    f->mBytesPerFrame = 4 * kVFDriver_Channels;
    f->mChannelsPerFrame = kVFDriver_Channels;
    f->mBitsPerChannel = 32;
}

static CFDictionaryRef CopyStatus(void)
{
    os_unfair_lock_lock(&gStateLock);
    SInt64 micIO = gIOCount[kObj_Mic], feedIO = gIOCount[kObj_Feed];
    Float64 rate = gSampleRate;
    os_unfair_lock_unlock(&gStateLock);
    SInt64 written = (SInt64)atomic_load(&gFramesWritten), read = (SInt64)atomic_load(&gFramesRead),
           valid = (SInt64)atomic_load(&gFramesValid);
    SInt64 gaps = (SInt64)atomic_load(&gRing.gaps), resets = (SInt64)atomic_load(&gRing.resets);
    const void *keys[] = { CFSTR("micClients"), CFSTR("feedClients"), CFSTR("sampleRate"),
                           CFSTR("framesWritten"), CFSTR("framesRead"), CFSTR("framesValid"),
                           CFSTR("gaps"), CFSTR("resets"), CFSTR("version") };
    CFTypeRef vals[9];
    vals[0] = CFNumberCreate(NULL, kCFNumberSInt64Type, &micIO);
    vals[1] = CFNumberCreate(NULL, kCFNumberSInt64Type, &feedIO);
    vals[2] = CFNumberCreate(NULL, kCFNumberFloat64Type, &rate);
    vals[3] = CFNumberCreate(NULL, kCFNumberSInt64Type, &written);
    vals[4] = CFNumberCreate(NULL, kCFNumberSInt64Type, &read);
    vals[5] = CFNumberCreate(NULL, kCFNumberSInt64Type, &valid);
    vals[6] = CFNumberCreate(NULL, kCFNumberSInt64Type, &gaps);
    vals[7] = CFNumberCreate(NULL, kCFNumberSInt64Type, &resets);
    vals[8] = CFSTR(VFDRIVER_VERSION);
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 9, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < 8; i++) CFRelease(vals[i]);
    return d;
}

// ------------------------------------------------------------------ lifecycle

static OSStatus VF_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gLog = os_log_create(kVFDriver_BundleID, "driver");
    gHost = inHost;
    gSampleRate = kDefaultRate;
    // Stored sample rate (persists across restarts), provided by the host.
    if (gHost && gHost->CopyFromStorage) {
        CFPropertyListRef stored = NULL;
        if (gHost->CopyFromStorage(gHost, kStorageKey_SampleRate, &stored) == 0 && stored) {
            Float64 r = 0;
            if (CFGetTypeID(stored) == CFNumberGetTypeID() && CFNumberGetValue(stored, kCFNumberFloat64Type, &r) && IsSupportedRate(r))
                gSampleRate = r;
            CFRelease(stored);
        }
    }
    if (gHost && gHost->CopyFromStorage) {
        CFPropertyListRef stored = NULL;
        if (gHost->CopyFromStorage(gHost, kStorageKey_MicName, &stored) == 0 && stored) {
            if (CFGetTypeID(stored) == CFStringGetTypeID() && CFStringGetLength(stored) > 0 && CFStringGetLength(stored) <= kMaxNameLength) {
                os_unfair_lock_lock(&gStateLock);
                if (gMicName) CFRelease(gMicName);
                gMicName = CFStringCreateCopy(NULL, stored);
                os_unfair_lock_unlock(&gStateLock);
            }
            CFRelease(stored);
        }
    }
    UpdateTicksPerFrame();
    if (gRing.data == NULL && vf_ring_init(&gRing, kVFDriver_RingFrames, kVFDriver_Channels) != 0) {
        os_log_error(gLog, "VoxFlowAir Driver: could not allocate the ring");
        return kAudioHardwareUnspecifiedError;
    }
    os_log(gLog, "VoxFlowAir Driver %{public}s initialized at %.0f Hz", VFDRIVER_VERSION, gSampleRate);
    return 0;
}

static OSStatus VF_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out)
{ return kAudioHardwareUnsupportedOperationError; }
static OSStatus VF_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev)
{ return kAudioHardwareUnsupportedOperationError; }
static OSStatus VF_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci)
{ return d == gDriverRef && IsDevice(dev) ? 0 : kAudioHardwareBadObjectError; }
static OSStatus VF_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci)
{ return d == gDriverRef && IsDevice(dev) ? 0 : kAudioHardwareBadObjectError; }

static OSStatus VF_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info)
{
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(dev)) return kAudioHardwareBadDeviceError;
    Float64 rate = (Float64)action;
    if (!IsSupportedRate(rate)) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gStateLock);
    Boolean changed = gSampleRate != rate;
    gSampleRate = rate;
    os_unfair_lock_unlock(&gStateLock);
    os_unfair_lock_lock(&gClockLock);
    UpdateTicksPerFrame();
    if (changed) {
        // The frame duration changes: with the old anchor, zero timestamps would land in the
        // future and the clock would stay frozen (silent mic). New anchor, signaled by the seed.
        gAnchorHostTime = mach_absolute_time();
        gTimestampCount = 0;
        gClockSeed++;
    }
    os_unfair_lock_unlock(&gClockLock);
    if (changed) {
        vf_ring_reset(&gRing);
        if (gHost && gHost->WriteToStorage) {
            CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat64Type, &rate);
            gHost->WriteToStorage(gHost, kStorageKey_SampleRate, n);
            CFRelease(n);
        }
        os_log(gLog, "VoxFlowAir Driver: sample rate %.0f Hz", rate);
    }
    return 0;
}

static OSStatus VF_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info)
{ return 0; }

// ------------------------------------------------------------------ properties

static Boolean VF_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a)
{
    if (d != gDriverRef || a == NULL) return false;
    switch (obj) {
    case kObj_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObj_Mic: case kObj_Feed:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout: case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockIsStable: case kVFPropertyStatus:
        case kAudioObjectPropertyCustomPropertyInfoList:
            return true;
        case kVFPropertyMicName:
            return obj == kObj_Mic;
        }
        return false;
    case kObj_MicStream: case kObj_FeedStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus VF_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out)
{
    if (d != gDriverRef || out == NULL) return kAudioHardwareBadObjectError;
    if (!VF_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (IsDevice(obj) && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    if (obj == kObj_Mic && a->mSelector == kVFPropertyMicName) *out = true;
    if (IsStream(obj) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) *out = true;
    return 0;
}

// Number of streams of a device in the requested scope.
static UInt32 StreamCount(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    Boolean input = dev == kObj_Mic;
    if (scope == kAudioObjectPropertyScopeGlobal) return 1;
    if (scope == kAudioObjectPropertyScopeInput) return input ? 1 : 0;
    if (scope == kAudioObjectPropertyScopeOutput) return input ? 0 : 1;
    return 0;
}

static OSStatus VF_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *out)
{
    if (d != gDriverRef || a == NULL || out == NULL) return kAudioHardwareBadObjectError;
    if (!VF_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle: case kVFPropertyStatus:
        *out = sizeof(CFTypeRef); return 0;
    case kAudioPlugInPropertyTranslateUIDToBox: case kAudioPlugInPropertyTranslateUIDToDevice:
        *out = sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyBoxList: *out = 0; return 0;
    case kAudioObjectPropertyControlList: *out = 0; return 0;
    case kAudioObjectPropertyCustomPropertyInfoList: *out = (obj == kObj_Mic ? 2 : 1) * sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
    case kVFPropertyMicName: *out = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyOwnedObjects:
        if (obj == kObj_PlugIn) *out = 2 * sizeof(AudioObjectID);
        else if (IsDevice(obj)) *out = StreamCount(obj, a->mScope) * sizeof(AudioObjectID);
        else *out = 0;
        return 0;
    case kAudioPlugInPropertyDeviceList: *out = 2 * sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyStreams: *out = StreamCount(obj, a->mScope) * sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyRelatedDevices: *out = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates: *out = kRateCount * sizeof(AudioValueRange); return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        *out = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kVFDriver_Channels * sizeof(AudioChannelDescription)); return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        *out = sizeof(AudioStreamBasicDescription); return 0;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *out = kRateCount * sizeof(AudioStreamRangedDescription); return 0;
    default: *out = sizeof(UInt32); return 0;
    }
}

#define NEED(sz) do { if (inDataSize < (sz)) return kAudioHardwareBadPropertySizeError; } while (0)

static OSStatus VF_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                   UInt32 qs, const void *q, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (d != gDriverRef || a == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareBadObjectError;
    if (!VF_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    const Boolean isMic = obj == kObj_Mic || obj == kObj_MicStream;
    UInt32 *u32 = (UInt32 *)outData;

    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        NEED(sizeof(AudioClassID));
        *u32 = kAudioObjectClassID;
        *outDataSize = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyClass:
        NEED(sizeof(AudioClassID));
        *u32 = obj == kObj_PlugIn ? kAudioPlugInClassID : (IsDevice(obj) ? kAudioDeviceClassID : kAudioStreamClassID);
        *outDataSize = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner:
        NEED(sizeof(AudioObjectID));
        *u32 = obj == kObj_PlugIn ? kAudioObjectUnknown : (IsDevice(obj) ? kObj_PlugIn : (isMic ? kObj_Mic : kObj_Feed));
        *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyManufacturer:
        NEED(sizeof(CFStringRef));
        *(CFStringRef *)outData = CFSTR(kVFDriver_Manufacturer);
        *outDataSize = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyName: case kVFPropertyMicName:
        NEED(sizeof(CFStringRef));
        if (obj == kObj_Mic) {
            // The caller releases the string it gets: hand it a retained reference.
            os_unfair_lock_lock(&gStateLock);
            *(CFStringRef *)outData = (CFStringRef)CFRetain(gMicName ? gMicName : CFSTR(kVFDriver_MicName));
            os_unfair_lock_unlock(&gStateLock);
        }
        else if (obj == kObj_Feed) *(CFStringRef *)outData = CFSTR(kVFDriver_FeedName);
        else *(CFStringRef *)outData = isMic ? CFSTR(kVFDriver_MicName " (input)") : CFSTR(kVFDriver_FeedName " (output)");
        *outDataSize = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyOwnedObjects: {
        UInt32 n = 0;
        AudioObjectID ids[2];
        if (obj == kObj_PlugIn) { ids[0] = kObj_Mic; ids[1] = kObj_Feed; n = 2; }
        else if (IsDevice(obj) && StreamCount(obj, a->mScope)) { ids[0] = isMic ? kObj_MicStream : kObj_FeedStream; n = 1; }
        n = n < inDataSize / sizeof(AudioObjectID) ? n : inDataSize / sizeof(AudioObjectID);
        memcpy(outData, ids, n * sizeof(AudioObjectID));
        *outDataSize = n * sizeof(AudioObjectID); return 0;
    }
    // ---- plug-in
    case kAudioPlugInPropertyBoxList: *outDataSize = 0; return 0;
    case kAudioPlugInPropertyTranslateUIDToBox:
        NEED(sizeof(AudioObjectID)); *u32 = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[2] = { kObj_Mic, kObj_Feed };
        UInt32 n = inDataSize / sizeof(AudioObjectID); if (n > 2) n = 2;
        memcpy(outData, ids, n * sizeof(AudioObjectID));
        *outDataSize = n * sizeof(AudioObjectID); return 0;
    }
    case kAudioPlugInPropertyTranslateUIDToDevice:
        NEED(sizeof(AudioObjectID));
        if (qs != sizeof(CFStringRef) || q == NULL) return kAudioHardwareBadPropertySizeError;
        *u32 = kAudioObjectUnknown;
        if (CFEqual(*(CFStringRef *)q, CFSTR(kVFDriver_MicUID))) *u32 = kObj_Mic;
        else if (CFEqual(*(CFStringRef *)q, CFSTR(kVFDriver_FeedUID))) *u32 = kObj_Feed;
        *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyResourceBundle:
        NEED(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(""); *outDataSize = sizeof(CFStringRef); return 0;
    // ---- devices
    case kAudioDevicePropertyDeviceUID:
        NEED(sizeof(CFStringRef));
        *(CFStringRef *)outData = isMic ? CFSTR(kVFDriver_MicUID) : CFSTR(kVFDriver_FeedUID);
        *outDataSize = sizeof(CFStringRef); return 0;
    case kAudioDevicePropertyModelUID:
        NEED(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(kVFDriver_ModelUID); *outDataSize = sizeof(CFStringRef); return 0;
    case kAudioDevicePropertyTransportType:
        NEED(4); *u32 = kAudioDeviceTransportTypeVirtual; *outDataSize = 4; return 0;
    case kAudioDevicePropertyRelatedDevices:
        NEED(sizeof(AudioObjectID)); *u32 = obj; *outDataSize = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyClockDomain:
        NEED(4); *u32 = kVFDriver_ClockDomain; *outDataSize = 4; return 0;
    case kAudioDevicePropertyDeviceIsAlive:
        NEED(4); *u32 = 1; *outDataSize = 4; return 0;
    case kAudioDevicePropertyDeviceIsRunning:
        NEED(4);
        os_unfair_lock_lock(&gStateLock); *u32 = gIOCount[obj] > 0; os_unfair_lock_unlock(&gStateLock);
        *outDataSize = 4; return 0;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        // The mic can be the default input; the internal source never.
        NEED(4); *u32 = (obj == kObj_Mic && a->mScope != kAudioObjectPropertyScopeOutput) ? 1 : 0; *outDataSize = 4; return 0;
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        NEED(4); *u32 = 0; *outDataSize = 4; return 0;
    case kAudioDevicePropertyLatency:   // = kAudioStreamPropertyLatency
        NEED(4); *u32 = kLatencyFrames; *outDataSize = 4; return 0;
    case kAudioDevicePropertySafetyOffset:
        NEED(4); *u32 = kSafetyOffsetFrames; *outDataSize = 4; return 0;
    case kAudioDevicePropertyStreams: {
        UInt32 n = StreamCount(obj, a->mScope);
        if (inDataSize < n * sizeof(AudioObjectID)) n = inDataSize / sizeof(AudioObjectID);
        if (n) *u32 = isMic ? kObj_MicStream : kObj_FeedStream;
        *outDataSize = n * sizeof(AudioObjectID); return 0;
    }
    case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
    case kAudioDevicePropertyNominalSampleRate:
        NEED(sizeof(Float64));
        os_unfair_lock_lock(&gStateLock); *(Float64 *)outData = gSampleRate; os_unfair_lock_unlock(&gStateLock);
        *outDataSize = sizeof(Float64); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        UInt32 n = inDataSize / sizeof(AudioValueRange); if (n > kRateCount) n = kRateCount;
        AudioValueRange *r = outData;
        for (UInt32 i = 0; i < n; i++) { r[i].mMinimum = kRates[i]; r[i].mMaximum = kRates[i]; }
        *outDataSize = n * sizeof(AudioValueRange); return 0;
    }
    case kAudioDevicePropertyIsHidden:
        NEED(4); *u32 = obj == kObj_Feed ? 1 : 0; *outDataSize = 4; return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        NEED(8); u32[0] = 1; u32[1] = 2; *outDataSize = 8; return 0;
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 sz = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kVFDriver_Channels * sizeof(AudioChannelDescription));
        NEED(sz);
        AudioChannelLayout *l = outData;
        memset(l, 0, sz);
        l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        l->mNumberChannelDescriptions = kVFDriver_Channels;
        l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        *outDataSize = sz; return 0;
    }
    case kAudioDevicePropertyZeroTimeStampPeriod:
        NEED(4); *u32 = kVFDriver_ZeroTSPeriod; *outDataSize = 4; return 0;
    case kAudioDevicePropertyClockIsStable:
        NEED(4); *u32 = 1; *outDataSize = 4; return 0;
    case kAudioObjectPropertyCustomPropertyInfoList: {
        // Declares 'vfst' to the host: without it, the host cannot pass the value on to apps.
        UInt32 n = obj == kObj_Mic ? 2 : 1;
        if (inDataSize < n * sizeof(AudioServerPlugInCustomPropertyInfo)) n = inDataSize / sizeof(AudioServerPlugInCustomPropertyInfo);
        AudioServerPlugInCustomPropertyInfo infos[2] = {
            { kVFPropertyStatus, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
            { kVFPropertyMicName, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone },
        };
        memcpy(outData, infos, n * sizeof(AudioServerPlugInCustomPropertyInfo));
        *outDataSize = n * sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
    }
    case kVFPropertyStatus:
        NEED(sizeof(CFDictionaryRef)); *(CFDictionaryRef *)outData = CopyStatus(); *outDataSize = sizeof(CFDictionaryRef); return 0;
    // ---- streams
    case kAudioStreamPropertyIsActive:
        NEED(4); *u32 = 1; *outDataSize = 4; return 0;
    case kAudioStreamPropertyDirection:
        NEED(4); *u32 = isMic ? 1 : 0; *outDataSize = 4; return 0;   // 1 = input
    case kAudioStreamPropertyTerminalType:
        NEED(4); *u32 = isMic ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine; *outDataSize = 4; return 0;
    case kAudioStreamPropertyStartingChannel:
        NEED(4); *u32 = 1; *outDataSize = 4; return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
        NEED(sizeof(AudioStreamBasicDescription));
        os_unfair_lock_lock(&gStateLock); Float64 r = gSampleRate; os_unfair_lock_unlock(&gStateLock);
        FillFormat(outData, r);
        *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
    }
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
        UInt32 n = inDataSize / sizeof(AudioStreamRangedDescription); if (n > kRateCount) n = kRateCount;
        AudioStreamRangedDescription *r = outData;
        for (UInt32 i = 0; i < n; i++) {
            FillFormat(&r[i].mFormat, kRates[i]);
            r[i].mSampleRateRange.mMinimum = kRates[i];
            r[i].mSampleRateRange.mMaximum = kRates[i];
        }
        *outDataSize = n * sizeof(AudioStreamRangedDescription); return 0;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

// Asks the host to change the sample rate of both devices (same clock).
static OSStatus RequestRate(Float64 rate)
{
    if (!IsSupportedRate(rate)) return kAudioDeviceUnsupportedFormatError;
    os_unfair_lock_lock(&gStateLock); Float64 cur = gSampleRate; os_unfair_lock_unlock(&gStateLock);
    if (cur == rate) return 0;
    if (gHost == NULL || gHost->RequestDeviceConfigurationChange == NULL) return kAudioHardwareIllegalOperationError;
    OSStatus e1 = gHost->RequestDeviceConfigurationChange(gHost, kObj_Mic, (UInt64)rate, NULL);
    OSStatus e2 = gHost->RequestDeviceConfigurationChange(gHost, kObj_Feed, (UInt64)rate, NULL);
    return e1 ? e1 : e2;
}

static OSStatus VF_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                   UInt32 qs, const void *q, UInt32 inDataSize, const void *inData)
{
    if (d != gDriverRef || a == NULL || inData == NULL) return kAudioHardwareBadObjectError;
    if (!VF_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    if (IsDevice(obj) && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        NEED(sizeof(Float64));
        return RequestRate(*(const Float64 *)inData);
    }
    if (obj == kObj_Mic && a->mSelector == kVFPropertyMicName) {
        // Name shown in OBS, FaceTime… Apps find the device by its UID, which never
        // changes: renaming breaks no configuration.
        NEED(sizeof(CFStringRef));
        CFStringRef name = *(const CFStringRef *)inData;
        if (name == NULL || CFGetTypeID(name) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
        CFMutableStringRef trimmed = CFStringCreateMutableCopy(NULL, 0, name);
        CFStringTrimWhitespace(trimmed);
        CFIndex len = CFStringGetLength(trimmed);
        if (len == 0 || len > kMaxNameLength) { CFRelease(trimmed); return kAudioHardwareIllegalOperationError; }
        os_unfair_lock_lock(&gStateLock);
        Boolean same = gMicName ? CFEqual(gMicName, trimmed) : CFEqual(CFSTR(kVFDriver_MicName), trimmed);
        if (!same) { if (gMicName) CFRelease(gMicName); gMicName = CFStringCreateCopy(NULL, trimmed); }
        os_unfair_lock_unlock(&gStateLock);
        if (!same && gHost) {
            if (gHost->WriteToStorage) gHost->WriteToStorage(gHost, kStorageKey_MicName, trimmed);
            AudioServerPlugInHostRef host = gHost;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                AudioObjectPropertyAddress changed = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                host->PropertiesChanged(host, kObj_Mic, 1, &changed);
            });
        }
        CFRelease(trimmed);
        return 0;
    }
    if (IsStream(obj) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        NEED(sizeof(AudioStreamBasicDescription));
        const AudioStreamBasicDescription *f = inData;
        // Only the advertised format (interleaved stereo Float32) is accepted; the rate may change.
        if (f->mFormatID != kAudioFormatLinearPCM || !(f->mFormatFlags & kAudioFormatFlagIsFloat) ||
            f->mBitsPerChannel != 32 || f->mChannelsPerFrame != kVFDriver_Channels || f->mFramesPerPacket != 1)
            return kAudioDeviceUnsupportedFormatError;
        return RequestRate(f->mSampleRate);
    }
    return kAudioHardwareUnsupportedOperationError;
}

// ------------------------------------------------------------------ I/O

static OSStatus VF_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client)
{
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(dev)) return kAudioHardwareBadDeviceError;
    os_unfair_lock_lock(&gStateLock);
    if (gTotalIO == 0) {
        // First activity: the virtual clock starts.
        os_unfair_lock_lock(&gClockLock);
        gAnchorHostTime = mach_absolute_time();
        gTimestampCount = 0;
        gClockSeed++;
        os_unfair_lock_unlock(&gClockLock);
    }
    if (dev == kObj_Feed && gIOCount[kObj_Feed] == 0) vf_ring_reset(&gRing);
    gIOCount[dev]++;
    gTotalIO++;
    os_unfair_lock_unlock(&gStateLock);
    return 0;
}

static OSStatus VF_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client)
{
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(dev)) return kAudioHardwareBadDeviceError;
    os_unfair_lock_lock(&gStateLock);
    if (gIOCount[dev] == 0) { os_unfair_lock_unlock(&gStateLock); return kAudioHardwareIllegalOperationError; }
    gIOCount[dev]--;
    gTotalIO--;
    // VoxFlowAir stops: the mic switches to silence right away.
    if (dev == kObj_Feed && gIOCount[kObj_Feed] == 0) vf_ring_reset(&gRing);
    os_unfair_lock_unlock(&gStateLock);
    return 0;
}

static OSStatus VF_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(dev)) return kAudioHardwareBadDeviceError;
    os_unfair_lock_lock(&gClockLock);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kVFDriver_ZeroTSPeriod;
    // Number of whole periods elapsed since the anchor (never goes back).
    if (now > gAnchorHostTime && ticksPerPeriod > 0) {
        UInt64 periods = (UInt64)((Float64)(now - gAnchorHostTime) / ticksPerPeriod);
        if (periods > gTimestampCount) gTimestampCount = periods;
    }
    *outSampleTime = (Float64)gTimestampCount * kVFDriver_ZeroTSPeriod;
    *outHostTime = gAnchorHostTime + (UInt64)(ticksPerPeriod * (Float64)gTimestampCount);
    *outSeed = gClockSeed;
    os_unfair_lock_unlock(&gClockLock);
    return 0;
}

static OSStatus VF_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outInPlace)
{
    if (d != gDriverRef || outWillDo == NULL || outInPlace == NULL) return kAudioHardwareBadObjectError;
    if (!IsDevice(dev)) return kAudioHardwareBadDeviceError;
    *outWillDo = (dev == kObj_Mic && op == kAudioServerPlugInIOOperationReadInput) ||
                 (dev == kObj_Feed && op == kAudioServerPlugInIOOperationWriteMix);
    *outInPlace = true;
    return 0;
}

static OSStatus VF_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info)
{ return d == gDriverRef && IsDevice(dev) ? 0 : kAudioHardwareBadObjectError; }
static OSStatus VF_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info)
{ return d == gDriverRef && IsDevice(dev) ? 0 : kAudioHardwareBadObjectError; }

static OSStatus VF_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary)
{
    if (d != gDriverRef || info == NULL) return kAudioHardwareBadObjectError;
    if (!IsDevice(dev)) return kAudioHardwareBadDeviceError;
    if (main == NULL) return 0;
    if (dev == kObj_Feed && op == kAudioServerPlugInIOOperationWriteMix) {
        vf_ring_write(&gRing, (int64_t)info->mOutputTime.mSampleTime, main, frames);
        atomic_fetch_add_explicit(&gFramesWritten, frames, memory_order_relaxed);
    } else if (dev == kObj_Mic && op == kAudioServerPlugInIOOperationReadInput) {
        uint32_t valid = vf_ring_read(&gRing, (int64_t)info->mInputTime.mSampleTime, main, frames);
        atomic_fetch_add_explicit(&gFramesRead, frames, memory_order_relaxed);
        atomic_fetch_add_explicit(&gFramesValid, valid, memory_order_relaxed);
    }
    return 0;
}
