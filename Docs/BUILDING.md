# Building, testing and releasing

The Xcode project `VoxFlowAir.xcodeproj` is the only build system. You need an Apple Silicon Mac with
macOS 26 or later and Xcode 26 or later.

## Xcode project

Open `VoxFlowAir.xcodeproj`, pick the **VoxFlowAir** scheme, then ⌘B (build), ⌘R (run) or ⌘U (tests).

| Target | Type | Contents |
|---|---|---|
| `VoxFlowAir` | App (arm64) | `Sources/VoxFlowAir` (SwiftUI) and `Resources/`; embeds the driver in `Contents/Resources/Driver/` |
| `VoxFlowAirCore` | Static framework (Swift) | `Sources/VoxFlowAirCore`: engine, devices, graph, plugin hosting, presets, settings |
| `VFObjC` | Static framework (Objective-C) | `Sources/VFObjC`: exception catching, Cocoa views of AUv2 plugins |
| `VoxFlowAirCoreTests` | Unit tests (Swift Testing) | `Tests/VoxFlowAirCoreTests` |
| `VoxFlowAirDriver` | `.driver` bundle (C, AudioServerPlugIn; arm64 + x86_64) | `Driver/VoxFlowAirDriver`, `Driver/Shared` |
| `VoxFlowAirDriverTests` | Command-line tool (C) | `Driver/Tests`: loads the built driver with a mock host |
| `VoxFlowAirTool` | Command-line tool | `Sources/VoxFlowAirTool`: plugin audits, offline chain rendering (development only) |

Shared schemes:

- **VoxFlowAir**: the app; ⌘U runs `VoxFlowAirCoreTests`.
- **VoxFlowAirDriver**: the driver and its test tool; ⌘R runs `VoxFlowAirDriverTests` on the driver just
  built.
- **VoxFlowAirTool**: the developer tool (`VoxFlowAirTool find <word>`, `audit`, `params`, `probe`,
  `analyze`, `solo`, `compare`, `build-spec`; see the header of `Sources/VoxFlowAirTool/main.swift`).

The frameworks are static, so the app is a single executable. The project uses synchronized folders:
a file added under `Sources/…`, `Driver/…` or `Tests/…` is compiled by the matching target without editing
the project. `Resources/Info.plist`, `Resources/VoxFlowAir.entitlements` and the driver's `Info.plist`
are excluded from the copied resources.

Settings worth knowing: deployment target macOS 26.0; app sandbox off (the app creates a private
aggregate device and can host third-party Audio Units in its own process), with the `audio-input`
entitlement; Hardened Runtime off in the project (see [signing](#signing-and-notarization-maintainers));
warnings are errors in the driver, which runs inside `coreaudiod`.

## Command line: `Scripts/build-xcode.sh`

```bash
Scripts/build-xcode.sh            # Release: driver + driver tests, app, tool
Scripts/build-xcode.sh --debug    # Debug configuration
Scripts/build-xcode.sh --test     # also runs the tests and writes a report
```

The script builds the VoxFlowAirDriver, VoxFlowAir and VoxFlowAirTool schemes, copies the app to
`dist/VoxFlowAir.app` and checks its signature (`codesign --verify --strict --deep`). It prints only
errors, warnings and the result.

| Variable | Default | Use |
|---|---|---|
| `VOXFLOWAIR_DERIVED` | `~/Library/Developer/VoxFlowAirXcode` | DerivedData, `dist/`, `test-reports/` and `installer/` (also read by `install.sh` and `make-installer.sh`) |

Products stay outside the source tree, which also avoids code-signing problems on file systems that
add `._*` files (exFAT, network shares).

## Build configuration: `Config/VoxFlowAir.xcconfig`

Every target uses `Config/VoxFlowAir.xcconfig`:

| Setting | Default | Meaning |
|---|---|---|
| `VOXFLOWAIR_BUNDLE_ID` | `be.jackfrom.voxflowair` | App identifier. The driver (`<id>.driver`), its device UIDs (`<id>.driver.mic`, `<id>.driver.feed`), the private aggregate device and the log subsystem derive from it |
| `VOXFLOWAIR_DEVELOPMENT_TEAM` | empty | Your Apple team ID |
| `VOXFLOWAIR_CODE_SIGN_IDENTITY` | `-` | `-` signs ad hoc (no Apple account needed); set `Developer ID Application` to distribute |
| `VOXFLOWAIR_CODE_SIGN_STYLE` | `Manual` | |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `1.0.0` / `1` | Version and build number, read by the app's and the driver's `Info.plist` and compiled into the driver |

To override them without touching tracked files:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # ignored by git
```

then set the values there. With a different `VOXFLOWAIR_BUNDLE_ID`, your build gets its own settings
identity, microphone permission and driver, and can live next to another VoxFlowAir install. The base
identifier reaches the driver as the `VF_BUNDLE_ID` preprocessor definition; the app publishes it in its
Info.plist (`VoxFlowAirBundleID`).

The **Source Code** and **Support VoxFlowAir** buttons of Settings › About read `VoxFlowAirRepositoryURL`
and `VoxFlowAirDonationURL` in `Resources/Info.plist`; an empty value hides the button.

## Tests

### Engine tests (`VoxFlowAirCoreTests`)

Swift Testing, run with ⌘U, `Scripts/build-xcode.sh --test`, or:

```bash
xcodebuild -project VoxFlowAir.xcodeproj -scheme VoxFlowAir test
```

They need no microphone or audio interface: audio is rendered offline through the real
`RealtimeProcessor` and AVAudioEngine in manual rendering mode, and files go to temporary folders
(`VOXFLOWAIR_SUPPORT_DIR` keeps tests apart from your real data). Suites cover the real-time engine
(gains, bypass, mute, monitoring, clipping, branches, hot reconfiguration), engine robustness (missing
plugins, load errors, missing devices), the node editor's chain edits, presets and persistence (round
trips, `.bak` recovery, quarantine, future format versions), the graph model and validator, analysis
(BS.1770 loudness, FFT, correlation), the drift-compensating buffer, the plugin library filter, the call
and capture policies, and the driver identifiers on the app side.

Some suites use what is installed on the Mac: *Installed AU plugins* loads Apple's AUDelay and AUNBandEQ
(and a few third-party plugins when present), in process and out of process; *Meter monitors* skips its
checks when no known meter plugin is installed.

### Hardware tests (`VOXFLOWAIR_HW=1`)

Two suites run only when `VOXFLOWAIR_HW=1`: *Real hardware* (the engine on your real devices, with
monitoring off) and *Call return (hardware)* (writes a tone into BlackHole for 2 seconds). They need
microphone access for the process that runs them.

```bash
TEST_RUNNER_VOXFLOWAIR_HW=1 xcodebuild -project VoxFlowAir.xcodeproj -scheme VoxFlowAir test
```

(`xcodebuild` passes `TEST_RUNNER_`-prefixed variables to the tests without the prefix.) In Xcode, add
`VOXFLOWAIR_HW = 1` under Edit Scheme › Test › Arguments › Environment Variables.

### Driver tests (`VoxFlowAirDriverTests`)

```bash
P=~/Library/Developer/VoxFlowAirXcode/Build/Products/Release
"$P/VoxFlowAirDriverTests" "$P/VoxFlowAirDriver.driver"     # without installing the driver
"$P/VoxFlowAirDriverTests" --installed                      # installed driver, through coreaudiod
"$P/VoxFlowAirDriverTests" --installed --loopback           # also reads back from "VoxFlowAir Micro"
"$P/VoxFlowAirDriverTests" --latency <feed UID> <mic UID> [buffer]
```

- Without arguments, only the ring buffer tests run (continuity, gaps, wraparound, reset, a 60-second
  concurrent load test). With the driver's path, the bundle is loaded through CFPlugIn as `coreaudiod`
  would, with a mock host: properties, visibility, formats, refusals, sample rate changes and their
  persistence, clock, transport, silence when VoxFlowAir is not writing, repeated start / stop.
- `--installed` checks the real installed driver: publishing, visible microphone and hidden source,
  renaming, sample rates, writing. `--loopback` also writes a tone to the source and reads it back from
  "VoxFlowAir Micro"; it needs microphone access for Terminal.
- `--latency` measures the transport delay between the two devices with impulses.

`Scripts/build-xcode.sh --test` runs the engine tests and the driver tests without installation, plus
`--installed` when the driver is installed, and writes the report to
`$VOXFLOWAIR_DERIVED/test-reports/xcode-<date>.txt`.

### Manual checks

Automated tests do not cover a receiving app, the headphones, the interface or plugin interfaces. Before
a release, check by hand: microphone permission, monitoring on and off, the virtual output in OBS
(an *Audio Input Capture* source on BlackHole 2ch or VoxFlowAir Micro), MUTE OUT (silence in OBS,
headphones still on), BYPASS (no click), a plugin interface and its state after relaunch, parallel
branches, closing the main window (audio continues), unplugging the headphones, sleep and wake, a
FaceTime call, and a long session with the Dropouts and Render errors counters at zero.

### Developer hooks

These environment variables are for development only:

| Variable | Effect |
|---|---|
| `VOXFLOWAIR_SUPPORT_DIR=<folder>` | Data and logs in that folder instead of Application Support |
| `VOXFLOWAIR_SNAPSHOT=<file.png>` | Renders the main window to a PNG without starting audio, then quits (`VOXFLOWAIR_SNAPSHOT_LIGHT=1` for the light appearance) |
| `VOXFLOWAIR_UITEST_EDITOR=<folder>` | Runs the node editor gesture test with real mouse events and writes a report there; use it with a copy of your data in `VOXFLOWAIR_SUPPORT_DIR` |
| `VOXFLOWAIR_DIAG_TONE=1` | Writes a 440 Hz, −30 dBFS tone directly to the virtual device |

The app also has a local control channel for automated stability tests, off unless the file
`~/Library/Application Support/VoxFlowAir/control/ENABLED` exists (see `LocalControl.swift`).

## Installer: `Scripts/make-installer.sh`

```bash
Scripts/build-xcode.sh --test
Scripts/make-installer.sh [output folder]     # default: $VOXFLOWAIR_DERIVED/installer
```

It takes `dist/VoxFlowAir.app` and produces:

| File | Contents |
|---|---|
| `VoxFlowAir-<version>.pkg` | Installs VoxFlowAir.app into `/Applications` and, checked by default (Customize to uncheck it), the VoxFlowAir Micro driver into `/Library/Audio/Plug-Ins/HAL`. Quits a running VoxFlowAir first, restarts `coreaudiod` after installing the driver. Apple Silicon and macOS 26 or later only |
| `VoxFlowAir-<version>.dmg` | The `.pkg`, *Uninstall VoxFlowAir.command*, *Uninstall VoxFlowAir Micro.command* and a *Read Me.txt* |

BlackHole is not included: the app offers to install it. Installing a newer package keeps presets and
settings. The packages are not relocatable, so Installer always writes to `/Applications` even if
another copy of the app exists elsewhere on disk.

With ad hoc signing, the package works on the Mac that built it. On another Mac, a downloaded copy is
quarantined and blocked until the user clicks **Open Anyway** in System Settings › Privacy & Security;
whether `coreaudiod` loads an ad hoc driver on other Macs is not guaranteed. The Mac App Store is not an
option: a HAL driver and a private aggregate device need an app outside the sandbox.

## Signing and notarization (maintainers)

To publish an installer that opens without warning on any Apple Silicon Mac with macOS 26 or later:

1. **Join the Apple Developer Program** and create two certificates (Xcode › Settings › Accounts ›
   Manage Certificates): *Developer ID Application* (app and driver) and *Developer ID Installer*
   (`.pkg`).
2. **Configure the build** in `Config/Local.xcconfig`: `VOXFLOWAIR_DEVELOPMENT_TEAM = <TEAMID>` and
   `VOXFLOWAIR_CODE_SIGN_IDENTITY = Developer ID Application`. Build with `Scripts/build-xcode.sh --test`.
3. **Sign with the Hardened Runtime**, required for notarization. The project turns it off, so re-sign
   the built app: the driver first, then the app, without `--deep`. Add
   `com.apple.security.cs.disable-library-validation` to the entitlements you sign with: it lets the app
   load third-party Audio Units in its own process (the *Inside VoxFlowAir* loading mode, and the automatic
   fallback when isolated loading fails).

   ```bash
   ID="Developer ID Application: <Name> (<TEAMID>)"
   APP=~/Library/Developer/VoxFlowAirXcode/dist/VoxFlowAir.app
   codesign -f -s "$ID" -o runtime --timestamp "$APP/Contents/Resources/Driver/VoxFlowAirDriver.driver"
   codesign -f -s "$ID" -o runtime --timestamp --entitlements <entitlements.plist> "$APP"
   codesign --verify --strict --deep "$APP"
   ```

4. **Sign the installer**: add `--sign "Developer ID Installer: <Name> (<TEAMID>)"` to the
   `productbuild` command in `Scripts/make-installer.sh`, then run the script.
5. **Notarize and staple**:

   ```bash
   xcrun notarytool store-credentials voxflowair --apple-id <email> --team-id <TEAMID>
   xcrun notarytool submit VoxFlowAir-<version>.pkg --keychain-profile voxflowair --wait
   xcrun stapler staple VoxFlowAir-<version>.pkg
   ```

   The password asked for is an app-specific password created at account.apple.com. Do the same for
   the `.dmg` if you distribute it (sign it first with `codesign -s "$ID" --timestamp`), or rebuild the
   disk image around the stapled package.
6. **Check**: `spctl -a -vv -t install VoxFlowAir-<version>.pkg` should answer
   `accepted, source=Notarized Developer ID`.

With a stable Developer ID signature, the microphone permission also survives updates.

## Updating the version

Change `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/VoxFlowAir.xcconfig`. The app, the
driver's `Info.plist` and the version the driver reports all follow; add an entry to `CHANGELOG.md`.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests, on a `macos-26` runner. It
builds the VoxFlowAirDriver, VoxFlowAir and VoxFlowAirTool schemes (Debug), runs the engine tests
(`xcodebuild test`, hardware tests off), and runs `VoxFlowAirDriverTests` on the built driver without
installing it. Run `Scripts/build-xcode.sh --test` locally before opening a pull request.
