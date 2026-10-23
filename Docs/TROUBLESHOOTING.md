# Troubleshooting

## Common problems

| Symptom | Likely cause | Fix |
|---|---|---|
| "Microphone access denied" | No macOS permission (often after a rebuild: the ad hoc signature changed) | System Settings › Privacy & Security › Microphone › turn VoxFlowAir on, then Audio › Restart Audio Engine (⌥⌘R). If it stays blocked: `tccutil reset Microphone be.jackfrom.voxflowair` (or your own `VOXFLOWAIR_BUNDLE_ID`), then relaunch |
| OBS / FaceTime do not list VoxFlowAir | No virtual device, or not loaded | Settings › Virtual Output › **Check**. "Installed but not yet loaded": restart the Mac, or run `sudo killall coreaudiod` |
| OBS receives silence | MUTE OUT on, virtual output not connected in the graph, wrong device in OBS, or an app that captures other apps' audio | Check MUTE OUT, the inspector's *Graph check*, and the microphone chosen in OBS (BlackHole 2ch or VoxFlowAir Micro). If the event log says the virtual output does not return the signal, see [Apps that capture app audio](#apps-that-capture-app-audio) |
| The other person in a call hears nothing, or choppy audio | The call app's echo canceller | See [Calls](#calls-facetime-zoom-and-echo-cancellers) |
| Echo, or your voice twice in the headphones | An app that captures and replays VoxFlowAir's output, or speakers instead of headphones | See [Apps that capture app audio](#apps-that-capture-app-audio); use headphones for monitoring |
| Crackles, a rising Dropouts counter | Buffer too small for the plugins' load | Settings › Audio › Latency profile › **Stable** (512) or **Maximum Safety** (1024) |
| A node shows "Plugin stopped" | The plugin crashed in its isolated process | Inspector › **Reload**. If it keeps happening, update the plugin or remove it from the chain |
| VoxFlowAir quits when a plugin loads | A plugin loaded Inside VoxFlowAir crashed | Relaunch holding Option (safe mode), then set that plugin's **Loading** to Isolated Process in the inspector |
| A plugin runs in demo mode or is silent | Plugin not activated | Activate it with the manufacturer's tool. VoxFlowAir bypasses no licensing |
| "Plugin missing" when opening a preset | Plugin uninstalled, or another version | Reinstall the plugin: its settings were kept in the preset |
| A plugin does not appear in the library | Not registered by macOS, hidden, or filtered out | Settings › Plugins: **Scan Again**, check *Show*, *Hidden plugins* and the AUv3 / aumf switches. See [Adding your own Audio Units](../README.md#adding-your-own-audio-units) |
| No sound in the headphones | MONITOR off, wrong device, low level, or monitoring paused for a call | Right-click MONITOR › **Level and Device…**; check the event log |
| Feedback or howling | Speakers used for monitoring | Use headphones, or turn MONITOR off |
| The engine restarts by itself | Device or sample rate change, interrupted stream | Expected: the event log (status bar) gives the reason. After more than 5 restarts in 30 seconds, the engine stops to protect your audio; check the devices and start it again |

## Calls: FaceTime, Zoom and echo cancellers

Call apps (FaceTime, Zoom, Teams, Discord, WhatsApp, Slack, Webex…) process the microphone with an
**echo canceller**. It takes as its reference everything that plays on the call's output device, from
every app, and removes it from the microphone signal. Two consequences:

1. **Monitoring on the call's speaker erases your voice.** If the call plays on your headphones and
   VoxFlowAir also monitors your processed voice there, the canceller hears your voice on the output,
   finds it again in the virtual microphone, and removes it: the other person hears silence or choppy
   audio.
2. **BlackHole as the call's microphone is erased in every case.** BlackHole plays its own output back
   on its input, and the canceller takes that output as a reference too. "VoxFlowAir Micro" does not have
   this problem: its microphone and its hidden source are separate devices.

What VoxFlowAir does:

- **Use VoxFlowAir Micro for calls.** When a known call app reads BlackHole, VoxFlowAir warns you.
- **Pause monitoring during a call that plays on these headphones** (Settings › Audio, on by default):
  every 2 seconds, VoxFlowAir lists the apps doing audio; while one reads the virtual microphone and
  plays on the monitoring headphones, monitoring pauses, then comes back when the call ends.
- **Call return** lets you hear yourself during a call anyway, like a broadcast console. Keep
  VoxFlowAir Micro as the call's microphone, and set the call's speaker to **BlackHole 2ch** (in
  FaceTime: Video › Output). VoxFlowAir reads BlackHole and mixes the other person into your headphones,
  next to your processed voice. The call's output then contains only the other person, so the echo
  canceller leaves your voice alone, and monitoring is not paused (the rule only concerns calls that play
  on the monitoring headphones). The return never goes to the virtual output, so the other person hears
  no echo. It needs BlackHole installed, monitoring headphones, and a virtual output other than
  BlackHole; set its level in Settings › Audio › **Call return level**.

## Apps that capture app audio

Per-app volume and audio routing tools (FineTune, SoundSource…) use Core Audio **process taps**: they
capture an app's audio, mute it at the source and play it again on their own device. Applied to
VoxFlowAir, this has two effects:

- the virtual device receives silence, so OBS or the call gets nothing;
- the headphones play the monitoring **and** the replayed virtual output, a few milliseconds apart: an
  echo.

When VoxFlowAir's verification probe finds that the virtual output does not come back, it looks for
processes that record without an input device (the signature of a process tap) and names them in the
message. Fix: exclude VoxFlowAir (and your call app) in that tool, so they go through normal macOS audio
again. In FineTune, enter edit mode (pencil), then click the eye next to VoxFlowAir. Then restart the
engine.

## How to diagnose

1. **Event log**: click the last event in the status bar. Engine starts ("Engine running: input →
   virtual output, monitoring on … at … Hz, buffer …"), device changes, plugin failures, call pauses and
   virtual output checks all appear there.
2. **Virtual output check**: the menu bar panel shows "Signal read back from the virtual output" or
   "Virtual output: no return". The probe reads the virtual device exactly as OBS would and reports the
   level difference and the delay.
3. **Counters**: status bar and bottom panel › Levels (Overloads, Near overruns, Errors). **Reset** them,
   then reproduce the problem.
4. **Diagnostics report**: Settings › Diagnostics › **Generate Report** or **Export…**: engine state,
   counters, chain, devices, plugins and the last log lines. Attach it to bug reports.
5. **Logs**: `~/Library/Logs/VoxFlowAir/VoxFlowAir.log` (Settings › Diagnostics › **Show Logs**), or
   Console.app filtered on the subsystem `be.jackfrom.voxflowair` (your bundle identifier if you changed
   it). The driver logs under `<subsystem>.driver`.
6. **Driver**: Settings › Virtual Output › **Check** shows the driver's readers, writers, sample rate and
   filled gaps. `VoxFlowAirDriverTests --installed` tests the installed driver
   ([BUILDING.md](BUILDING.md#driver-tests-voxflowairdrivertests)).
7. **Restart the engine**: ⌥⌘R, or ↻ in the menu bar panel. **Safe mode**: hold Option at launch.

Data lives in `~/Library/Application Support/VoxFlowAir`. Unreadable presets are moved to a subfolder of
`Presets/`, never deleted; an unreadable settings file is set aside and replaced by defaults.
