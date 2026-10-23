import Foundation

public struct GraphIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String { "\(severity)-\(nodeID?.uuidString ?? "-")-\(message)" }
    public let severity: Severity
    public let message: String
    public let nodeID: UUID?
    public init(_ severity: Severity, _ message: String, node: UUID? = nil) {
        self.severity = severity; self.message = message; self.nodeID = node
    }
}

public enum GraphValidator {
    public static func validate(_ g: ProcessingGraph, missingPlugins: Set<UUID> = [], failedPlugins: Set<UUID> = []) -> [GraphIssue] {
        var issues: [GraphIssue] = []
        let inputs = g.nodes.filter { $0.kind == .input }
        let outputs = g.nodes.filter { $0.kind == .output }
        if inputs.count != 1 { issues.append(.init(.error, String(localized: "The graph must contain exactly one input (currently \(inputs.count))."))) }
        if outputs.count != 1 { issues.append(.init(.error, String(localized: "The graph must contain exactly one virtual output (currently \(outputs.count))."))) }
        if g.nodes.filter({ $0.kind == .monitorOutput }).count > 1 { issues.append(.init(.error, String(localized: "Only one monitoring output is allowed."))) }
        if g.topologicalOrder() == nil { issues.append(.init(.error, String(localized: "The graph contains a loop: the engine does not support feedback."))) }

        let ids = Set(g.nodes.map(\.id))
        for c in g.connections where !ids.contains(c.from) || !ids.contains(c.to) {
            issues.append(.init(.error, String(localized: "Orphan connection ignored.")))
        }
        for c in g.connections {
            if let a = g.node(c.from), !a.kind.hasOutputPort { issues.append(.init(.error, String(localized: "“\(a.title)” has no output."), node: a.id)) }
            if let b = g.node(c.to), !b.kind.hasInputPort { issues.append(.init(.error, String(localized: "“\(b.title)” has no input."), node: b.id)) }
        }

        if let out = outputs.first, g.incoming(out.id).isEmpty {
            issues.append(.init(.warning, String(localized: "The virtual output is not connected to anything: apps will receive silence."), node: out.id))
        }
        let active = g.activeNodeIDs()
        if let out = outputs.first, !active.contains(out.id), !g.incoming(out.id).isEmpty {
            issues.append(.init(.warning, String(localized: "The virtual output is not fed by the microphone input."), node: out.id))
        }
        for n in g.nodes where !active.contains(n.id) && n.kind != .input && n.kind != .output && n.kind != .monitorOutput {
            issues.append(.init(.info, String(localized: "“\(n.title)” is not on an active path: it is not processed."), node: n.id))
        }
        for n in g.nodes where missingPlugins.contains(n.id) {
            issues.append(.init(.warning, String(localized: "Plugin not found: “\(n.plugin?.name ?? n.title)”. The node passes the signal through; its settings are kept."), node: n.id))
        }
        for n in g.nodes where failedPlugins.contains(n.id) {
            issues.append(.init(.warning, String(localized: "Failed to load “\(n.title)”. The node is bypassed; its settings are kept."), node: n.id))
        }
        return issues
    }
}
