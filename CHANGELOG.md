# Changelog

## 1.0.0 — first public release

- Real-time voice processing: microphone → chain of Audio Units and built-in nodes → virtual
  microphone (BlackHole or the included “VoxFlowAir Micro” driver) and headphones monitoring.
- Node editor, inspector with plugin interfaces, presets with import and export, meters, analyzers,
  loudness-matched bypass, menu bar control.
- Choose which Audio Units appear in the library: all installed plugins, or only the manufacturers and
  plugins you pick; hide plugins, leave out AUv3 extensions or music effects, and change a plugin's
  category (Settings › Plugins, or right-click a plugin in the library).
- Meter monitors on the input and output, with any analyzer plugin.
- Call return: hear a call played into BlackHole in your headphones without the call app's echo
  canceller erasing your voice.
- English interface with a French translation.
- Settings › About with the version, credits, source code link and an optional donation link.
- Bundle identifier, version and signing are set in `Config/VoxFlowAir.xcconfig` and can be overridden in
  an untracked `Config/Local.xcconfig`.
