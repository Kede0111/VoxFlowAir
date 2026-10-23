// VoxFlowAirDriverTests — tests the virtual device without installing it.
//
//  1. Ring unit tests (vf_ring): continuity, gaps, wraparound, reset, load.
//  2. Driver integration tests: the built VoxFlowAirDriver.driver bundle is loaded into
//     this process through CFPlugIn, exactly as coreaudiod would, with a mock host.
//
// Usage: VoxFlowAirDriverTests [path/to/VoxFlowAirDriver.driver]
//        VoxFlowAirDriverTests --installed [--loopback]   (installed driver, see installed.c)
// Exit code 0 if everything passes.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "VoxFlowAirDriverShared.h"
#include "vf_ring.h"
#include "../VoxFlowAirDriver/vf_ring.c"

int gFailures = 0, gChecks = 0;
int testInstalled(int loopback);
int testLatency(const char *feedUID, const char *micUID, UInt32 buffer);
#define CHECK(cond, ...) do { gChecks++; if (!(cond)) { gFailures++; printf("    ✘ %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define TEST(name) printf("◇ %s\n", name)

// ====================================================================== ring

static void fillRamp(float *b, int64_t t, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) { b[2 * i] = (float)(t + i); b[2 * i + 1] = -(float)(t + i); }
}

static int isRamp(const float *b, int64_t t, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++)
        if (b[2 * i] != (float)(t + i) || b[2 * i + 1] != -(float)(t + i)) return 0;
    return 1;
}

static int isSilent(const float *b, uint32_t n)
{
    for (uint32_t i = 0; i < 2 * n; i++) if (b[i] != 0) return 0;
    return 1;
}

static void testRing(void)
{
    vf_ring r;
    float in[2 * 4096], out[2 * 4096];

    TEST("Ring: reading before any write = silence");
    CHECK(vf_ring_init(&r, 32768, 2) == 0, "init");
    CHECK(r.frames == 32768, "size %u", r.frames);
    CHECK(vf_ring_read(&r, 0, out, 512) == 0 && isSilent(out, 512), "silence expected");

    TEST("Ring: reads back exactly what was written");
    fillRamp(in, 1000, 512);
    vf_ring_write(&r, 1000, in, 512);
    CHECK(vf_ring_read(&r, 1000, out, 512) == 512 && isRamp(out, 1000, 512), "identical data");

    TEST("Ring: read straddling the write end");
    uint32_t v = vf_ring_read(&r, 1256, out, 512);
    CHECK(v == 256 && isRamp(out, 1256, 256) && isSilent(out + 512, 256), "256 valid then silence (v=%u)", v);

    TEST("Ring: wraparound at the end of the buffer");
    vf_ring_reset(&r);
    int64_t t = 32768 - 100;
    fillRamp(in, t, 300);
    vf_ring_write(&r, t, in, 300);
    CHECK(vf_ring_read(&r, t, out, 300) == 300 && isRamp(out, t, 300), "continuity across wraparound");

    TEST("Ring: a write gap reads back as silence (no old audio)");
    vf_ring_reset(&r);
    // Old content at the position that will be "skipped".
    fillRamp(in, 0, 2048); vf_ring_write(&r, 0, in, 2048);
    fillRamp(in, 2048, 512); vf_ring_write(&r, 2048, in, 512);
    fillRamp(in, 3584, 512); vf_ring_write(&r, 3584, in, 512);   // gap [2560, 3584)
    CHECK(vf_ring_read(&r, 2560, out, 1024) == 1024 && isSilent(out, 1024), "gap = silence");
    CHECK(vf_ring_read(&r, 3584, out, 512) == 512 && isRamp(out, 3584, 512), "exact resume");
    CHECK(atomic_load(&r.gaps) == 1, "one gap counted");

    TEST("Ring: after a reset (VoxFlowAir stopped), nothing is read back");
    vf_ring_reset(&r);
    CHECK(vf_ring_read(&r, 3584, out, 512) == 0 && isSilent(out, 512), "silence after stop");

    TEST("Ring: jump ahead larger than the size = ring cleared");
    fillRamp(in, 100, 512); vf_ring_write(&r, 100, in, 512);
    fillRamp(in, 100000, 512); vf_ring_write(&r, 100000, in, 512);
    CHECK(vf_ring_read(&r, 100, out, 512) == 0, "old content unreachable");
    CHECK(vf_ring_read(&r, 100000, out, 512) == 512 && isRamp(out, 100000, 512), "new content");

    TEST("Ring: clock went back = ring cleared");
    fillRamp(in, 0, 512); vf_ring_write(&r, 0, in, 512);
    CHECK(vf_ring_read(&r, 100000, out, 512) == 0, "future content forgotten");
    CHECK(vf_ring_read(&r, 0, out, 512) == 512 && isRamp(out, 0, 512), "fresh start");

    TEST("Ring: block larger than the ring truncated without overflow");
    vf_ring small;
    vf_ring_init(&small, 1000, 2);   // rounded to 1024
    CHECK(small.frames == 1024, "rounded to a power of two");
    float *big = malloc(sizeof(float) * 2 * 3000);
    fillRamp(big, 0, 3000);
    vf_ring_write(&small, 0, big, 3000);
    CHECK(atomic_load(&small.writeEnd) == 3000, "write end %lld", (long long)atomic_load(&small.writeEnd));
    free(big);
    vf_ring_free(&small);
    vf_ring_free(&r);
}

// Load: concurrent writer and reader, variable block sizes, 60 s of signal at 48 kHz.
typedef struct { vf_ring *r; int64_t total; _Atomic int64_t pos; _Atomic int64_t readPos; } loadctx;

static void *writerThread(void *p)
{
    loadctx *c = p;
    float buf[2 * 1024];
    int64_t t = 0;
    unsigned seed = 1;
    while (t < c->total) {
        // Like a real clock: the writer never gets more than 8192 frames ahead.
        if (t - atomic_load(&c->readPos) > 8192) { sched_yield(); continue; }
        uint32_t n = 32 + (rand_r(&seed) % 992);
        fillRamp(buf, t, n);
        vf_ring_write(c->r, t, buf, n);
        t += n;
        atomic_store(&c->pos, t);
    }
    return NULL;
}

static void testRingLoad(void)
{
    TEST("Ring (load): concurrent writes and reads, 2,880,000 frames, continuity checked");
    vf_ring r;
    vf_ring_init(&r, 32768, 2);
    loadctx c = { &r, 48000 * 60, 0, 0 };
    pthread_t th;
    pthread_create(&th, NULL, writerThread, &c);
    float out[2 * 512];
    int64_t rt = 0, bad = 0, validTotal = 0, reads = 0;
    // The reader trails the writer by 2048 frames (like an app reading the mic).
    while (rt + 512 < c.total) {
        int64_t w = atomic_load(&c.pos);
        if (w - rt < 2048 + 512) { if (w >= c.total) break; sched_yield(); continue; }
        uint32_t v = vf_ring_read(&r, rt, out, 512);
        validTotal += v; reads++;
        if (v != 512 || !isRamp(out, rt, 512)) bad++;
        rt += 512;
        atomic_store(&c.readPos, rt);
    }
    pthread_join(th, NULL);
    CHECK(bad == 0, "%lld bad blocks out of %lld", (long long)bad, (long long)reads);
    CHECK(validTotal == reads * 512, "valid frames %lld", (long long)validTotal);
    vf_ring_free(&r);
}

// ====================================================================== driver

static AudioServerPlugInDriverRef gDrv;
static int gRequests = 0;
static AudioObjectID gRequestDevices[8];
static UInt64 gRequestActions[8];
static CFMutableDictionaryRef gStorage;

static _Atomic int gNameChanges = 0;
static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a)
{ if (n && a[0].mSelector == kAudioObjectPropertyName) atomic_fetch_add(&gNameChanges, 1); return 0; }
static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef h, CFStringRef key, CFPropertyListRef *out)
{
    CFPropertyListRef v = CFDictionaryGetValue(gStorage, key);
    *out = v ? CFRetain(v) : NULL;
    return 0;
}
static OSStatus HostWriteToStorage(AudioServerPlugInHostRef h, CFStringRef key, CFPropertyListRef v)
{ CFDictionarySetValue(gStorage, key, v); return 0; }
static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef key)
{ CFDictionaryRemoveValue(gStorage, key); return 0; }
static OSStatus HostRequestConfigChange(AudioServerPlugInHostRef h, AudioObjectID dev, UInt64 action, void *info)
{
    if (gRequests < 8) { gRequestDevices[gRequests] = dev; gRequestActions[gRequests] = action; }
    gRequests++;
    return 0;
}

static AudioServerPlugInHostInterface gHost = {
    HostPropertiesChanged, HostCopyFromStorage, HostWriteToStorage, HostDeleteFromStorage, HostRequestConfigChange,
};

#define DRV (*gDrv)

static OSStatus getProp(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
                        UInt32 qs, const void *q, UInt32 size, void *out, UInt32 *outSize)
{
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    UInt32 s = 0;
    return DRV->GetPropertyData(gDrv, obj, getpid(), &a, qs, q, size, outSize ? outSize : &s, out);
}

static UInt32 getU32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope)
{
    UInt32 v = 0xFFFFFFFF;
    getProp(obj, sel, scope, 0, NULL, 4, &v, NULL);
    return v;
}

static Float64 getRate(AudioObjectID dev)
{
    Float64 r = 0;
    getProp(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, NULL, 8, &r, NULL);
    return r;
}

static int cfEqualsC(CFStringRef s, const char *c)
{
    CFStringRef o = CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8);
    int eq = CFEqual(s, o);
    CFRelease(o);
    return eq;
}

static AudioObjectID translate(const char *uid)
{
    CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID id = 0;
    getProp(kAudioObjectPlugInObject, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
            sizeof(CFStringRef), &s, sizeof(id), &id, NULL);
    CFRelease(s);
    return id;
}

static void testDriver(const char *path)
{
    TEST("Driver: bundle loaded through CFPlugIn (like coreaudiod)");
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    CFRelease(url);
    CHECK(plugin != NULL, "bundle not found: %s", path);
    if (!plugin) return;
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    CHECK(factories && CFArrayGetCount(factories) == 1, "one factory declared for kAudioServerPlugInTypeUUID");
    if (!factories || CFArrayGetCount(factories) == 0) return;
    CFUUIDRef factory = CFArrayGetValueAtIndex(factories, 0);
    void *iunknown = CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    CHECK(iunknown != NULL, "instance created");
    if (!iunknown) return;
    IUnknownVTbl **unk = iunknown;
    void *drv = NULL;
    HRESULT hr = (*unk)->QueryInterface(iunknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &drv);
    CHECK(hr == 0 && drv != NULL, "interface AudioServerPlugInDriverInterface");
    gDrv = drv;
    CFRelease(factories);

    TEST("Driver: initialization with a mock host");
    gStorage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    AudioServerPlugInHostInterface *hp = &gHost;
    CHECK(DRV->Initialize(gDrv, hp) == 0, "Initialize");

    TEST("Driver: two devices, UIDs and names");
    AudioObjectID devs[4] = { 0 };
    UInt32 sz = 0;
    getProp(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(devs), devs, &sz);
    CHECK(sz == 2 * sizeof(AudioObjectID), "2 devices (size %u)", sz);
    AudioObjectID mic = translate(kVFDriver_MicUID), feed = translate(kVFDriver_FeedUID);
    CHECK(mic != 0 && feed != 0 && mic != feed, "UID translation (mic %u, source %u)", mic, feed);
    CHECK(translate("unknown") == kAudioObjectUnknown, "unknown UID");
    CFStringRef name = NULL;
    getProp(mic, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(name), &name, NULL);
    CHECK(name && cfEqualsC(name, kVFDriver_MicName), "mic name");
    CFStringRef uid = NULL;
    getProp(feed, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(uid), &uid, NULL);
    CHECK(uid && cfEqualsC(uid, kVFDriver_FeedUID), "source UID");
    CHECK(getU32(mic, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioDeviceClassID, "device class");
    CHECK(getU32(mic, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual, "virtual transport");
    CHECK(getU32(mic, kAudioDevicePropertyClockDomain, 0) == getU32(feed, kAudioDevicePropertyClockDomain, 0), "same clock domain");

    TEST("Driver: visibility and default role");
    CHECK(getU32(mic, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "mic visible");
    CHECK(getU32(feed, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1, "source hidden");
    CHECK(getU32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1, "mic can be the default input");
    CHECK(getU32(feed, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "source never the default output");
    CHECK(getU32(mic, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput) == 0, "no system sounds");

    TEST("Driver: streams (mic = input only, source = output only)");
    AudioObjectID streams[2] = { 0 };
    getProp(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0, NULL, sizeof(streams), streams, &sz);
    CHECK(sz == sizeof(AudioObjectID), "one input stream on the mic");
    AudioObjectID micStream = streams[0];
    getProp(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0, NULL, sizeof(streams), streams, &sz);
    CHECK(sz == 0, "no output stream on the mic");
    getProp(feed, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0, NULL, sizeof(streams), streams, &sz);
    CHECK(sz == 0, "no input stream on the source");
    getProp(feed, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0, NULL, sizeof(streams), streams, &sz);
    CHECK(sz == sizeof(AudioObjectID), "one output stream on the source");
    AudioObjectID feedStream = streams[0];
    CHECK(getU32(micStream, kAudioStreamPropertyDirection, 0) == 1, "input direction");
    CHECK(getU32(feedStream, kAudioStreamPropertyDirection, 0) == 0, "output direction");
    CHECK(getU32(micStream, kAudioStreamPropertyTerminalType, 0) == kAudioStreamTerminalTypeMicrophone, "microphone terminal");

    TEST("Driver: advertised format = interleaved stereo Float32, 4 sample rates");
    AudioStreamBasicDescription f;
    getProp(micStream, kAudioStreamPropertyVirtualFormat, 0, 0, NULL, sizeof(f), &f, NULL);
    CHECK(f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mChannelsPerFrame == 2
          && f.mBitsPerChannel == 32 && f.mBytesPerFrame == 8 && f.mSampleRate == 48000, "format %u ch %.0f Hz", f.mChannelsPerFrame, f.mSampleRate);
    AudioValueRange rates[8];
    getProp(mic, kAudioDevicePropertyAvailableNominalSampleRates, 0, 0, NULL, sizeof(rates), rates, &sz);
    CHECK(sz == 4 * sizeof(AudioValueRange) && rates[0].mMinimum == 44100 && rates[3].mMaximum == 96000, "44.1 / 48 / 88.2 / 96 kHz");
    AudioStreamRangedDescription rd[8];
    getProp(feedStream, kAudioStreamPropertyAvailablePhysicalFormats, 0, 0, NULL, sizeof(rd), rd, &sz);
    CHECK(sz == 4 * sizeof(AudioStreamRangedDescription), "4 physical formats");

    TEST("Driver: unknown properties and invalid objects rejected");
    AudioObjectPropertyAddress bogus = { 'zzzz', 0, 0 };
    CHECK(!DRV->HasProperty(gDrv, mic, getpid(), &bogus), "unknown property");
    UInt32 dummy;
    CHECK(getProp(99, kAudioObjectPropertyName, 0, 0, NULL, 4, &dummy, NULL) != 0, "unknown object");
    UInt32 tiny = 0;
    CHECK(getProp(mic, kAudioDevicePropertyNominalSampleRate, 0, 0, NULL, 4, &tiny, NULL) == kAudioHardwareBadPropertySizeError, "size too small");

    TEST("Driver: sample rate change requested from the host for both devices");
    AudioObjectPropertyAddress rateAddr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0 };
    Boolean settable = false;
    DRV->IsPropertySettable(gDrv, mic, getpid(), &rateAddr, &settable);
    CHECK(settable, "sample rate settable");
    Float64 newRate = 44100;
    gRequests = 0;
    CHECK(DRV->SetPropertyData(gDrv, feed, getpid(), &rateAddr, 0, NULL, 8, &newRate) == 0, "SetPropertyData");
    CHECK(gRequests == 2 && gRequestActions[0] == 44100 && gRequestDevices[0] != gRequestDevices[1], "2 requests (%d)", gRequests);
    CHECK(getRate(mic) == 48000, "nothing changes before PerformDeviceConfigurationChange");
    DRV->PerformDeviceConfigurationChange(gDrv, mic, 44100, NULL);
    DRV->PerformDeviceConfigurationChange(gDrv, feed, 44100, NULL);
    CHECK(getRate(mic) == 44100 && getRate(feed) == 44100, "both at 44.1 kHz");
    Float64 badRate = 22050;
    gRequests = 0;
    CHECK(DRV->SetPropertyData(gDrv, mic, getpid(), &rateAddr, 0, NULL, 8, &badRate) == kAudioDeviceUnsupportedFormatError && gRequests == 0, "22.05 kHz rejected");
    AudioStreamBasicDescription mono = f; mono.mChannelsPerFrame = 1;
    AudioObjectPropertyAddress fmtAddr = { kAudioStreamPropertyVirtualFormat, 0, 0 };
    CHECK(DRV->SetPropertyData(gDrv, micStream, getpid(), &fmtAddr, 0, NULL, sizeof(mono), &mono) == kAudioDeviceUnsupportedFormatError, "mono format rejected (not advertised)");

    TEST("Driver: sample rate stored and restored when coreaudiod restarts");
    CFNumberRef stored = CFDictionaryGetValue(gStorage, CFSTR("NominalSampleRate"));
    Float64 sv = 0;
    CHECK(stored && CFNumberGetValue(stored, kCFNumberFloat64Type, &sv) && sv == 44100, "stored (%.0f)", sv);
    Float64 r96 = 96000;
    CFNumberRef n96 = CFNumberCreate(NULL, kCFNumberFloat64Type, &r96);
    CFDictionarySetValue(gStorage, CFSTR("NominalSampleRate"), n96);
    CFRelease(n96);
    DRV->Initialize(gDrv, hp);
    CHECK(getRate(mic) == 96000, "restored to %.0f", getRate(mic));
    DRV->PerformDeviceConfigurationChange(gDrv, mic, 48000, NULL);

    TEST("Driver: mic name settable by VoxFlowAir (UID unchanged), stored");
    AudioObjectPropertyAddress nameAddr = { 'vfnm', kAudioObjectPropertyScopeGlobal, 0 };
    DRV->IsPropertySettable(gDrv, mic, getpid(), &nameAddr, &settable);
    CHECK(settable, "mic name settable (property 'vfnm')");
    CHECK(!DRV->HasProperty(gDrv, feed, getpid(), &nameAddr), "no settable name on the source");
    AudioObjectPropertyAddress stdName = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0 };
    DRV->IsPropertySettable(gDrv, mic, getpid(), &stdName, &settable);
    CHECK(!settable, "kAudioObjectPropertyName stays read-only (the HAL does not forward it)");
    CFStringRef newName = CFSTR("  VoxFlowAir — Podcast Voice  ");
    CHECK(DRV->SetPropertyData(gDrv, mic, getpid(), &nameAddr, 0, NULL, sizeof(newName), &newName) == 0, "rename");
    CFStringRef got = NULL;
    getProp(mic, kAudioObjectPropertyName, 0, 0, NULL, sizeof(got), &got, NULL);
    CHECK(got && CFEqual(got, CFSTR("VoxFlowAir — Podcast Voice")), "name read back (whitespace trimmed)");
    if (got) CFRelease(got);
    CFStringRef uidAfter = NULL;
    getProp(mic, kAudioDevicePropertyDeviceUID, 0, 0, NULL, sizeof(uidAfter), &uidAfter, NULL);
    CHECK(uidAfter && cfEqualsC(uidAfter, kVFDriver_MicUID), "UID unchanged");
    CFStringRef storedName = CFDictionaryGetValue(gStorage, CFSTR("MicName"));
    CHECK(storedName && CFEqual(storedName, CFSTR("VoxFlowAir — Podcast Voice")), "name stored by the host");
    for (int i = 0; i < 50 && atomic_load(&gNameChanges) == 0; i++) usleep(10000);
    CHECK(atomic_load(&gNameChanges) == 1, "apps notified of the name change (%d)", atomic_load(&gNameChanges));
    CFStringRef empty = CFSTR("   ");
    CHECK(DRV->SetPropertyData(gDrv, mic, getpid(), &nameAddr, 0, NULL, sizeof(empty), &empty) != 0, "empty name rejected");
    CFStringRef tooLong = CFSTR("0123456789012345678901234567890123456789012345678901234567890123456789");
    CHECK(DRV->SetPropertyData(gDrv, mic, getpid(), &nameAddr, 0, NULL, sizeof(tooLong), &tooLong) != 0, "name longer than 63 characters rejected");
    CHECK(DRV->SetPropertyData(gDrv, feed, getpid(), &nameAddr, 0, NULL, sizeof(newName), &newName) != 0, "renaming the source rejected");
    DRV->Initialize(gDrv, hp);
    getProp(mic, kAudioObjectPropertyName, 0, 0, NULL, sizeof(got), &got, NULL);
    CHECK(got && CFEqual(got, CFSTR("VoxFlowAir — Podcast Voice")), "name restored after coreaudiod restart");
    if (got) CFRelease(got);
    CFStringRef defName = CFSTR(kVFDriver_MicName);
    DRV->SetPropertyData(gDrv, mic, getpid(), &nameAddr, 0, NULL, sizeof(defName), &defName);

    TEST("Driver: advertised I/O operations");
    Boolean will = false, inPlace = false;
    DRV->WillDoIOOperation(gDrv, mic, 0, kAudioServerPlugInIOOperationReadInput, &will, &inPlace);
    CHECK(will, "mic: read");
    DRV->WillDoIOOperation(gDrv, mic, 0, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace);
    CHECK(!will, "mic: no write");
    DRV->WillDoIOOperation(gDrv, feed, 0, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace);
    CHECK(will, "source: write");

    TEST("Driver: virtual clock monotonic and consistent with the sample rate");
    CHECK(DRV->StartIO(gDrv, mic, 1) == 0, "StartIO mic");
    CHECK(getU32(mic, kAudioDevicePropertyDeviceIsRunning, 0) == 1, "mic running");
    Float64 st0, st1; UInt64 ht0, ht1, seed0, seed1;
    DRV->GetZeroTimeStamp(gDrv, mic, 1, &st0, &ht0, &seed0);
    usleep(800000);   // > 2 periods of 16,384 frames at 48 kHz
    DRV->GetZeroTimeStamp(gDrv, feed, 1, &st1, &ht1, &seed1);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double sec = (double)(ht1 - ht0) * tb.numer / tb.denom / 1e9;
    double measuredRate = sec > 0 ? (st1 - st0) / sec : 0;
    CHECK(st1 > st0 && seed0 == seed1, "progress (%.0f → %.0f)", st0, st1);
    CHECK(fabs(measuredRate - 48000) < 1, "clock rate %.2f Hz", measuredRate);

    TEST("Driver: without VoxFlowAir, the mic produces only silence");
    float io[2 * 512];
    AudioServerPlugInIOCycleInfo cyc;
    memset(&cyc, 0, sizeof(cyc));
    for (int i = 0; i < 1024; i++) io[i] = 0.5f;
    cyc.mInputTime.mSampleTime = 1000;
    DRV->DoIOOperation(gDrv, mic, micStream, 1, kAudioServerPlugInIOOperationReadInput, 512, &cyc, io, NULL);
    CHECK(isSilent(io, 512), "silence");

    TEST("Driver: signal written to the source reads back identically on the mic");
    CHECK(DRV->StartIO(gDrv, feed, 2) == 0, "StartIO source");
    for (int k = 0; k < 8; k++) {
        fillRamp(io, 4096 + k * 512, 512);
        cyc.mOutputTime.mSampleTime = 4096 + k * 512;
        DRV->DoIOOperation(gDrv, feed, feedStream, 2, kAudioServerPlugInIOOperationWriteMix, 512, &cyc, io, NULL);
    }
    int ok = 1;
    for (int k = 0; k < 8; k++) {
        cyc.mInputTime.mSampleTime = 4096 + k * 512;
        DRV->DoIOOperation(gDrv, mic, micStream, 1, kAudioServerPlugInIOOperationReadInput, 512, &cyc, io, NULL);
        ok &= isRamp(io, 4096 + k * 512, 512);
    }
    CHECK(ok, "4096 identical frames, no offset");

    TEST("Driver: status exposed to VoxFlowAir (property 'vfst', declared to the host)");
    AudioServerPlugInCustomPropertyInfo cpi;
    getProp(mic, kAudioObjectPropertyCustomPropertyInfoList, 0, 0, NULL, sizeof(cpi), &cpi, &sz);
    AudioServerPlugInCustomPropertyInfo cpis[2];
    getProp(mic, kAudioObjectPropertyCustomPropertyInfoList, 0, 0, NULL, sizeof(cpis), cpis, &sz);
    CHECK(sz == 2 * sizeof(cpi) && cpis[0].mSelector == 'vfst' && cpis[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList
          && cpis[1].mSelector == 'vfnm' && cpis[1].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFString, "properties declared on the mic");
    getProp(feed, kAudioObjectPropertyCustomPropertyInfoList, 0, 0, NULL, sizeof(cpi), &cpi, &sz);
    CHECK(sz == sizeof(cpi) && cpi.mSelector == 'vfst', "property declared on the source");
    CFDictionaryRef st = NULL;
    getProp(mic, 'vfst', 0, 0, NULL, sizeof(st), &st, NULL);
    CHECK(st != NULL, "dictionary");
    if (st) {
        SInt64 w = 0, fc = 0;
        CFNumberGetValue(CFDictionaryGetValue(st, CFSTR("framesWritten")), kCFNumberSInt64Type, &w);
        CFNumberGetValue(CFDictionaryGetValue(st, CFSTR("feedClients")), kCFNumberSInt64Type, &fc);
        CHECK(w >= 4096 && fc == 1, "framesWritten=%lld feedClients=%lld", (long long)w, (long long)fc);
        CFRelease(st);
    }

    TEST("Driver: VoxFlowAir stopping = immediate return to silence");
    CHECK(DRV->StopIO(gDrv, feed, 2) == 0, "StopIO source");
    cyc.mInputTime.mSampleTime = 4096;
    DRV->DoIOOperation(gDrv, mic, micStream, 1, kAudioServerPlugInIOOperationReadInput, 512, &cyc, io, NULL);
    CHECK(isSilent(io, 512), "silence after stop");
    CHECK(DRV->StopIO(gDrv, mic, 1) == 0, "StopIO mic");
    CHECK(DRV->StopIO(gDrv, mic, 1) == kAudioHardwareIllegalOperationError, "extra StopIO rejected");
    CHECK(getU32(mic, kAudioDevicePropertyDeviceIsRunning, 0) == 0, "mic stopped");

    TEST("Driver: I/O restart = new clock (seed changed)");
    DRV->StartIO(gDrv, mic, 1);
    Float64 st2; UInt64 ht2, seed2;
    DRV->GetZeroTimeStamp(gDrv, mic, 1, &st2, &ht2, &seed2);
    CHECK(seed2 != seed1 && st2 == 0, "seed %llu → %llu", seed1, seed2);
    DRV->StopIO(gDrv, mic, 1);

    TEST("Driver: repeated start/stop cycles (200)");
    int errs = 0;
    for (int i = 0; i < 200; i++) {
        errs += DRV->StartIO(gDrv, feed, 3) != 0;
        errs += DRV->StartIO(gDrv, mic, 4) != 0;
        fillRamp(io, i * 512, 512);
        cyc.mOutputTime.mSampleTime = i * 512;
        DRV->DoIOOperation(gDrv, feed, feedStream, 3, kAudioServerPlugInIOOperationWriteMix, 512, &cyc, io, NULL);
        errs += DRV->StopIO(gDrv, mic, 4) != 0;
        errs += DRV->StopIO(gDrv, feed, 3) != 0;
    }
    CHECK(errs == 0, "%d errors", errs);

    (*unk)->Release(iunknown);
}

int main(int argc, const char *argv[])
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("VoxFlowAirDriverTests — driver %s\n", VFDRIVER_VERSION);
    if (argc > 3 && strcmp(argv[1], "--latency") == 0) {
        testLatency(argv[2], argv[3], argc > 4 ? (UInt32)atoi(argv[4]) : 0);
        printf("%s %d checks, %d failure(s)\n", gFailures ? "✘" : "✔", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
    if (argc > 1 && strcmp(argv[1], "--installed") == 0) {
        testInstalled(argc > 2 && strcmp(argv[2], "--loopback") == 0);
        printf("%s %d checks, %d failure(s)\n", gFailures ? "✘" : "✔", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
    testRing();
    testRingLoad();
    if (argc > 1) testDriver(argv[1]);
    else printf("(driver path not given: bundle integration tests skipped)\n");
    printf("%s %d checks, %d failure(s)\n", gFailures ? "✘" : "✔", gChecks, gFailures);
    return gFailures ? 1 : 0;
}
