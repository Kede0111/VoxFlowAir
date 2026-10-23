import Foundation

/// Factory presets shipped with VoxFlowAir (Resources/FactoryPresets, copied into the app).
///
/// A user preset is linked to its factory version by its identifier: it can be freely
/// edited and saved, then restored to its factory version at any time.
/// A deleted factory preset is not reinstalled automatically, but can be restored.
public enum FactoryPresets {
    /// Reads the factory presets from a folder, or from the app's resources.
    public static func load(directory: URL? = nil, bundle: Bundle = .main) -> [Preset] {
        let urls: [URL]
        if let directory {
            urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == PresetStore.fileExtension }
        } else {
            urls = bundle.urls(forResourcesWithExtension: PresetStore.fileExtension, subdirectory: nil) ?? []
        }
        var seen = Set<UUID>()
        return urls.compactMap { url -> Preset? in
            do { return try PresetMigrator.decode(Data(contentsOf: url)) }
            catch { vlog(.error, "Unreadable factory preset \(url.lastPathComponent): \(error)"); return nil }
        }
        .filter { seen.insert($0.id).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// True if the content (chain and routing) differs from the factory version.
    public static func differs(_ p: Preset, from factory: Preset) -> Bool {
        p.graph != factory.graph || p.routing != factory.routing || p.name != factory.name
    }
}
