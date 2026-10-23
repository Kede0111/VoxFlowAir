# VoxFlowAir

Real-time voice processing for macOS. VoxFlowAir takes your microphone, runs it through a chain of
Audio Unit plugins and built-in nodes that you build in a node editor, and sends the result to:

- a **virtual microphone** that OBS, FaceTime, Zoom, Discord and other apps can pick as their input;
- your **headphones** (monitoring), with their own level and on/off switch.

<!-- Screenshot: save it as Docs/images/main-window.png, then replace this comment with ![VoxFlowAir main window](Docs/images/main-window.png) -->

```
Microphone ─▶ VoxFlowAir engine ─▶ processing graph ─┬─▶ virtual output ─▶ OBS / FaceTime / …
                                                    └─▶ headphones (monitoring)
```

[Version française](README.fr.md)

## Features

- **Node editor**: drag plugins from the library onto the canvas or onto a connection, reorder the
  chain, build parallel branches (summed), group nodes into sections, bypass a node or a whole section.
- **Any effect Audio Unit** installed on the Mac (AUv2 and AUv3), with its own interface. By default,
  plugins load in an isolated system process, so a crashing plugin is bypassed instead of taking the
  app down.
- **Built-in nodes**: Gain, Analyzer (measurement point) and a dedicated monitoring output that lets the
  headphones play any point of the chain.
- **Three independent controls**: MONITOR (headphones), MUTE OUT (virtual output only) and BYPASS
  (crossfade to the unprocessed microphone, loudness-matched by default for a fair comparison).
- **Presets**: save, duplicate, rename, favorites, import and export (`.voxpreset` files). A preset keeps
  the whole chain, every plugin's state, the layout, the gains and its virtual output.
- **Meters and analyzers**: input, processed, virtual and headphone meters, spectrum, oscilloscope, phase
  correlation, LUFS loudness (momentary, short-term, integrated, loudness range, true peak).
- **Meter monitors**: run one analyzer plugin on the input and another on the output, off the audio path.
- **Call return**: hear a call in your headphones without the call app's echo canceller erasing your voice.
- **Menu bar panel**: the engine keeps running when the main window is closed.
- **Your own virtual microphone**: the optional "VoxFlowAir Micro" driver, which you can rename per preset.
- English interface with a French translation.

## Requirements

- A Mac with Apple Silicon.
- macOS 26 or later.
- Xcode 26 or later to build it.
- A virtual audio device: [BlackHole 2ch](https://existential.audio/blackhole/) (free, installed through
  the in-app assistant) or the "VoxFlowAir Micro" driver included in this repository.

## Install

There is no notarized binary yet: build VoxFlowAir from source.

```bash
git clone https://github.com/Kede0111/VoxFlowAir.git
cd VoxFlowAir
Scripts/build-xcode.sh      # app, driver and developer tool (Release, signed ad hoc)
Scripts/install.sh          # copies VoxFlowAir.app to /Applications and opens it
```

`Scripts/install.sh --user` installs into `~/Applications` instead. You can also open
`VoxFlowAir.xcodeproj` in Xcode and run the **VoxFlowAir** scheme (⌘R).

**Gatekeeper.** Builds are signed ad hoc, not notarized by Apple. An app you built yourself opens
normally. A copy built on another Mac (downloaded, AirDropped…) is blocked the first time: open
System Settings › Privacy & Security and click **Open Anyway**. You never need to turn Gatekeeper off.

**Microphone access.** macOS asks for it on first launch; it is required. With ad hoc signing, macOS
may ask again after a rebuild.

Details, updating and uninstalling: [Docs/INSTALLATION.md](Docs/INSTALLATION.md).

## Quick start

1. **Set up a virtual output** (once), either:
   - **BlackHole 2ch**: when no virtual output is found, a banner offers **Install Virtual Output…**.
     The assistant runs an install script in Terminal (Homebrew, official signed package) or opens the
     official download page. Your administrator password is asked for by macOS, never by VoxFlowAir.
   - **VoxFlowAir Micro**: Settings › Virtual Output › **Install in Terminal**, then Settings › Audio ›
     Virtual output › **VoxFlowAir Micro (VoxFlowAir driver)**. This is the better choice for calls
     (see [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md#calls-facetime-zoom-and-echo-cancellers)).
2. **Pick your microphone** in Settings › Audio › Microphone / input interface.
3. **Build a chain**: double-click a plugin in the library to add it at the end of the chain, or drag it
   onto a connection. A new preset starts as the microphone input wired straight to the virtual output.
4. **In OBS, FaceTime or any other app**, choose **BlackHole 2ch** or **VoxFlowAir Micro** as the
   microphone.
5. Turn on **MONITOR** to hear the processed voice in your headphones.

Full guide: [Docs/USAGE.md](Docs/USAGE.md).

## Adding your own Audio Units

VoxFlowAir lists the effect Audio Units that macOS has registered:

- plugins in `/Library/Audio/Plug-Ins/Components` (all users) or `~/Library/Audio/Plug-Ins/Components`
  (current user), normally put there by the plugin's own installer;
- Audio Unit v3 extensions that come inside apps (install the app and open it once).

To add a plugin, run its installer or copy its `.component` bundle into one of these folders, then click
**Scan Again** in Settings › Plugins (or ↻ under the library). **Open Components Folder** opens the
per-user folder.

Settings › Plugins also controls what the library shows:

- **Show**: *All installed Audio Units*, or *Only the plugins I choose* (an allowlist, by manufacturer or
  plugin by plugin);
- include or leave out Audio Unit extensions from apps (AUv3), music effects (aumf) and multichannel
  variants (5.1, 7.1, Ambisonics…);
- **hidden plugins**: right-click a plugin in the library › **Hide from Library**; show it again in
  Settings › Plugins › Hidden plugins;
- **category**: right-click a plugin › **Category** to replace the automatic category (useful for plugins
  that publish no tags). Plugins in the *Analyzers* category are offered as meter monitors.

A plugin already used in a preset keeps loading even if you hide it later.

**Why not a custom plugin folder?** Audio Units are found by macOS, not by the host: macOS keeps a
registry of the Components folders and app extensions, and instantiates plugins loaded out of process
from that registry. A host cannot add folders to it, so VoxFlowAir only offers the standard locations.

VoxFlowAir does not bypass licensing: a plugin that is not activated behaves as in any other host.

## Documentation

| Document | Contents |
|---|---|
| [Docs/INSTALLATION.md](Docs/INSTALLATION.md) | Build, install, update, uninstall, Gatekeeper, BlackHole, the VoxFlowAir Micro driver |
| [Docs/USAGE.md](Docs/USAGE.md) | Main window, node editor, inspector, presets, menu bar, settings |
| [Docs/METER-MONITORS.md](Docs/METER-MONITORS.md) | Analyzer plugins on the input and the output |
| [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) | Common problems, calls and echo cancellers, diagnostics |
| [Docs/LIMITATIONS.md](Docs/LIMITATIONS.md) | Status and known limitations |
| [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | How audio flows through the app, technical choices |
| [Docs/VIRTUAL-DEVICE.md](Docs/VIRTUAL-DEVICE.md) | Virtual output options and the VoxFlowAir Micro driver |
| [Docs/BUILDING.md](Docs/BUILDING.md) | Xcode project, build scripts, tests, installer, signing and notarization, CI |

## Contributing

Bug reports, plugin compatibility reports, translations and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md), the [code of conduct](CODE_OF_CONDUCT.md) and the
[security policy](SECURITY.md).

## Support the project

VoxFlowAir is free. If it is useful to you, a donation helps keep it going: click **Support VoxFlowAir**
in Settings › About, or the **Sponsor** button on the GitHub repository page.

## License

[MIT](LICENSE) © 2026 Quentin Descotte.

BlackHole is a separate project by Existential Audio, under GPL-3.0. VoxFlowAir uses it only as an audio
device and does not include it.
