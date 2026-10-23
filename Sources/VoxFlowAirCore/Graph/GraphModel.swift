import Foundation
import AudioToolbox

/// Persistent reference to an Audio Unit plugin (independent of the loaded instance).
public struct PluginReference: Codable, Hashable, Sendable {
    public var type: UInt32
    public var subType: UInt32
    public var manufacturer: UInt32
    public var name: String
    public var manufacturerName: String
    public var version: UInt32

    public init(type: UInt32, subType: UInt32, manufacturer: UInt32, name: String, manufacturerName: String, version: UInt32) {
        self.type = type; self.subType = subType; self.manufacturer = manufacturer
        self.name = name; self.manufacturerName = manufacturerName; self.version = version
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    public var identifier: String { "\(fccString(type)):\(fccString(subType)):\(fccString(manufacturer))" }
}

public enum NodeKind: String, Codable, CaseIterable, Sendable {
    /// Microphone signal (single source).
    case input
    /// Virtual output (BlackHole) — main destination.
    case output
    /// Dedicated monitoring output (headphones). Without this node, the headphones hear the main output.
    case monitorOutput
    /// Third-party Audio Unit plugin.
    case audioUnit
    /// Native VoxFlowAir gain.
    case gain
    /// Native VoxFlowAir analyzer (measurement point in the chain).
    case analyzer

    public var isNative: Bool { self != .audioUnit }
    public var hasInputPort: Bool { self != .input }
    public var hasOutputPort: Bool { self != .output && self != .monitorOutput }
    public var isUnique: Bool { self == .input || self == .output || self == .monitorOutput }

    public var displayName: String {
        switch self {
        case .input: return String(localized: "Microphone input")
        case .output: return String(localized: "Virtual output")
        case .monitorOutput: return String(localized: "Monitoring output")
        case .audioUnit: return String(localized: "AU plugin")
        case .gain: return String(localized: "Gain")
        case .analyzer: return String(localized: "Analyzer")
        }
    }
}

public struct GraphPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct GraphNode: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: NodeKind
    public var title: String
    public var position: GraphPoint
    public var bypassed: Bool
    public var groupID: UUID?
    /// For AU plugins.
    public var plugin: PluginReference?
    /// Full plugin state (serialized property list), kept even if the plugin is missing.
    public var pluginState: Data?
    /// Parameters of native nodes (e.g. "gain" in dB).
    public var parameters: [String: Double]
    /// Load mode specific to this plugin (nil = global setting).
    public var loadMode: PluginLoadMode?

    public init(id: UUID = UUID(), kind: NodeKind, title: String? = nil, position: GraphPoint,
                bypassed: Bool = false, groupID: UUID? = nil, plugin: PluginReference? = nil,
                pluginState: Data? = nil, parameters: [String: Double] = [:]) {
        self.id = id; self.kind = kind; self.title = title ?? plugin?.name ?? kind.displayName
        self.position = position; self.bypassed = bypassed; self.groupID = groupID
        self.plugin = plugin; self.pluginState = pluginState; self.parameters = parameters
    }
}

public struct GraphConnection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public init(id: UUID = UUID(), from: UUID, to: UUID) { self.id = id; self.from = from; self.to = to }
}

public struct NodeGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    public var bypassed: Bool
    public init(id: UUID = UUID(), name: String, colorIndex: Int = 0, bypassed: Bool = false) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.bypassed = bypassed
    }
}

public struct GraphViewport: Codable, Hashable, Sendable {
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var zoom: Double = 1
    public init(offsetX: Double = 0, offsetY: Double = 0, zoom: Double = 1) {
        self.offsetX = offsetX; self.offsetY = offsetY; self.zoom = zoom
    }
}

/// Processing graph: what is drawn is exactly what the engine runs.
public struct ProcessingGraph: Codable, Hashable, Sendable {
    public var nodes: [GraphNode]
    public var connections: [GraphConnection]
    public var groups: [NodeGroup]
    public var viewport: GraphViewport

    public init(nodes: [GraphNode] = [], connections: [GraphConnection] = [], groups: [NodeGroup] = [], viewport: GraphViewport = .init()) {
        self.nodes = nodes; self.connections = connections; self.groups = groups; self.viewport = viewport
    }

    /// Starting chain: microphone input wired straight to the virtual output.
    public static func defaultGraph() -> ProcessingGraph {
        let input = GraphNode(kind: .input, position: GraphPoint(x: 80, y: 220))
        let output = GraphNode(kind: .output, position: GraphPoint(x: 420, y: 220))
        return ProcessingGraph(nodes: [input, output], connections: [GraphConnection(from: input.id, to: output.id)])
    }

    public func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { nodes.firstIndex { $0.id == id } }
    public func incoming(_ id: UUID) -> [GraphConnection] { connections.filter { $0.to == id } }
    public func outgoing(_ id: UUID) -> [GraphConnection] { connections.filter { $0.from == id } }
    public var inputNode: GraphNode? { nodes.first { $0.kind == .input } }
    public var outputNode: GraphNode? { nodes.first { $0.kind == .output } }
    public var monitorNode: GraphNode? { nodes.first { $0.kind == .monitorOutput } }

    public func isEffectivelyBypassed(_ node: GraphNode) -> Bool {
        if node.bypassed { return true }
        if let g = node.groupID, let group = groups.first(where: { $0.id == g }) { return group.bypassed }
        return false
    }

    // MARK: Editing

    public mutating func addNode(_ node: GraphNode) { nodes.append(node) }

    /// Removes a node (see `removingNode`); returns false if refused, graph unchanged.
    @discardableResult
    public mutating func removeNode(_ id: UUID) -> Bool {
        guard let g = try? removingNode(id) else { return false }
        self = g
        return true
    }

    public enum EditError: Error, Equatable, CustomStringConvertible {
        case invalidPorts, duplicate, cycle, selfLoop, unknownNode
        public var description: String {
            switch self {
            case .invalidPorts: return String(localized: "These ports cannot be connected.")
            case .duplicate: return String(localized: "This connection already exists.")
            case .cycle: return String(localized: "This connection would create a loop (not supported).")
            case .selfLoop: return String(localized: "A node cannot be connected to itself.")
            case .unknownNode: return String(localized: "Unknown node.")
            }
        }
    }

    @discardableResult
    public mutating func connect(from: UUID, to: UUID) throws -> GraphConnection {
        guard let a = node(from), let b = node(to) else { throw EditError.unknownNode }
        guard from != to else { throw EditError.selfLoop }
        guard a.kind.hasOutputPort, b.kind.hasInputPort else { throw EditError.invalidPorts }
        guard !connections.contains(where: { $0.from == from && $0.to == to }) else { throw EditError.duplicate }
        if reachable(from: to, target: from) { throw EditError.cycle }
        let c = GraphConnection(from: from, to: to)
        connections.append(c)
        return c
    }

    public mutating func disconnect(_ connectionID: UUID) { connections.removeAll { $0.id == connectionID } }

    /// Inserts a node on an existing connection (A → B becomes A → N → B).
    /// Unknown connection: the node is added unconnected. Refused: graph unchanged, returns false.
    @discardableResult
    public mutating func insert(_ node: GraphNode, on connectionID: UUID) -> Bool {
        guard connections.contains(where: { $0.id == connectionID }) else { addNode(node); return true }
        guard let g = try? inserting(node, on: connectionID) else { return false }
        self = g
        return true
    }

    /// Inserts just before the virtual output, on the main chain (see `appendingToMainChain`).
    @discardableResult
    public mutating func appendToMainChain(_ node: GraphNode) -> Bool {
        guard let g = try? appendingToMainChain(node) else { return false }
        self = g
        return true
    }

    /// Lays out the nodes in a serpentine: topological order, rows of width `rowWidth`.
    public mutating func arrangeMainChain(rowWidth: Double, nodeWidth: Double = 212, spacing: Double = 56, rowHeight: Double = 200) {
        guard let order = topologicalOrder() else { return }
        // Depth = longest path from a source; nodes at the same depth are stacked.
        var depth: [UUID: Int] = [:]
        for id in order { depth[id] = (incoming(id).compactMap { depth[$0.from] }.max() ?? -1) + 1 }
        let perRow = max(1, Int((rowWidth + spacing) / (nodeWidth + spacing)))
        var stackCount: [Int: Int] = [:]
        let maxDepth = depth.values.max() ?? 0
        let lanes = (0...maxDepth).map { d in depth.values.filter { $0 == d }.count }.max() ?? 1
        for id in order {
            guard let i = index(of: id), let d = depth[id] else { continue }
            let lane = stackCount[d, default: 0]
            stackCount[d] = lane + 1
            let row = d / perRow
            var col = d % perRow
            if row % 2 == 1 { col = perRow - 1 - col } // way back in reverse
            nodes[i].position = GraphPoint(x: 60 + Double(col) * (nodeWidth + spacing),
                                           y: 60 + Double(row) * rowHeight * Double(lanes) + Double(lane) * rowHeight * 0.75)
        }
        viewport = GraphViewport()
    }

    public func reachable(from start: UUID, target: UUID) -> Bool {
        var stack = [start], seen = Set<UUID>()
        while let cur = stack.popLast() {
            if cur == target { return true }
            if !seen.insert(cur).inserted { continue }
            stack.append(contentsOf: outgoing(cur).map(\.to))
        }
        return false
    }

    /// Topological order (nil if there is a cycle).
    public func topologicalOrder() -> [UUID]? {
        var indeg: [UUID: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for c in connections where indeg[c.to] != nil && indeg[c.from] != nil { indeg[c.to]! += 1 }
        var queue = nodes.filter { indeg[$0.id] == 0 }.map(\.id)
        var order: [UUID] = []
        while !queue.isEmpty {
            let n = queue.removeFirst()
            order.append(n)
            for c in outgoing(n) where indeg[c.to] != nil {
                indeg[c.to]! -= 1
                if indeg[c.to] == 0 { queue.append(c.to) }
            }
        }
        return order.count == nodes.count ? order : nil
    }

    /// Nodes that actually contribute to an output (virtual or monitoring).
    public func activeNodeIDs() -> Set<UUID> {
        var result = Set<UUID>()
        var stack = nodes.filter { $0.kind == .output || $0.kind == .monitorOutput }.map(\.id)
        while let cur = stack.popLast() {
            if !result.insert(cur).inserted { continue }
            stack.append(contentsOf: incoming(cur).map(\.from))
        }
        // An active node must also be fed by the input.
        guard let input = inputNode else { return [] }
        var fed = Set<UUID>(); var s2 = [input.id]
        while let cur = s2.popLast() {
            if !fed.insert(cur).inserted { continue }
            s2.append(contentsOf: outgoing(cur).map(\.to))
        }
        return result.intersection(fed)
    }
}
