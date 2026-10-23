// Tests of the INSTALLED driver, through the real Core Audio service (coreaudiod).
//
//   --installed            publishing, properties, sample rates, writing to the source
//   --installed --loopback also reads back from "VoxFlowAir Micro": requires microphone access
//                          for the app running the test (Terminal), as for OBS.

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "VoxFlowAirDriverShared.h"

extern int gFailures, gChecks;
#define ICHECK(cond, ...) do { gChecks++; if (!(cond)) { gFailures++; printf("    ✘ "); printf(__VA_ARGS__); printf("\n"); } else { printf("    ✔ "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static AudioObjectID translateUID(const char *uid)
{
    CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(s), &s, &size, &id);
    CFRelease(s);
    return id;
}

static UInt32 u32(AudioObjectID o, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc)
{
    AudioObjectPropertyAddress a = { sel, sc, kAudioObjectPropertyElementMain };
    UInt32 v = 0xFFFFFFFF, size = 4;
    AudioObjectGetPropertyData(o, &a, 0, NULL, &size, &v);
    return v;
}

static Float64 rate(AudioObjectID o)
{
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 v = 0; UInt32 size = 8;
    AudioObjectGetPropertyData(o, &a, 0, NULL, &size, &v);
    return v;
}

static OSStatus setRate(AudioObjectID o, Float64 r)
{
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    return AudioObjectSetPropertyData(o, &a, 0, NULL, sizeof(r), &r);
}

static int inDeviceList(AudioObjectID id)
{
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    AudioObjectID ids[256];
    if (size > sizeof(ids)) size = sizeof(ids);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids);
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) if (ids[i] == id) return 1;
    return 0;
}

static SInt64 stateValue(AudioObjectID mic, CFStringRef key)
{
    AudioObjectPropertyAddress a = { 'vfst', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDictionaryRef d = NULL; UInt32 size = sizeof(d);
    if (AudioObjectGetPropertyData(mic, &a, 0, NULL, &size, &d) != 0 || !d) return -1;
    SInt64 v = -1;
    CFNumberRef n = CFDictionaryGetValue(d, key);
    if (n) CFNumberGetValue(n, kCFNumberSInt64Type, &v);
    CFRelease(d);
    return v;
}

// --- I/O: 1 kHz -20 dBFS tone written to the source, read back from the mic.
static _Atomic UInt64 gOutFrames, gInFrames, gInNonZero;
static _Atomic float gInPeak;
static double gPhase;
static Float64 gRate;
// Latency measurement: impulses written to the source, detected on the mic (host time).
static int gImpulseMode = 0;
static UInt64 gFramesSinceImpulse = 0;
static double gTicksPerFrame = 0;
static _Atomic UInt64 gEmitHost = 0, gEmitCall = 0;
static double gHandoff[64];
static double gLatencies[64];
static _Atomic int gLatencyCount = 0;

static OSStatus feedProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                         AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx)
{
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        float *p = out->mBuffers[b].mData;
        UInt32 ch = out->mBuffers[b].mNumberChannels, n = out->mBuffers[b].mDataByteSize / (4 * ch);
        for (UInt32 i = 0; i < n; i++) {
            float s;
            if (gImpulseMode) {
                // One impulse every 0.25 s; its presentation time is recorded.
                s = 0;
                if (++gFramesSinceImpulse >= (UInt64)(gRate / 4)) {
                    gFramesSinceImpulse = 0; s = 0.9f;
                    atomic_store(&gEmitCall, now->mHostTime);
                    atomic_store(&gEmitHost, outTime->mHostTime + (UInt64)(i * gTicksPerFrame));
                }
            } else {
                s = 0.1f * (float)sin(gPhase);
                gPhase += 2 * M_PI * 1000.0 / gRate;
            }
            for (UInt32 c = 0; c < ch; c++) p[i * ch + c] = s;
        }
        atomic_fetch_add(&gOutFrames, n);
    }
    return 0;
}

static OSStatus micProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                        AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx)
{
    for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
        const float *p = in->mBuffers[b].mData;
        UInt32 ch = in->mBuffers[b].mNumberChannels, n = in->mBuffers[b].mDataByteSize / (4 * ch);
        float pk = atomic_load(&gInPeak);
        UInt64 nz = 0;
        for (UInt32 i = 0; i < n * ch; i++) { float a = fabsf(p[i]); if (a > pk) pk = a; if (a > 1e-6f) nz++; }
        if (gImpulseMode) {
            for (UInt32 i = 0; i < n; i++) if (p[i * ch] > 0.5f) {
                UInt64 emit = atomic_exchange(&gEmitHost, 0), emitCall = atomic_load(&gEmitCall);
                int k = atomic_load(&gLatencyCount);
                if (emit && k < 64) {
                    UInt64 seen = inTime->mHostTime + (UInt64)(i * gTicksPerFrame);
                    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
                    gLatencies[k] = ((double)seen - (double)emit) * tb.numer / tb.denom / 1e6;
                    gHandoff[k] = ((double)now->mHostTime - (double)emitCall) * tb.numer / tb.denom / 1e6;
                    atomic_store(&gLatencyCount, k + 1);
                }
            }
        }
        atomic_store(&gInPeak, pk);
        atomic_fetch_add(&gInNonZero, nz);
        atomic_fetch_add(&gInFrames, n);
    }
    return 0;
}

// Latency measured with impulses between an output and the input that reads it back.
// bufferFrames > 0: forces this buffer size on both clients (like VoxFlowAir).
static void measureLatency(AudioObjectID feed, AudioObjectID mic, UInt32 bufferFrames)
{
    AudioDeviceIOProcID fp = NULL, mp = NULL;
    UInt64 out = atomic_load(&gOutFrames);
    gRate = rate(feed);
    atomic_store(&gLatencyCount, 0); gFramesSinceImpulse = 0; atomic_store(&gEmitHost, 0);
    if (bufferFrames) {
        AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectSetPropertyData(feed, &a, 0, NULL, 4, &bufferFrames);
        AudioObjectSetPropertyData(mic, &a, 0, NULL, 4, &bufferFrames);
    }
        printf("◇ Installed driver: source → mic transport latency (impulses, 3 s)\n");
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        gTicksPerFrame = 1e9 / gRate * tb.denom / tb.numer;
        gImpulseMode = 1;
        atomic_store(&gInPeak, 0); atomic_store(&gInFrames, 0);
        AudioDeviceCreateIOProcID(feed, feedProc, NULL, &fp); AudioDeviceCreateIOProcID(mic, micProc, NULL, &mp);
        AudioDeviceStart(mic, mp); AudioDeviceStart(feed, fp);
        sleep(3);
        AudioDeviceStop(feed, fp); AudioDeviceStop(mic, mp);
        AudioDeviceDestroyIOProcID(feed, fp); AudioDeviceDestroyIOProcID(mic, mp);
        int k = atomic_load(&gLatencyCount);
        printf("    (diagnostics: %llu frames written, %llu read, peak %.3f)\n", atomic_load(&gOutFrames) - out, atomic_load(&gInFrames), atomic_load(&gInPeak));
        double lo = 1e9, hi = -1e9, sum = 0;
        for (int i = 0; i < k; i++) { sum += gLatencies[i]; if (gLatencies[i] < lo) lo = gLatencies[i]; if (gLatencies[i] > hi) hi = gLatencies[i]; }
        ICHECK(k >= 8, "%d impulses found on the mic", k);
        if (k) {
            printf("    timestamp offset (frame presentation → capture of the same frame): mean %.2f ms, min %.2f, max %.2f\n", sum / k, lo, hi);
            double hs = 0, hlo = 1e9, hhi = -1e9;
            for (int i = 0; i < k; i++) { hs += gHandoff[i]; if (gHandoff[i] < hlo) hlo = gHandoff[i]; if (gHandoff[i] > hhi) hhi = gHandoff[i]; }
            printf("    actual transfer latency (writer call → call of the reader that gets the impulse): mean %.2f ms, min %.2f, max %.2f, at %.0f Hz\n", hs / k, hlo, hhi, gRate);
        }
        UInt32 bufOut = u32(feed, kAudioDevicePropertyBufferFrameSize, 0), bufIn = u32(mic, kAudioDevicePropertyBufferFrameSize, 0);
        printf("    buffers: source %u frames, mic %u frames\n", bufOut, bufIn);
    }

int testInstalled(int loopback)
{
    printf("◇ Installed driver: published by Core Audio\n");
    AudioObjectID mic = translateUID(kVFDriver_MicUID), feed = translateUID(kVFDriver_FeedUID);
    ICHECK(mic != kAudioObjectUnknown, "\"%s\" published (id %u)", kVFDriver_MicName, mic);
    ICHECK(feed != kAudioObjectUnknown, "internal source published (id %u)", feed);
    if (mic == kAudioObjectUnknown || feed == kAudioObjectUnknown) {
        printf("    The driver is not loaded. Check /Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver, then restart coreaudiod.\n");
        return 1;
    }
    ICHECK(inDeviceList(mic), "mic present in the device list (visible to apps)");
    ICHECK(!inDeviceList(feed), "source absent from the list (hidden)");
    ICHECK(u32(feed, kAudioDevicePropertyIsHidden, 0) == 1, "source: IsHidden = 1");
    ICHECK(u32(mic, kAudioDevicePropertyDeviceIsAlive, 0) == 1, "mic alive");
    ICHECK(u32(mic, kAudioDevicePropertyTransportType, 0) == kAudioDeviceTransportTypeVirtual, "virtual transport");
    ICHECK(stateValue(mic, CFSTR("framesWritten")) >= 0, "internal status readable (property 'vfst')");

    printf("◇ Installed driver: renaming the mic through coreaudiod\n");
    {
        AudioObjectPropertyAddress vfnm = { 'vfnm', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectPropertyAddress nm = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFStringRef before = NULL, after = NULL; UInt32 sz = sizeof(CFStringRef);
        AudioObjectGetPropertyData(mic, &nm, 0, NULL, &sz, &before);
        CFStringRef test = CFSTR("VoxFlowAir Micro — test");
        OSStatus st = AudioObjectSetPropertyData(mic, &vfnm, 0, NULL, sizeof(test), &test);
        usleep(300000);
        sz = sizeof(CFStringRef);
        AudioObjectGetPropertyData(mic, &nm, 0, NULL, &sz, &after);
        ICHECK(st == 0 && after && CFEqual(after, test), "name visible to apps after renaming (status %d)", (int)st);
        ICHECK(translateUID(kVFDriver_MicUID) == mic, "UID unchanged");
        if (before) { AudioObjectSetPropertyData(mic, &vfnm, 0, NULL, sizeof(before), &before); CFRelease(before); }
        if (after) CFRelease(after);
    }
    printf("◇ Installed driver: sample rate change (both devices follow)\n");
    Float64 initial = rate(mic);
    Float64 target = initial == 44100 ? 48000 : 44100;
    OSStatus st = setRate(mic, target);
    for (int i = 0; i < 40 && rate(feed) != target; i++) usleep(50000);
    ICHECK(st == 0 && rate(mic) == target && rate(feed) == target, "%.0f → %.0f Hz (mic %.0f, source %.0f)", initial, target, rate(mic), rate(feed));
    ICHECK(setRate(mic, 22050) != 0, "22.05 kHz rejected");
    setRate(mic, initial);
    for (int i = 0; i < 40 && rate(feed) != initial; i++) usleep(50000);
    ICHECK(rate(mic) == initial && rate(feed) == initial, "back to %.0f Hz", initial);

    printf("◇ Installed driver: writing to the source for 2 s%s\n", loopback ? " and reading back from the mic" : "");
    gRate = rate(feed);
    SInt64 w0 = stateValue(mic, CFSTR("framesWritten")), v0 = stateValue(mic, CFSTR("framesValid"));
    AudioDeviceIOProcID fp = NULL, mp = NULL;
    ICHECK(AudioDeviceCreateIOProcID(feed, feedProc, NULL, &fp) == 0 && AudioDeviceStart(feed, fp) == 0, "IOProc on the source started");
    if (loopback) ICHECK(AudioDeviceCreateIOProcID(mic, micProc, NULL, &mp) == 0 && AudioDeviceStart(mic, mp) == 0, "IOProc on the mic started");
    sleep(2);
    if (mp) { AudioDeviceStop(mic, mp); AudioDeviceDestroyIOProcID(mic, mp); }
    AudioDeviceStop(feed, fp); AudioDeviceDestroyIOProcID(feed, fp);
    SInt64 w1 = stateValue(mic, CFSTR("framesWritten")), v1 = stateValue(mic, CFSTR("framesValid"));
    UInt64 out = atomic_load(&gOutFrames);
    ICHECK(out > gRate * 1.5, "%llu frames produced", out);
    ICHECK(w1 - w0 > gRate * 1.5, "the driver received %lld frames", (long long)(w1 - w0));
    if (loopback) {
        UInt64 inF = atomic_load(&gInFrames);
        float pk = atomic_load(&gInPeak);
        ICHECK(inF > gRate * 1.5, "%llu frames read from the mic", inF);
        ICHECK(fabsf(pk - 0.1f) < 0.005f, "peak read back %.4f (written 0.1000 = -20 dBFS)", pk);
        ICHECK(v1 - v0 > gRate * 1.0, "%lld valid frames read back", (long long)(v1 - v0));
        if (inF > 0 && atomic_load(&gInNonZero) == 0)
            printf("    (total silence: microphone access is probably denied for this app)\n");
    }
    if (loopback) measureLatency(feed, mic, 0);
    usleep(200000);
    ICHECK(u32(feed, kAudioDevicePropertyDeviceIsRunning, 0) == 0, "source stopped after the test");
    return 0;
}

// Comparison under the same conditions: VoxFlowAirDriverTests --latency <output UID> <input UID> [buffer]
int testLatency(const char *feedUID, const char *micUID, UInt32 buffer)
{
    AudioObjectID feed = translateUID(feedUID), mic = translateUID(micUID);
    ICHECK(feed && mic, "devices %s → %s", feedUID, micUID);
    if (!feed || !mic) return 1;
    measureLatency(feed, mic, buffer);
    return 0;
}
