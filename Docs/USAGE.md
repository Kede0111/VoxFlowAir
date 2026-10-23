# Using VoxFlowAir

## Main window

| Area | What it holds |
|---|---|
| **Toolbar** (top) | Preset menu, previous / next preset, new preset, undo / redo, save; engine status; MONITOR, MUTE OUT and BYPASS; Meter Monitors, Settings, Inspector |
| **Library** (left sidebar) | Native nodes and Audio Unit plugins, with search |
| **Editor** (center) | The processing graph that the engine actually runs |
| **Inspector** (right, ⌥⌘I) | Settings of the selected node, or an overview of the chain |
| **Bottom panel** | Input and output cards, analyzers, loudness |
| **Status bar** (bottom) | Processing state, CPU load, latency, counters, last event, monitoring device and level |

If no virtual output is installed, a banner at the top of the editor offers **Install Virtual Output…**.

### Toolbar

- **Preset menu** (the active preset's name; • means unsaved changes): Favorites, Presets, then
  Save “…” (⌘S), New Preset…, Save As…, Duplicate “…”, Rename…, Add to / Remove from Favorites,
  Export…, Import…, Revert to Saved, Delete “…”….
- **‹ ›** switch to the previous / next preset; **+** creates a new preset.
- **Undo / Redo** (⌘Z, ⇧⌘Z) and **Save** (⌘S, a check mark when the preset is saved).
- **Engine status**: click the pill to stop or start the engine. While it runs, it shows the
  estimated headphone latency and the buffer size; click the buffer size to change it.
- **MONITOR · MUTE OUT · BYPASS**: see [The three controls](#the-three-controls). Right-click
  MONITOR for **Level and Device…**; right-click BYPASS for **Loudness-matched bypass**.
- **Meter Monitors** (⌘2), **Settings** (⌘,), **Inspector** (⌥⌘I).

### Library

Three tabs, plus the sidebar search field (name or manufacturer):

- **Effects**: *VoxFlowAir native effects* (Gain, Analyzer, Headphone output), then the plugins *By
  category (AU plugins)*.
- **Plugins**: by manufacturer, then by category.
- **Favorites**: plugins you starred, and *Recently used*.

Double-click a plugin to add it at the end of the chain, just before the virtual output. Drag it onto
the canvas to place it, or onto a connection to insert it there. Right-click a plugin for **Add to End
of Chain**, **Add to Favorites**, **Category** (Automatic or a chosen category) and **Hide from
Library**. The ↻ button under the list scans for plugins again.

The categories are Dynamics, Equalization, Filters, Saturation, Reverb and Time-Based Effects, Voice and
Noise Reduction, Pitch and Modulation, Utilities, Analyzers and Other. They come from the plugin's tags,
or from keywords in its name when it publishes none.

### Bottom panel

- **Input** and **Output** cards: device, level, clipping (click to clear), bit depth; the output shows
  MUTE when the virtual output is muted.
- **Analyzer** area, with four views: **Analyzer** (spectrum), **Oscilloscope**, **Phase** (correlation:
  +1 for a duplicated mono mic, negative for a phase inversion) and **Levels**. The source can be
  **Output (processed)**, **Input (mic)** or any Analyzer node in the graph.
- **Levels** shows the INPUT, PROCESSED, VIRTUAL and PHONES meters, the input gain, virtual output and
  monitoring levels, counters (Load, Overloads, Near overruns, Errors, **Reset**), and **Record 20 s (Raw
  + Processed)**: two 32-bit float WAV files (unprocessed microphone and processed signal) to compare by
  ear. **Show in Finder** reveals them.
- **Loudness** column: ITU-R BS.1770 / EBU R128 loudness of the analyzed source: M (400 ms), S (3 s),
  INT (integrated, with a reset button), LRA and an approximate true peak.

Drag the dividers to resize the columns; drag the line above the panel to change its height.

### Status bar

Processing / Bypass, CPU (share of each audio cycle used by VoxFlowAir), estimated latency to apps,
counters that appear when non-zero (Dropouts, Render errors, Invalid samples), the number of
warnings, the last event (click it for the **Event Log**), and on the right the headphones icon
(monitoring on / off), the monitoring device and its level.

## The three controls

| Control | Effect | Does not affect |
|---|---|---|
| **MONITOR** (⇧⌘M) | Plays the processed signal in the headphones, at its own level | The virtual output |
| **MUTE OUT** (⇧⌘U) | Mutes what VoxFlowAir sends to apps (virtual output) | Monitoring |
| **BYPASS** (⇧⌘B) | Replaces the whole chain with the unprocessed microphone (input gain kept), with a crossfade; plugins keep running for an instant return | Routing, presets |

With **Loudness-matched bypass** (on by default), the raw signal is corrected by the measured loudness
difference between the processed and unprocessed signal, so you compare sound, not level. The same
commands are in the **Audio** menu, with **Restart Audio Engine** (⌥⌘R) and **Stop Engine** /
**Start Engine**.

## Node editor

Every preset has one **Input** node (the microphone) and one **Virtual output** node; they cannot be
deleted. Between them you place plugins and native nodes:

| Native node | Use |
|---|---|
| **Gain** | Level from −60 to +24 dB, no latency |
| **Analyzer** | Measurement point: pick it as the source of the analysis views |
| **Dedicated monitoring output** | The headphones play the point of the chain connected to this node instead of the virtual output (for example, before a limiter). Only one is allowed, and it is never sent to apps |

Add them from the library, from **Add Native Node** at the bottom left of the canvas, or by
right-clicking a connection (**Insert Gain**, **Insert Analyzer**).

### Moving and reordering

Position on screen, processing order and connections are separate things.

- **Drag a node** onto empty space: it only moves on the canvas (snapped to 10 pt). The sound never
  changes; the top of the canvas says "Visual move: the sound doesn't change".
- **Drop a node on a ⊕ connection**: while you drag, every connection the node can go to shows a ⊕
  marker. Near one, the connection thickens, the new connections and the new order numbers appear as
  a preview, and the top of the canvas reads "Release to reorder the audio chain". On release, the node
  leaves its place (its neighbors are reconnected) and is inserted there in one step, without reloading
  the plugin or touching its settings. ⌘Z undoes.
- **Grip ≡** (top left of a node) or **⌥ + drag**: reorder only. Released away from a connection, nothing
  changes; on an impossible connection, a red badge explains why.
- **⌥⌘↑ / ⌥⌘↓**, the node's context menu (**Move Up in Chain**, **Move Down in Chain**), or the
  *Processing order* list in the inspector do the same from the keyboard or a list.
- Input / output nodes, branch nodes and multiple selections show no ⊕: dropping them only moves them.
- The **number** above a node is its position in the main chain (the longest path from the input to the
  virtual output), that is, the order the engine runs.
- **Arrange** (magic wand, top right) lays the nodes out in chain order. Positions only; ⌘Z undoes.

A tip explains reordering the first time, until you click **Got It** or reorder successfully. The help
bar at the bottom right recalls the two main gestures; **Other Gestures** lists them all.

### Connections and branches

- Drag from a node's **output port** (right) to another node's input (left) to connect them. One output
  can feed several nodes (**parallel branches**); several connections into one input are **summed**.
- A connection that is not possible (loop, duplicate, missing port) is drawn in red with the reason and
  is not created. Feedback loops are not supported.
- Click the dot in the middle of a connection to select it; Delete removes it. Right-click it for
  **Insert Gain**, **Insert Analyzer** and **Delete Connection**.
- Connections glow with the real signal level. Nodes that are not on an active path are dimmed and are
  not processed.

### Selection, editing and view

| Gesture | Action |
|---|---|
| Click · ⇧ or ⌘ + click | Select · add to the selection |
| Drag on the background | Lasso selection |
| Double-click a plugin | Open its interface |
| ⏻ button on a node · B | Bypass the node |
| Delete · ⌘D · ⌘G | Delete · duplicate · group into a section |
| Space + drag · scroll wheel | Pan the view |
| ⌘ + scroll wheel · pinch | Zoom (also ⌘+, ⌘−; ⌘0 zooms to fit) |
| Esc | Cancel the current gesture |

**Sections**: select nodes and press ⌘G (Graph › Group Selection). A section's ⏻ button bypasses all of
it; right-click its title for **Ungroup Section**, or use **Remove from Section** on a node.

**Lock** (padlock, ⌥⌘L, or Settings › General › Lock graph editing) prevents accidental edits. The
canvas then shows **Editing Locked**; click it to unlock.

The view (pan and zoom) is saved with the preset. The node context menu also has **Open Interface**,
**Reload Plugin** (after a failure), **Bypass** / **Enable**, **Analyze This Point**, **Duplicate** and
**Delete**.

## Inspector

With nothing selected, the inspector shows the chain:

- **Processing order**: the main chain from Input to Virtual output; reorder it with the arrows (or by
  drag and drop on macOS 27 and later). Nodes outside the main chain are counted below.
- **Active chain**: preset, number of nodes and connections, sections (with on/off switches).
- **Latency (estimate)**: sample rate, buffer, hardware input / output, plugins, estimated total.
- **Graph check**: errors and warnings (click one to select its node).
- **Quick help**.

With a node selected: its name (editable), its **Status** (Active, Bypassed, Plugin missing, Plugin
stopped, Error…), **Bypass this node**, its level, and the settings for its kind:

- **Input**: device, channels (stereo pair, or one channel as dual mono), input gain.
- **Virtual output**: device and level.
- **Gain**: slider and −12 / −6 / 0 / +6 / +12 dB buttons.
- **Plugin**: **Controls** (the plugin's own presets, **Compare** for an A/B comparison, **Copy** / **Paste**
  of settings between instances of the same plugin, the first twelve parameters, **Show Full
  Interface**), then manufacturer, AU identifier, version, format (AUv2 / AUv3), channels, reported
  latency, process, **Check Interface and Validation**, and **Loading** (Isolated Process or In
  VoxFlowAir, for this node only). **Reload** appears after a failure.

With several nodes selected: **Group into Section**, **Bypass Selection**, **Re-enable Selection**,
**Delete**.

A plugin that is not installed keeps its settings in the preset; its node passes the signal through
until the plugin is available again.

## Presets

A preset stores the graph (nodes, plugins, connections, the full state of each plugin, bypass, sections,
layout and view), and its routing: input, virtual output and monitoring gains, input channels, buffer
size, virtual output and, for VoxFlowAir Micro, the microphone name shown in apps.

- **New Preset** starts from the microphone input connected to the virtual output. On first launch,
  VoxFlowAir creates one called "Default".
- **New Preset** and **Save As…** open a sheet where you also choose the preset's **Virtual output**
  (current setting, VoxFlowAir Micro, or BlackHole) and, for VoxFlowAir Micro, the **Microphone name in
  OBS, FaceTime…**. Apps find the microphone by its identifier, so renaming it does not break their
  settings. BlackHole's name is set by its driver and cannot be changed.
- **Save** (⌘S) overwrites the active preset; the previous version stays in a `.bak` file. **Save As…**
  with the name of an existing preset offers to replace it.
- Switching presets with unsaved changes asks whether to save them (the menu bar panel saves them).
- **Delete** moves the preset file to the Trash. **Export…** / **Import…** use `.voxpreset` files; an
  imported preset lists the plugins missing on this Mac.
- Unsaved changes are saved automatically and restored after an unexpected quit.

Presets are JSON files in `~/Library/Application Support/VoxFlowAir/Presets`.

## Meter monitors

The **Meter Monitors** window (⌘2, or Window › Show Meter Monitors) runs an analyzer plugin on the
input and another on the output. See [METER-MONITORS.md](METER-MONITORS.md).

## Call return

Settings › Audio › **Call return: hear what plays into BlackHole in the headphones**. With VoxFlowAir
Micro as the virtual output, set FaceTime's speaker (Video › Output) to BlackHole: you hear the other
person and your processed voice in the headphones, and FaceTime's echo canceller no longer erases your
voice. The return is never sent to the virtual output. It needs BlackHole, monitoring headphones, and a
virtual output other than BlackHole. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#calls-facetime-zoom-and-echo-cancellers).

## Menu bar

The menu bar icon (a waveform, slashed when the engine is stopped or the output is muted) opens a panel
that works with the main window closed:

- on/off switch for the engine, preset picker, settings;
- **Input** and **Output** meters with clip indicators (click to clear);
- monitoring device and level;
- **MONITOR**, **MUTE** and **BYPASS**;
- virtual output in use and whether its signal is read back, estimated latency, dropouts, failed or
  missing plugins, engine errors;
- **Open VoxFlowAir**, settings, restart the audio engine, **Quit VoxFlowAir**.

Closing the main window does not stop processing: VoxFlowAir stays in the menu bar. Quit it from the
panel.

## Menus and shortcuts

| Menu | Commands |
|---|---|
| File | Save Preset (⌘S), Revert to Saved Preset |
| Edit | Undo (⌘Z), Redo (⇧⌘Z) |
| View | Show / Hide Inspector (⌥⌘I) |
| Audio | Turn Monitoring On / Off (⇧⌘M), Mute / Unmute Virtual Output (⇧⌘U), Bypass / Resume Processing (⇧⌘B), Restart Audio Engine (⌥⌘R), Stop / Start Engine |
| Graph | Zoom In (⌘+), Zoom Out (⌘−), Zoom to Fit (⌘0), Duplicate Node (⌘D), Group Selection (⌘G), Move Up / Down in Chain (⌥⌘↑ / ⌥⌘↓), Lock / Unlock Editing (⌥⌘L) |
| Window | VoxFlowAir Main Window (⌘1), Show / Hide Meter Monitors (⌘2) |

## Settings (⌘,)

**Audio**

- Microphone / input interface, and channels. VoxFlowAir's own virtual microphone is never offered as
  an input (it would create a loop).
- **Virtual output**: *Automatic (BlackHole, otherwise VoxFlowAir Micro)*, VoxFlowAir Micro (VoxFlowAir
  driver), or a virtual device. For VoxFlowAir Micro, a field sets the **Microphone name in apps**.
- **Monitoring (headphones)**: *System default output* or a device; the headphones in use; **If the
  headphones disappear, switch to the system output (with a message)**.
- **Pause monitoring during a call that plays on these headphones** (on by default).
- **Call return** and **Call return level** (−30 to +12 dB).
- **Sample rate** (same as the microphone by default) and **Latency profile**: Ultra-Low Latency (64
  samples), Low Latency (128), Balanced (256, default), Stable (512), Maximum Safety (1024). Profiles
  the device does not support are marked.
- Estimated latency, **Restart Audio Engine**, and **Allow Microphone Access…** when access is missing.

**Virtual Output**: status, install, reinstall and uninstall of the VoxFlowAir Micro driver (with its
reader / writer counts), and the BlackHole assistant. See [INSTALLATION.md](INSTALLATION.md).

**Plugins**

- **Load plugins**: **Isolated Process** (default: the plugin runs in a macOS service, AUHostingService;
  if it crashes, VoxFlowAir keeps running and bypasses the node) or **Inside VoxFlowAir** (best compatibility,
  but a faulty plugin can quit VoxFlowAir). If a plugin fails to load isolated, VoxFlowAir retries in its
  own process.
- **Library**: Show all installed Audio Units or only the plugins you choose; AUv3, music effects and
  multichannel variants; counts; **Scan Again**; **Open Components Folder**; allowed and hidden plugins.
  See [Adding your own Audio Units](../README.md#adding-your-own-audio-units).

**General**: Appearance (Dark, Light, Match macOS), **Open VoxFlowAir at login**, **Show the main window
at launch**, **Lock graph editing**.

**Diagnostics**: **Generate Report**, **Export…**, **Show Logs**, **Presets Folder**, **Reset Counters**.

**About**: version, credits, license, **Source Code** and **Support VoxFlowAir** (donation).

## Safe mode

Hold **Option** while VoxFlowAir launches: it starts without loading any plugin. Use it when a plugin
makes the app crash at launch. If the previous session did not end normally, VoxFlowAir says so at the
next launch.
