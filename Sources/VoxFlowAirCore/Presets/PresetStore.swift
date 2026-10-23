import Foundation

/// Preset storage: one JSON file per preset in
/// ~/Library/Application Support/VoxFlowAir/Presets, written atomically with a
/// backup copy (.bak). An unreadable file is set aside, never deleted.
public final class PresetStore: @unchecked Sendable {
    public static let fileExtension = "voxpreset"
    public let directory: URL
    public let quarantineDirectory: URL
    public private(set) var presets: [Preset] = []
    public private(set) var loadErrors: [String] = []

    public init(directory: URL = AppPaths.presets) {
        self.directory = directory
        quarantineDirectory = directory.appendingPathComponent("Unreadable", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func load() -> [Preset] {
        loadErrors = []
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [Preset] = []
        for url in files where url.pathExtension == Self.fileExtension {
            do {
                result.append(try PresetMigrator.decode(Data(contentsOf: url)))
            } catch {
                // Try the backup copy.
                let bak = url.appendingPathExtension("bak")
                if let data = try? Data(contentsOf: bak), let p = try? PresetMigrator.decode(data) {
                    result.append(p)
                    loadErrors.append(String(localized: "“\(url.lastPathComponent)” was unreadable and has been restored from its backup copy."))
                    try? write(p)
                } else if error is PresetMigrator.UnsupportedVersion {
                    loadErrors.append(String(localized: "“\(url.lastPathComponent)”: \(error.localizedDescription)"))
                } else {
                    try? fm.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
                    let dest = quarantineDirectory.appendingPathComponent(url.lastPathComponent + "-\(Int(Date().timeIntervalSince1970))")
                    try? fm.moveItem(at: url, to: dest)
                    loadErrors.append(String(localized: "“\(url.lastPathComponent)” is unreadable and was moved to \(dest.path)."))
                }
                vlog(.error, "Loading preset \(url.lastPathComponent): \(error)")
            }
        }
        // Deduplicate by identifier.
        var seen = Set<UUID>()
        presets = result.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return presets
    }

    public func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)") }

    public func preset(_ id: UUID) -> Preset? { presets.first { $0.id == id } }

    /// Writes the preset (atomically), keeping the previous version as .bak.
    public func write(_ p: Preset) throws {
        var p = p
        p.modifiedAt = Date()
        p.formatVersion = Preset.currentFormatVersion
        let data = try PresetMigrator.encode(p)
        // Check that it reads back before overwriting anything.
        _ = try PresetMigrator.decode(data)
        let url = url(for: p.id)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        try data.write(to: url, options: .atomic)
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func uniqueName(_ base: String) -> String {
        let names = Set(presets.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    @discardableResult
    public func create(name: String, graph: ProcessingGraph = .defaultGraph(), routing: PresetRouting? = nil) throws -> Preset {
        let p = Preset(name: uniqueName(name), graph: graph, routing: routing)
        try write(p)
        return p
    }

    @discardableResult
    public func duplicate(_ id: UUID) throws -> Preset {
        guard var p = preset(id) else { throw RuntimeError(String(localized: "Preset not found")) }
        p.id = UUID()
        p.name = uniqueName(String(localized: "\(p.name) copy"))
        p.createdAt = Date()
        p.isFavorite = false
        try write(p)
        return p
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard var p = preset(id) else { throw RuntimeError(String(localized: "Preset not found")) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeError(String(localized: "The name cannot be empty.")) }
        p.name = trimmed
        try write(p)
    }

    public func setFavorite(_ id: UUID, _ fav: Bool) throws {
        guard var p = preset(id) else { return }
        p.isFavorite = fav
        try write(p)
    }

    /// Recoverable deletion: the file goes to the Trash.
    public func delete(_ id: UUID) throws {
        let url = url(for: id)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
        let bak = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: bak.path) { try? fm.trashItem(at: bak, resultingItemURL: nil) }
        presets.removeAll { $0.id == id }
    }

    public func export(_ id: UUID, to dest: URL) throws {
        guard let p = preset(id) else { throw RuntimeError(String(localized: "Preset not found")) }
        try PresetMigrator.encode(p).write(to: dest, options: .atomic)
    }

    /// Imports a .voxpreset file. An identifier already in use is replaced by a new one.
    @discardableResult
    public func importPreset(from src: URL) throws -> Preset {
        var p = try PresetMigrator.decode(Data(contentsOf: src))
        if preset(p.id) != nil { p.id = UUID() }
        p.name = uniqueName(p.name)
        try write(p)
        return p
    }
}

/// Standard macOS locations.
public enum AppPaths {
    public static var applicationSupport: URL {
        // VOXFLOWAIR_SUPPORT_DIR keeps tests apart from real data.
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["VOXFLOWAIR_SUPPORT_DIR"] {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = base.appendingPathComponent("VoxFlowAir", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static var presets: URL { applicationSupport.appendingPathComponent("Presets", isDirectory: true) }
    public static var settings: URL { applicationSupport.appendingPathComponent("settings.json") }
    public static var session: URL { applicationSupport.appendingPathComponent("session.json") }
    public static var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoxFlowAir", isDirectory: true) }
}
