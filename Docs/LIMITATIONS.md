# Status and known limitations

## Status

| Area | Status |
|---|---|
| Real-time engine (private aggregate, IOProc, AVAudioEngine manual rendering) | Covered by offline tests; hardware test available (`VOXFLOWAIR_HW=1`) |
| Device selection: input, channels, virtual output, headphones, sample rate, buffer | Working; reconfigures on device changes |
| Monitoring, Mute Output, Bypass (independent, loudness-matched bypass) | Covered by tests |
| Meters, clipping, dropout counters, CPU load | Covered by tests |
| Spectrum, oscilloscope, phase correlation, LUFS loudness | Calculations covered by tests |
| Audio Unit hosting (discovery, categories, library filter, favorites, recents) | Covered by tests |
| Plugin loading in process and out of process, state saved and restored | Covered by tests with Apple plugins (and third-party plugins when installed) |
| Plugin interfaces | Depend on each plugin; report problems with the *Plugin compatibility* issue form |
| Node editor (add, move, reorder, connect, branches, sections, zoom, bypass, duplicate) | Chain edits covered by tests; gesture test available (`VOXFLOWAIR_UITEST_EDITOR`) |
| Presets (create, save, duplicate, rename, favorites, import, export, delete, format versions) | Covered by tests |
| Undo / redo, session autosave, safe mode | Working |
| Menu bar panel, closing the window without stopping the engine, open at login | Working |
| BlackHole: detection, assistant, install script | Working |
| Virtual output verification (read-back probe) | Working with BlackHole and VoxFlowAir Micro |
| VoxFlowAir Micro driver | Tested without installation and installed (see [VIRTUAL-DEVICE.md](VIRTUAL-DEVICE.md)); signed ad hoc |
| Call return, pausing monitoring during calls, process tap detection | Working; policies covered by tests |
| Installer (`.pkg` / `.dmg`) | Working with ad hoc signing; no notarized release yet |

## Known limitations

1. **Distribution**: builds are signed ad hoc and not notarized. They run on the Mac that built them;
   other Macs need **Open Anyway**, and the driver may not load there. A public release needs Developer ID
   signing and notarization ([BUILDING.md](BUILDING.md#signing-and-notarization-maintainers)).
2. **Microphone permission**: tied to the code signature. With ad hoc signing, macOS may ask again after
   each rebuild.
3. **BlackHole's name**: apps show "BlackHole 2ch"; only VoxFlowAir Micro can be renamed.
4. **BlackHole and calls**: call apps' echo cancellers erase a voice sent through BlackHole. Use
   VoxFlowAir Micro for calls ([TROUBLESHOOTING.md](TROUBLESHOOTING.md#calls-facetime-zoom-and-echo-cancellers)).
5. **Plugin isolation** is real only with *Isolated Process* (macOS AUHostingService). *Inside VoxFlowAir*, a
   crashing plugin quits VoxFlowAir; safe mode lets you start again. Isolation adds a small CPU cost per
   cycle.
6. **Latency** is estimated, not measured end to end. It includes the virtual output buffer; only the
   engine → virtual device → reading app path is measured by the probe. The aggregate's drift correction
   and the receiving app add latency that is not counted.
7. **Bypass**: the dry signal is not delayed to match the plugins' latency.
8. **Parallel branches** are summed without latency compensation between branches: a plugin with latency
   on one branch only causes a slight phase effect.
9. **No feedback** (loops are refused) and one stereo input and output port per node (no side-chain).
10. **Reconfiguration**: adding or removing nodes causes a short transition silence (a few to a few tens
    of milliseconds, depending on the plugins).
11. **Virtual output buffer**: writing outside the aggregate needs a drift-compensating buffer, which adds
    a few milliseconds.
12. **VoxFlowAir Micro**:
    - not the automatic choice: BlackHole is used when present, VoxFlowAir Micro when it is chosen in
      Settings › Audio or when BlackHole is missing;
    - installing or removing it needs an administrator password and stops all Mac audio for a few
      seconds (`coreaudiod` restart);
    - interleaved stereo Float32 at 44.1 to 96 kHz only; no volume control in the driver;
    - its own virtual clock: drift with the physical microphone is compensated by VoxFlowAir, as with
      BlackHole;
    - one device for the whole Mac: its name changes when a preset with another name loads;
    - transport latency of about two buffers, plus VoxFlowAir's drift buffer and the receiving app's own
      latency.
13. **Mac App Store**: not possible; the driver and the private aggregate device need an app outside the
    sandbox.
