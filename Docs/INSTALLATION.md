# Installation

## Requirements

- A Mac with Apple Silicon, macOS 26 or later.
- Xcode 26 or later (the build uses the macOS 26 SDK).
- Optional: [Homebrew](https://brew.sh), used by the BlackHole install script.

There is no notarized binary yet: you build VoxFlowAir yourself. Maintainers who want to publish a
signed installer: see [BUILDING.md](BUILDING.md#signing-and-notarization-maintainers).

## Build and install

```bash
git clone https://github.com/Kede0111/VoxFlowAir.git
cd VoxFlowAir
Scripts/build-xcode.sh      # → ~/Library/Developer/VoxFlowAirXcode/dist/VoxFlowAir.app
Scripts/install.sh          # copies it to /Applications, checks the signature and opens it
```

- `Scripts/install.sh --user` installs into `~/Applications` (no administrator rights needed).
- `Scripts/install.sh` runs `Scripts/build-xcode.sh` first if the app has not been built yet, quits a
  running VoxFlowAir before replacing it, and tells you whether BlackHole is present.
- Build products live outside the source tree, in `~/Library/Developer/VoxFlowAirXcode`. Set
  `VOXFLOWAIR_DERIVED` to use another folder (both scripts honor it).

You can also build from Xcode: open `VoxFlowAir.xcodeproj`, scheme **VoxFlowAir**, ⌘R. See
[BUILDING.md](BUILDING.md).

## First launch

1. **Gatekeeper.** VoxFlowAir is signed ad hoc (a local signature without an Apple identity) and is not
   notarized. A build made on your own Mac is not quarantined and opens normally. A copy made on
   another Mac and downloaded or received is blocked: open System Settings › Privacy & Security and
   click **Open Anyway** (once, with an administrator password). Gatekeeper never needs to be turned off.
2. **Microphone.** macOS asks for microphone access: it is required. The permission is tied to the code
   signature, and an ad hoc signature changes with every build, so macOS may ask again after a rebuild.
   If access stays blocked, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
3. **Virtual output.** Other apps can only receive VoxFlowAir through a virtual audio device. Install
   BlackHole 2ch or the VoxFlowAir Micro driver (below). Until then, a banner at the top of the main
   window says so, and only monitoring works.
4. In OBS, FaceTime or any other app, choose **BlackHole 2ch** or **VoxFlowAir Micro** as the microphone.

## Virtual output: BlackHole 2ch

[BlackHole](https://github.com/ExistentialAudio/BlackHole) is a free virtual audio driver by Existential
Audio (GPL-3.0). VoxFlowAir uses it as an ordinary audio device and does not include it.

From the app: click **Install Virtual Output…** in the banner, or open Settings › Virtual Output. The
assistant offers:

- **Install in Terminal**: runs the bundled `install-blackhole.command` script, which checks whether
  BlackHole is already there, installs `blackhole-2ch` with Homebrew (official signed and notarized
  package, checksum verified by Homebrew) after asking you, then checks that macOS publishes the device.
  Without Homebrew, it opens the official download page.
- **Copy Command**: copies `brew install --cask blackhole-2ch`.
- **Official Page**: [existential.audio/blackhole](https://existential.audio/blackhole/), to download the
  `.pkg` yourself.

Then click **Check**. If BlackHole is installed but not published ("installed but not yet loaded"),
restart the Mac or run `sudo killall coreaudiod`.

## Virtual output: the VoxFlowAir Micro driver

VoxFlowAir includes its own virtual microphone, "VoxFlowAir Micro" (an AudioServerPlugIn, see
[VIRTUAL-DEVICE.md](VIRTUAL-DEVICE.md)). It is optional; it is the recommended choice for calls, and it
can be renamed per preset.

**Install from the app**: Settings › Virtual Output › **Install in Terminal** (or **Reinstall**). This runs
the bundled `install-voxflowair-driver.command` with the driver embedded in the app
(`VoxFlowAir.app/Contents/Resources/Driver/VoxFlowAirDriver.driver`). The script:

1. checks the macOS version, the driver's identifier and its code signature;
2. explains that all Mac audio stops for a few seconds, and asks for confirmation;
3. asks for your administrator password through `sudo` (VoxFlowAir never sees it);
4. copies the driver to `/Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver`, owned by `root:wheel`,
   without extended attributes;
5. restarts the audio service (`coreaudiod`) and checks that "VoxFlowAir Micro" is published; if not, it
   prints a diagnostic (permissions, signature, recent `coreaudiod` log).

From a terminal, pass the driver's path:

```bash
Resources/install-voxflowair-driver.command \
  ~/Library/Developer/VoxFlowAirXcode/dist/VoxFlowAir.app/Contents/Resources/Driver/VoxFlowAirDriver.driver
```

Then choose Settings › Audio › Virtual output › **VoxFlowAir Micro (VoxFlowAir driver)**, and pick
"VoxFlowAir Micro" as the microphone in your apps.

**Uninstall the driver**: Settings › Virtual Output › **Uninstall…**, or
`Resources/uninstall-voxflowair-driver.command`. It checks the identifier, removes only
`/Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver` and restarts `coreaudiod`. BlackHole, plugins,
presets and settings are not touched. If BlackHole is installed, VoxFlowAir falls back to it.

The driver is signed ad hoc like the app. It loads on the Mac that built it; using it on other Macs
requires Developer ID signing and notarization.

## Update

```bash
git pull
Scripts/build-xcode.sh && Scripts/install.sh
```

Presets and settings in `~/Library/Application Support/VoxFlowAir` are kept. If the driver changed,
reinstall it (Settings › Virtual Output › **Reinstall**): an installed driver is not updated by
rebuilding the app.

## Uninstall

```bash
Scripts/uninstall.sh            # removes the app (to the Trash), keeps presets and settings
Scripts/uninstall.sh --purge    # also deletes presets, settings and logs (asks for confirmation)
```

The script quits VoxFlowAir, removes it from `/Applications` and `~/Applications`, and resets its
microphone permission. A login item goes away with the app. It does not remove:

- the VoxFlowAir Micro driver: use `Resources/uninstall-voxflowair-driver.command` (or the app, before
  uninstalling it);
- BlackHole, which other apps may use: `brew uninstall --cask blackhole-2ch`, or delete
  `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver` and restart.

## Where VoxFlowAir keeps its files

| What | Where |
|---|---|
| Settings | `~/Library/Application Support/VoxFlowAir/settings.json` (+ `.bak`) |
| Presets | `~/Library/Application Support/VoxFlowAir/Presets/*.voxpreset` (+ `.bak`) |
| Unsaved session | `~/Library/Application Support/VoxFlowAir/session.json` |
| Logs | `~/Library/Logs/VoxFlowAir/VoxFlowAir.log` (and Console.app) |
| Driver | `/Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver` |
