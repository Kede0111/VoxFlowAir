# Contributing to VoxFlowAir

Thanks for your interest in VoxFlowAir. Bug reports, plugin compatibility reports, translations and pull
requests are all welcome.

## Before you start

- For a bug, open an issue with the diagnostics report (Settings › Diagnostics › Generate Report).
- For a plugin that misbehaves, use the *Plugin compatibility* issue form.
- For a larger change (new node type, engine or driver work), open an issue first so we can agree on
  the approach before you spend time on it.

## Setting up

You need an Apple Silicon Mac with macOS 26 or later and Xcode 26 or later.

```bash
git clone https://github.com/Kede0111/VoxFlowAir.git
cd VoxFlowAir
open VoxFlowAir.xcodeproj        # scheme "VoxFlowAir", ⌘R to run, ⌘U to test
```

From the command line:

```bash
Scripts/build-xcode.sh          # app, driver and tool (Release), signed ad hoc
Scripts/build-xcode.sh --test   # also runs the engine and driver tests and writes a report
```

Build products and test reports go to `~/Library/Developer/VoxFlowAirXcode` (set `VOXFLOWAIR_DERIVED` to
change it). See [Docs/BUILDING.md](Docs/BUILDING.md) for details.

### Your own bundle identifier and signing

The default build is signed ad hoc with the identifier `be.jackfrom.voxflowair`. To run your build next to
an installed VoxFlowAir, or to sign with your own team:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # ignored by git
```

and set `VOXFLOWAIR_BUNDLE_ID`, `VOXFLOWAIR_DEVELOPMENT_TEAM` or `VOXFLOWAIR_CODE_SIGN_IDENTITY` there. The driver,
its device UIDs and the log subsystem follow the bundle identifier.

## Project layout

| Path | Contents |
|---|---|
| `Sources/VoxFlowAirCore` | Engine, devices, processing graph, Audio Unit hosting, presets, settings. No UI, fully testable. |
| `Sources/VoxFlowAir` | SwiftUI app: main window, node editor, inspector, settings, menu bar. |
| `Sources/VFObjC` | Small Objective-C helpers (exception catching, Cocoa views of AUv2 plugins). |
| `Sources/VoxFlowAirTool` | Developer command-line tool: plugin audits, offline chain rendering. |
| `Driver/` | “VoxFlowAir Micro” virtual audio device (AudioServerPlugIn, C) and its tests. |
| `Tests/VoxFlowAirCoreTests` | Engine tests (Swift Testing), run without audio hardware. |
| `Resources/` | Info.plist, entitlements, icon, string catalogs, helper scripts bundled in the app. |
| `Config/` | Shared build settings (`VoxFlowAir.xcconfig`). |

[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) explains how audio flows through the app.

## Guidelines

- **Real-time audio thread.** Code that runs in the render callback must not allocate, lock, log, or
  call Objective-C/Swift runtime features that may do so. Pass data with the existing lock-free
  structures (`SPSCRingBuffer`, `DriftRing`, `RTAtomics`).
- **Match the surrounding code.** Naming, comment density and idioms should look like the file you are
  editing. Code, comments and logs are in English.
- **User-facing text is localized.** SwiftUI literals (`Text("…")`, `Button("…")`) are picked up
  automatically; other strings shown to the user use `String(localized:)`. Add the French translation in
  `Resources/Localizable.xcstrings` (Xcode's string catalog editor does this nicely). Logs and the
  diagnostics report are not localized.
- **Settings and presets stay readable.** Settings and `.voxpreset` files decode tolerantly; new keys need
  defaults, and existing keys or raw values must not be renamed.
- **Tests.** Add tests in `Tests/VoxFlowAirCoreTests` for engine, graph and preset changes. Tests must run
  without a microphone or audio interface; hardware tests are gated behind `VOXFLOWAIR_HW=1`.
- **The driver** runs inside `coreaudiod`. Keep it small, allocation-free on the I/O path, and run the
  driver tests (`Scripts/build-xcode.sh --test`) before submitting.

## Pull requests

- One topic per pull request, with a description of what a user would notice (before / after).
- `Scripts/build-xcode.sh --test` passes locally; CI runs the same build and tests.
- Commit messages: a short imperative summary line, then the why if it is not obvious.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
