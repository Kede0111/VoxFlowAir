# Architecture

This page explains how audio flows through VoxFlowAir and why it is built this way. For the virtual
device itself, see [VIRTUAL-DEVICE.md](VIRTUAL-DEVICE.md).

## Overview

```
 ┌── private aggregate device (clock = microphone) ─────────────────┐
 │ Core Audio IOProc ─▶ RealtimeProcessor                           │
 │   input gain → AVAudioEngine (manual rendering = the graph)      │
 │   → bypass (crossfade) → monitoring (on/off + gain) → headphones │
 │                        ↖ call return (BlackHole → headphones)    │
 │   → virtual output (gain + mute) ──┐                             │
 └────────────────────────────────────┼─────────────────────────────┘
                                      ▼ lock-free ring (DriftRing)
               own IOProc on the virtual device (cubic resampler, drift correction ±0.5 %)
                                      ▼
            BlackHole 2ch or VoxFlowAir Micro ─▶ OBS / FaceTime / …
                                      ▲ read back continuously by a verification probe
```

## Engine

- **Private aggregate device** (`AudioHardwareCreateAggregateDevice`, private key): groups the microphone
  and the headphones under the microphone's clock, with drift correction on the headphones. It is
  invisible to other apps, needs no administrator rights and disappears with the process.
- **Direct IOProc** (`AudioDeviceCreateIOProcIDWithBlock`): one callback receives every stream's buffers;
  channels are read and written at their exact positions.
- **Virtual output outside the aggregate.** On macOS 27, a signal written to BlackHole *through an
  aggregate device* did not reach other apps, while a direct write did (checked by reading the device
  back). VoxFlowAir therefore writes the virtual device with its own IOProc (`VirtualOutputWriter`), fed by
  a lock-free ring. A cubic resampler continuously adjusts the read rate (±0.5 % at most) to absorb the
  drift between the microphone's clock and the virtual device's clock. The ring's target fill is one
  producer block plus one consumer block plus 64 frames (at least 448 frames), raised by 32 frames after
  each underrun, up to 2048.
- **Verification probe** (`LoopbackProbe`): a second, input-only AUHAL unit opens the virtual device's
  input exactly as OBS would (for VoxFlowAir Micro, the "VoxFlowAir Micro" input) and compares what it
  reads with what VoxFlowAir wrote: level difference and delay by cross-correlation. The result appears
  in the event log and the menu bar panel ("Signal read back from the virtual output", or "no return").
- **The graph runs in AVAudioEngine's real-time manual rendering mode**
  (`enableManualRenderingMode(.realtime)`): the render block is called from the IOProc. Each logical node
  becomes `input mixer (sums its inputs, adapts mono/stereo) → plugin → native meter node`, so branches
  (one output to several inputs) and merges really run. Loops are refused (no feedback).
- **Native nodes** (Gain, Analyzer, monitoring tap, meters) are Audio Units v3 registered only inside the
  VoxFlowAir process (`VFUtilityAudioUnit`), so they plug into AVAudioEngine like any plugin.
- **Real-time rules**: no allocation, lock, disk access or logging in the callback. Values shared with the
  UI use `Synchronization.Atomic` and the lock-free types in `RTAtomics`, `SPSCRingBuffer` and
  `DriftRing`; buffers are preallocated; meters and analyzers are read by the UI at 30 Hz, with peaks
  held on the audio side.
- **Reconfiguration**: a structural change closes a "gate" (the audio thread outputs a short transition
  silence, without waiting), rebuilds the connections, then reopens with a fade. Bypass and gains
  rebuild nothing (per-sample ramps).
- **Bypass Processing**: crossfade to the input signal after input gain. Plugins keep running for an
  instant return. With loudness matching, the raw signal is corrected by the loudness difference
  measured between the processed output and the input while you speak (clamped to ±24 dB). The dry
  signal is not delayed to match the plugins' latency.
- **Mute Output** only affects the virtual output. **Monitoring** has its own gain and can listen to any
  point of the chain through the monitoring output node.
- **Call return** (`CallReturnReader`): when BlackHole exists and is neither the virtual output nor the
  input, VoxFlowAir reads what other apps play into it and mixes it into the headphones only, through a
  second `DriftRing`.
- **Watching other audio apps**: every 2 seconds, VoxFlowAir lists Core Audio's process objects
  (`kAudioHardwarePropertyProcessObjectList`, macOS 14.2+). It pauses monitoring while an app reads the
  virtual microphone and plays on the monitoring headphones, warns when a known call app reads BlackHole,
  and names apps that capture other apps' audio when the virtual output's signal does not come back.
  See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#calls-facetime-zoom-and-echo-cancellers).
- **Supervision**: Core Audio overloads (`kAudioDeviceProcessorOverload`), cycles using more than 90 % of
  the available time, render errors, NaN / infinite samples (neutralized), clipping per measurement
  point; a watchdog restarts the engine when no cycle ran for 3 seconds; device, sample rate and
  aggregate composition changes trigger an automatic reset. More than 5 automatic restarts in 30
  seconds stop the engine.
- **Latency** is estimated from the device latencies and safety offsets, twice the buffer, the virtual
  output ring and the latencies reported by plugins. It is always shown as an estimate.
- **Buffer profiles**: 64 / 128 / 256 (default) / 512 / 1024 samples, limited to the device's range.

## Audio Unit hosting

- **Discovery**: `AVAudioUnitComponentManager`, effect (`aufx`) and music effect (`aumf`) types. The
  category comes from the plugin's tags, or from keywords in its name for plugins that publish none.
  Multichannel variants are hidden by default. The library filter (`PluginFilter`) then applies the
  user's allowlist, hidden plugins, AUv3 / aumf switches and category overrides.
- **Instantiation**: `AVAudioUnit.instantiate`, either **out of process** (`.loadOutOfProcess`, the macOS
  AUHostingService; the default) or **in process**. If isolated loading fails, VoxFlowAir retries in
  process.
- **Crashes**: out of process, a plugin crash raises `kAudioComponentInstanceInvalidationNotification`:
  VoxFlowAir bypasses the node and offers **Reload**. In process, a plugin crash quits VoxFlowAir: a
  session lock file detects the abnormal end at the next launch, and **safe mode** (Option at launch)
  starts without loading plugins.
- **Formats**: stereo if the plugin accepts it, otherwise mono (with −3 dB compensation of the
  constant-power stereo-to-mono downmix) or mono-to-stereo, based on `channelCapabilities`.
- **Interface**: `requestViewController` (AUv3 and bridged AUv2), then the AUv2 Cocoa view
  (`kAudioUnitProperty_CocoaUI`), otherwise a generic interface built from the parameters.
- **State**: `fullState` is serialized as a binary property list in the preset. The state of a missing or
  failed plugin is kept as is.

## Data

| Data | Location | Robustness |
|---|---|---|
| Settings | `~/Library/Application Support/VoxFlowAir/settings.json` | Atomic write + `.bak`; missing keys take their defaults; an unreadable file is set aside |
| Presets | `…/VoxFlowAir/Presets/<uuid>.voxpreset` (JSON, `formatVersion`) | Atomic write + `.bak`, read back before writing, unreadable files moved to a quarantine subfolder, deletion to the Trash |
| Unsaved session | `…/VoxFlowAir/session.json` | Restored at the next launch |
| Comparison recordings | `…/VoxFlowAir/Recordings/` | 32-bit float WAV |
| Logs | `~/Library/Logs/VoxFlowAir/VoxFlowAir.log`, and Console.app (subsystem = the bundle identifier) | Rotated at 5 MB |

Settings and preset files decode tolerantly so that old files keep working.

## Interface

Native SwiftUI for macOS 26 (Liquid Glass): a `NavigationSplitView` with the plugin library as sidebar,
the node editor as detail and a system inspector; a toolbar; the bottom panel and status bar; a
`MenuBarExtra` panel; a separate Meter Monitors window; Settings. Glass is used for controls; the canvas,
nodes, meters and dense text stay on opaque backgrounds. Dark appearance by default, light or matching
macOS. Closing the main window keeps the engine running: the app becomes an accessory app with its
menu bar icon. Open at login uses `SMAppService.mainApp`.

## Source tree

```
Sources/VoxFlowAirCore/   Analysis/ Devices/ Diagnostics/ Engine/ Graph/ Monitoring/ Nodes/ Plugins/
                          Presets/ Settings/ Util/ Virtual/
Sources/VoxFlowAir/       VoxFlowAirApp.swift, Views/, Editor/, MenuBar/, Support/
Sources/VFObjC/           NSException catching, AUv2 Cocoa views
Sources/VoxFlowAirTool/   developer command-line tool
Driver/                   VoxFlowAir Micro driver (C), shared header, driver tests
Tests/VoxFlowAirCoreTests/ engine tests (Swift Testing)
Resources/                Info.plist, entitlements, icon, string catalogs, bundled helper scripts
Scripts/                  build-xcode, install, uninstall, make-installer, make-icon
Config/                   VoxFlowAir.xcconfig, Local.xcconfig.example
```
