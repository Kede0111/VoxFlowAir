# Virtual audio device

A macOS app cannot publish an audio device to other apps by itself: that takes a driver. VoxFlowAir
supports two:

- **BlackHole 2ch** (Existential Audio, GPL-3.0), installed separately. It is the automatic choice when
  present.
- **VoxFlowAir Micro**, VoxFlowAir's own driver (`Driver/`), optional, chosen in Settings › Audio ›
  Virtual output. It is the better choice for calls.

Installing and uninstalling either one: [INSTALLATION.md](INSTALLATION.md).

## Mechanisms available on macOS

| Mechanism | Status | Usable? |
|---|---|---|
| **AudioServerPlugIn** (user-space HAL driver, `/Library/Audio/Plug-Ins/HAL/*.driver`, loaded by `coreaudiod`) | Not deprecated in the current SDK; the model Apple recommends for virtual devices (WWDC21, session 10190) | **Yes** |
| **AudioDriverKit** (DriverKit system extension) | For hardware-backed drivers: Apple does not grant the audio DriverKit entitlement for a virtual device. Also needs a paid developer account and user approval of the extension | No |
| Kernel extensions | Deprecated; need reduced security on Apple Silicon | No |
| Core Audio taps (`AudioHardwareTapping.h`, macOS 14.2+) | Capture other processes' audio; do not create a microphone | No |
| Media Device Extension (`AudioServerPlugInRegisterMediaDeviceExtension`) | Not available on macOS | No |

Constraints of an AudioServerPlugIn (from Apple's header):

- it runs in a **sandboxed** host process: it can read only its own bundle, stores data through the host,
  and cannot call the Core Audio client API;
- installing into `/Library/Audio/Plug-Ins/HAL` needs **administrator rights**, then a restart of
  `coreaudiod` (audio stops for a few seconds) or of the Mac;
- on Apple Silicon the code must be signed; an ad hoc signature works for a driver built on the same Mac;
- distributing to other Macs needs Developer ID signing and notarization; a quarantined (downloaded)
  driver is refused by `coreaudiod` without a message;
- nothing to approve in System Settings, unlike DriverKit;
- apps that read the virtual microphone need microphone permission, as for a physical microphone.

## Options compared

| | A. Use BlackHole | B. VoxFlowAir's own driver | C. Fork BlackHole |
|---|---|---|---|
| Effort | None | A small C driver written for VoxFlowAir | Understand and maintain a large C file, follow upstream |
| Signing | Signed and notarized by its publisher | Ad hoc unless you have a Developer ID | Ad hoc, and the trademark must be removed |
| Install | Homebrew or the official `.pkg` | Bundled script, or the VoxFlowAir installer | As B |
| Maintenance | By its publisher | By this project, for each macOS release | By this project, plus upstream changes |
| License | GPL-3.0, no effect on VoxFlowAir (separate program, no shared code) | MIT, like the rest of VoxFlowAir | GPL-3.0 for the derived driver; the BlackHole name and logo may not be used for a modified version |
| What you get | A proven device, named "BlackHole 2ch" | A microphone named "VoxFlowAir Micro" (renamable), only the input visible to apps, guaranteed silence when VoxFlowAir is not running, stream state readable by VoxFlowAir, no Homebrew dependency, and no echo-canceller problem in calls | A custom name only |

**Decision: B, alongside A.** AudioServerPlugIn is the documented route, needs no entitlement, system
extension or reduced security, and the driver is small and testable outside `coreaudiod`. C would add
the maintenance of B to the GPL and trademark constraints, for a different name only. BlackHole stays
supported and remains the automatic choice when installed; if the VoxFlowAir driver misbehaves on a
Mac, uninstall it and keep BlackHole.

Using BlackHole without modifying it imposes nothing on VoxFlowAir: the two only talk through Core
Audio. BlackHole is not bundled, because shipping its binary would also mean shipping its source under
the GPL.

## The VoxFlowAir Micro driver

```
VoxFlowAir engine ── IOProc ──▶ "VoxFlowAir Source (internal)"   (output, hidden)
                                       │  shared ring indexed by sample time
                                       ▼  same virtual clock, same clock domain
                OBS, FaceTime ◀── "VoxFlowAir Micro"              (stereo input, visible)
```

| Topic | Choice |
|---|---|
| Code | `Driver/VoxFlowAirDriver/VoxFlowAirDriver.c` (AudioServerPlugIn contract), `vf_ring.c` (transport, no dependencies, tested on its own), `Driver/Shared/VoxFlowAirDriverShared.h` (identifiers shared with the app), `Sources/VoxFlowAirCore/Virtual/VoxFlowAirDriverSupport.swift` (app side) |
| Identifiers | Derived from the base bundle identifier (`VOXFLOWAIR_BUNDLE_ID`): driver `<id>.driver`, microphone UID `<id>.driver.mic`, source UID `<id>.driver.feed`. The tests check that the C header and the Swift side agree |
| Transport | A ring of 32,768 stereo Float32 frames inside the driver, written by the source's `WriteMix` at its output time and read by the microphone's `ReadInput` at its input time; one writer, one reader, no lock |
| Formats | Interleaved stereo Float32 at 44.1, 48, 88.2 or 96 kHz; any other format is refused |
| Sample rate | Shared by both devices, stored by the host and restored after a restart |
| VoxFlowAir not running | The microphone outputs silence: the ring is cleared when the source stops, and a frame is only read if it was written recently |
| Gaps, clock jumps | Gaps are filled with silence; a clock jump or reset clears the ring; old audio is never repeated |
| Audio loops | Neither device can be chosen as VoxFlowAir's input (checked by the engine and the microphone list) |
| Clock drift | The driver has its own virtual clock, independent of the physical microphone; VoxFlowAir's resampler compensates, as with BlackHole |
| Monitoring / Mute / Bypass | Unchanged: they act in the engine before the write; the driver only carries audio |
| Diagnostics | Custom property `'vfst'` (clients, frames written / read / valid, gaps, resets, sample rate, version), declared through `kAudioObjectPropertyCustomPropertyInfoList`; shown in Settings › Virtual Output. Logs under the subsystem `<id>.driver` |
| Displayed name | Custom property `'vfnm'` (CFString) on the microphone, because the HAL does not let clients set `kAudioObjectPropertyName` on a device. 1 to 63 characters, stored by the host, apps notified. The UID never changes, so apps keep their setting. Set per preset or in Settings › Audio |
| Not offered | Volume control, hardware mute, system sounds; the source is never a default output |

The app embeds the built driver at `VoxFlowAir.app/Contents/Resources/Driver/VoxFlowAirDriver.driver`,
which the install script copies to `/Library/Audio/Plug-Ins/HAL`.

## Tests

| Type | What it checks |
|---|---|
| Ring unit tests | Silence before writing, exact read-back, wraparound, gaps, reset, clock jumps, oversized blocks |
| Ring load test | Concurrent writer and reader over 60 seconds of audio at 48 kHz, blocks of 32 to 1,023 frames, continuity checked frame by frame |
| Bundle integration, without installing | The built `.driver` loaded through CFPlugIn as `coreaudiod` would, with a mock host: properties, visibility, formats, refusals, sample rate changes and persistence, clock, transport, silence without VoxFlowAir, repeated start / stop |
| App side (`VoxFlowAirCoreTests`) | Swift identifiers match the C header, loop guard, choice of the read-back device, status |
| Installed driver (`--installed`) | Publishing, visible microphone and hidden source, renaming seen by apps, sample rate changes through `coreaudiod`, writing |
| Installed driver + read-back (`--installed --loopback`) | A −20 dBFS tone written to the source and read back from "VoxFlowAir Micro"; impulses for latency |
| Latency (`--latency <feed UID> <mic UID> [buffer]`) | Transport delay between writer and reader with impulses: about two buffers |

The tests without installation do not prove that `coreaudiod` accepts the driver on a given Mac; the
installed tests do. Commands: [BUILDING.md](BUILDING.md#driver-tests-voxflowairdrivertests).

### Manual validation

1. Install the driver; the script must print that "VoxFlowAir Micro" is published.
2. Run `VoxFlowAirDriverTests --installed`: every check passes.
3. Audio MIDI Setup shows "VoxFlowAir Micro" as a 2-channel input, and no "VoxFlowAir Source".
4. Settings › Audio › Virtual output = **VoxFlowAir Micro (VoxFlowAir driver)**. The event log reports
   "Virtual output verified: signal read back as OBS would read it" with the measured delay.
5. OBS: an *Audio Input Capture* source on VoxFlowAir Micro moves when you speak. MUTE OUT gives silence in
   OBS while the headphones keep playing; BYPASS sends the unprocessed voice.
6. Quit VoxFlowAir: OBS receives silence (no hum, no repeated audio). Relaunch: audio comes back without
   touching OBS.
7. Change the sample rate in Audio MIDI Setup: VoxFlowAir reconfigures itself.
8. Sleep for a minute and wake: audio comes back in OBS.
9. Restart the Mac: "VoxFlowAir Micro" is still there, with the same sample rate.
10. FaceTime with VoxFlowAir Micro as the microphone: the other person hears the processed voice.
11. Uninstall: VoxFlowAir falls back to BlackHole if it is installed.

## Sources

- macOS SDK: `CoreAudio.framework/Headers/AudioServerPlugIn.h`
- [Create audio drivers with DriverKit, WWDC21](https://developer.apple.com/videos/play/wwdc2021/10190/)
- [AudioDriverKit Extension for Virtual Devices? (Apple Developer Forums)](https://developer.apple.com/forums/thread/682035)
- [Notarizing a user-space CoreAudio driver (Apple Developer Forums)](https://developer.apple.com/forums/thread/116003)
- [BlackHole: source code and license](https://github.com/ExistentialAudio/BlackHole)
