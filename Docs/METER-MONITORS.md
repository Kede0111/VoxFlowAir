# Meter monitors

Besides its own meters and analyzers, VoxFlowAir can run two analyzer plugins of your choice: one on the
input signal and one on the output signal. They show their own interface in the **Meter Monitors**
window and never touch the audio sent to apps.

## Using them

- **Show or hide the window**: the Meter Monitors button (gauge) in the toolbar, or Window › Show Meter
  Monitors (⌘2). Closing the window stops neither the audio nor the measurement: the plugins keep
  measuring in the background, so an integrated loudness keeps accumulating.
- **Choose a meter**: the menu at the top of each column (**None** to disconnect it). The choice and each
  meter's own settings (loudness target, scale…) are kept from one session to the next.
- The badge at the top right shows the peak of the signal the plugin actually receives, read at its
  output: "no signal" means the plugin receives nothing.
- Each column takes the width of the plugin's interface; plugins that offer several interface sizes
  resize the window.

## Measurement points

These are the points used by the analyzers of the bottom panel:

| Column | Signal |
|---|---|
| Input | Microphone after input gain, before the chain |
| Output | Final processed signal (bypass included), before the virtual output gain and mute |

## Which plugins are offered

Every plugin of the **Analyzers** category that the library shows (multichannel variants left out).
Well-known meters come first, with a short description; the other analyzers follow, by manufacturer
and name.

| Listed first (stereo variants, when installed) | Description shown |
|---|---|
| Waves WLM Plus, WLM Meter | LUFS loudness (momentary, short-term, integrated), true peak, LRA |
| Waves Dorrough | Peak and average on one scale |
| Waves VU Meter | Analog VU meter |
| Waves Abbey Road TG Meter Bridge | VU and PPM meter bridge |
| Waves PAZ Analyzer | Full analyzer: spectrum, stereo image, peaks |
| Waves PAZ Frequency | Spectrum |
| Waves PAZ Meters | Peak and RMS |
| Waves PAZ Position | Stereo image and phase |

The known list lives in `MeterPlugins.known` (`Sources/VoxFlowAirCore/Monitoring/MeterMonitorFeeder.swift`),
matched by Audio Unit manufacturer and subtype codes. Pull requests that add other common meters are
welcome.

To offer a plugin that is not detected as an analyzer, right-click it in the library › **Category** ›
**Analyzers**. Any effect Audio Unit with an audio input and output can be fed, since its output is
discarded. Hidden plugins, and plugins left out by an allowlist, are not offered.

## How it works

Meter plugins are insert effects: they must receive audio to display anything. VoxFlowAir does not put
them in the chain. A dedicated thread reads a copy of the signal from the existing analysis buffers and
has the plugin process it in blocks of 256 samples; the plugin's output is discarded, except for its
peak (the badge).

- No added latency and no change to the audio sent to apps (checked sample by sample in
  `MeterMonitorTests`).
- One instance per column, created when you choose the meter and kept: opening or closing the window
  recreates nothing.
- The display lags the audio by a few milliseconds (block reading).
- The plugins load with the mode set in Settings › Plugins (isolated process by default), and are
  reconfigured when the sample rate changes.
- In safe mode, the previous session's meters are not reloaded.
