import Foundation

/// Routing settings saved with a preset (optional: when absent, the global settings are kept).
public struct PresetRouting: Codable, Hashable, Sendable {
    public var inputGainDB: Double?
    public var virtualGainDB: Double?
    public var monitorGainDB: Double?
    public var inputChannels: [Int]?
    /// Recommended buffer size for this chain (applied on load).
    public var bufferFrames: Int?
    /// The preset's virtual output (UID: BlackHole, or the VoxFlowAir driver's source). Absent = global setting.
    public var virtualUID: String?
    /// Name shown for the "VoxFlowAir Micro" microphone in apps (VoxFlowAir driver only:
    /// BlackHole's name is fixed by its driver). Absent = global setting.
    public var virtualDeviceName: String?
    public init(inputGainDB: Double? = nil, virtualGainDB: Double? = nil, monitorGainDB: Double? = nil, inputChannels: [Int]? = nil,
                bufferFrames: Int? = nil, virtualUID: String? = nil, virtualDeviceName: String? = nil) {
        self.inputGainDB = inputGainDB; self.virtualGainDB = virtualGainDB
        self.monitorGainDB = monitorGainDB; self.inputChannels = inputChannels; self.bufferFrames = bufferFrames
        self.virtualUID = virtualUID; self.virtualDeviceName = virtualDeviceName
    }
}

/// A preset = a complete chain (structure, plugins, order, connections,
/// plugin states, bypass, layout) + its routing.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    /// File format version. Incremented on every incompatible change;
    /// `PresetMigrator` converts older versions.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isFavorite: Bool
    public var graph: ProcessingGraph
    public var routing: PresetRouting?
    public var notes: String?
    /// App that wrote the file (diagnostics).
    public var writer: String?

    public init(id: UUID = UUID(), name: String, graph: ProcessingGraph = .defaultGraph(), routing: PresetRouting? = nil, isFavorite: Bool = false) {
        formatVersion = Self.currentFormatVersion
        self.id = id; self.name = name
        createdAt = Date(); modifiedAt = Date()
        self.isFavorite = isFavorite
        self.graph = graph
        self.routing = routing
        writer = "VoxFlowAir"
    }

    /// Plugins referenced by the preset.
    public var pluginReferences: [PluginReference] { graph.nodes.compactMap(\.plugin) }
}

public enum PresetMigrator {
    public struct UnsupportedVersion: Error, LocalizedError {
        public let version: Int
        public var errorDescription: String? { String(localized: "Preset format v\(version) is newer than this version of VoxFlowAir (v\(Preset.currentFormatVersion)).") }
    }

    static func decode(_ data: Data) throws -> Preset {
        struct Header: Decodable { var formatVersion: Int? }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let v = (try? dec.decode(Header.self, from: data))?.formatVersion ?? 1
        guard v <= Preset.currentFormatVersion else { throw UnsupportedVersion(version: v) }
        // v1: current format. Future migrations go here.
        var p = try dec.decode(Preset.self, from: data)
        p.formatVersion = Preset.currentFormatVersion
        return p
    }

    static func encode(_ p: Preset) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(p)
    }
}
