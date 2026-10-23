import Foundation

/// Transactional chain editing operations: each one works on a copy, checks the result
/// and returns the new graph only if everything succeeded. When refused, a typed error
/// is thrown and the original graph is left unchanged (no connection removed without
/// being replaced).
///
/// Three notions stay separate:
/// - the visual position (`GraphNode.position`) never changes the sound;
/// - the processing order is *derived* from the connections (nothing is stored twice);
/// - the connections are the single source of truth for routing.
public enum ChainEditError: Error, Equatable, CustomStringConvertible, Sendable {
    case unknownNode
    case unknownConnection
    /// Input, virtual output or monitoring output: their place is fixed.
    case fixedNode
    /// The node has several inputs or outputs (branch), or only one of its two connections.
    case notLinear
    /// The node lacks the two ports needed to be inserted on a connection.
    case invalidPorts
    /// The result would be identical to the current state.
    case noChange
    /// The result would contain a loop (refused for safety, should not happen).
    case cycle

    public var description: String {
        switch self {
        case .unknownNode: return String(localized: "Unknown node.")
        case .unknownConnection: return String(localized: "Unknown connection.")
        case .fixedNode: return String(localized: "The input and outputs have a fixed place in the chain.")
        case .notLinear: return String(localized: "This node is not on a linear section (branch or partial connection): move its connections by hand.")
        case .invalidPorts: return String(localized: "This node cannot be inserted on a connection (it lacks an input or an output).")
        case .noChange: return String(localized: "The node is already at this place in the chain.")
        case .cycle: return String(localized: "This operation would create a loop: refused.")
        }
    }
}

extension ProcessingGraph {

    // MARK: Reading the order

    /// Deterministic processing order: topological order, ties broken by the order of the
    /// nodes array. This is the order the connections actually impose on the engine.
    public func processingOrder() -> [UUID] { topologicalOrder() ?? nodes.map(\.id) }

    /// Longest path (in number of nodes) from the input to each node it feeds.
    func depthsFromInput() -> [UUID: Int] {
        guard let input = inputNode, let order = topologicalOrder() else { return [:] }
        var depth: [UUID: Int] = [input.id: 0]
        for id in order {
            guard let d = depth[id] else { continue }
            for c in outgoing(id) where (depth[c.to] ?? -1) < d + 1 { depth[c.to] = d + 1 }
        }
        return depth
    }

    /// Main chain: the longest path Input → Virtual output (deterministic, ties broken by
    /// the first connection in the array). Empty if the output is not fed by the input.
    public func mainChain() -> [UUID] {
        guard let input = inputNode, let out = outputNode else { return [] }
        let depth = depthsFromInput()
        guard depth[out.id] != nil else { return [] }
        var chain = [out.id]
        var cur = out.id
        while cur != input.id {
            let preds = incoming(cur).filter { depth[$0.from] != nil }
            guard let top = preds.compactMap({ depth[$0.from] }).max(),
                  let best = preds.first(where: { depth[$0.from] == top }) else { return [] }
            cur = best.from
            chain.append(cur)
        }
        return chain.reversed()
    }

    /// Connection that reaches `node` along the main chain (nil if off the chain).
    public func mainChainConnection(into node: UUID) -> GraphConnection? {
        let chain = mainChain()
        guard let i = chain.firstIndex(of: node), i > 0 else { return nil }
        return connections.first { $0.from == chain[i - 1] && $0.to == node }
    }

    /// Nodes that can be moved within the main chain (neither input nor output).
    public func reorderableMainChain() -> [UUID] {
        mainChain().filter { id in node(id).map { !$0.kind.isUnique } ?? false }
    }

    // MARK: Checks

    /// Reason why `from → to` would be refused (nil if the connection is valid).
    public func connectionError(from: UUID, to: UUID) -> EditError? {
        var copy = self
        do { try copy.connect(from: from, to: to); return nil }
        catch let e as EditError { return e }
        catch { return .unknownNode }
    }

    /// Reason why `node` cannot be moved onto `connection` (nil if possible).
    public func moveInChainError(_ node: UUID, onto connection: UUID) -> ChainEditError? {
        do { _ = try movingInChain(node, onto: connection); return nil }
        catch let e as ChainEditError { return e }
        catch { return .unknownNode }
    }

    /// Drop targets for `node` in the chain: for each connection, the graph obtained by dropping
    /// it there (`movingInChain`, the same operation as the real one) or the reason for the
    /// refusal. Connections where the node already sits (`noChange`) are left out. The editor
    /// computes them when a drag starts: dropping on a target reorders, elsewhere it only moves.
    public func chainDropTargets(for node: UUID) -> [UUID: Result<ProcessingGraph, ChainEditError>] {
        var out: [UUID: Result<ProcessingGraph, ChainEditError>] = [:]
        for c in connections {
            do { out[c.id] = .success(try movingInChain(node, onto: c.id)) }
            catch let e as ChainEditError { if e != .noChange { out[c.id] = .failure(e) } }
            catch { out[c.id] = .failure(.unknownNode) }
        }
        return out
    }

    // MARK: Transactional operations

    /// Moves an existing node onto the connection `connection` (X → Y becomes X → N → Y).
    /// Its former neighbors are linked together (A → N → B becomes A → B). Only its place
    /// in the routing changes: identifier, settings and plugin instance are kept.
    /// A free node (no connection) is simply inserted.
    public func movingInChain(_ id: UUID, onto connectionID: UUID, position: GraphPoint? = nil) throws -> ProcessingGraph {
        guard let n = node(id) else { throw ChainEditError.unknownNode }
        guard let target = connections.first(where: { $0.id == connectionID }) else { throw ChainEditError.unknownConnection }
        if n.kind.isUnique { throw ChainEditError.fixedNode }
        guard n.kind.hasInputPort && n.kind.hasOutputPort else { throw ChainEditError.invalidPorts }
        if target.from == id || target.to == id { throw ChainEditError.noChange }
        let ins = incoming(id), outs = outgoing(id)
        let free = ins.isEmpty && outs.isEmpty
        guard free || (ins.count == 1 && outs.count == 1) else { throw ChainEditError.notLinear }
        // A → N → B with a direct A → B connection already present: the A → B target is
        // where N already sits (and replacing it would remove the direct branch).
        if !free, target.from == ins[0].from, target.to == outs[0].to { throw ChainEditError.noChange }

        var g = self
        if !free {
            let a = ins[0].from, b = outs[0].to
            g.connections.removeAll { $0.id == ins[0].id || $0.id == outs[0].id }
            if !g.connections.contains(where: { $0.from == a && $0.to == b }) {
                g.connections.append(GraphConnection(from: a, to: b))
            }
        }
        try g.splice(id, on: target)
        if let position, let i = g.index(of: id) { g.nodes[i].position = position }
        return g
    }

    /// Adds a new node on the connection `connection` (X → Y becomes X → N → Y).
    public func inserting(_ node: GraphNode, on connectionID: UUID) throws -> ProcessingGraph {
        guard let target = connections.first(where: { $0.id == connectionID }) else { throw ChainEditError.unknownConnection }
        guard node.kind.hasInputPort && node.kind.hasOutputPort else { throw ChainEditError.invalidPorts }
        guard self.node(node.id) == nil else { throw ChainEditError.unknownNode }
        var g = self
        g.nodes.append(node)
        try g.splice(node.id, on: target)
        return g
    }

    /// Adds a new node at the end of the main chain, just before the virtual output.
    /// The connection chosen is the one ending the longest Input → Output path, so it is
    /// always the same for a given graph, even with several branches.
    public func appendingToMainChain(_ node: GraphNode) throws -> ProcessingGraph {
        guard node.kind.hasInputPort && node.kind.hasOutputPort else { throw ChainEditError.invalidPorts }
        guard let out = outputNode else { var g = self; g.nodes.append(node); return g }
        let chain = mainChain()
        var g = self
        var n = node
        let last: UUID? = chain.count >= 2 ? chain[chain.count - 2] : {
            // Output not fed by the input: extend the deepest node fed by the input
            // (or the input itself) and link it to the output.
            let depth = depthsFromInput()
            return processingOrder().filter { id in depth[id] != nil && (self.node(id)?.kind.hasOutputPort ?? false) }
                .max { (depth[$0] ?? 0) < (depth[$1] ?? 0) }
        }()
        guard let last, let src = self.node(last) else { g.nodes.append(n); return g }
        n.position = GraphPoint(x: src.position.x + 280, y: src.position.y)
        if let c = connections.first(where: { $0.from == last && $0.to == out.id }) {
            g = try g.inserting(n, on: c.id)
        } else {
            g.nodes.append(n)
            try g.link(last, n.id)
            try g.link(n.id, out.id)
        }
        // Shift the output to keep room to the right of the new node.
        if let oi = g.index(of: out.id), g.nodes[oi].position.x < n.position.x + 280 {
            g.nodes[oi].position.x = n.position.x + 280
        }
        return g
    }

    /// Removes a node; if it was on a linear section (A → N → B), links A → B.
    public func removingNode(_ id: UUID) throws -> ProcessingGraph {
        guard let n = node(id) else { throw ChainEditError.unknownNode }
        if n.kind == .input || n.kind == .output { throw ChainEditError.fixedNode }
        let ins = incoming(id).map(\.from), outs = outgoing(id).map(\.to)
        var g = self
        g.connections.removeAll { $0.from == id || $0.to == id }
        g.nodes.removeAll { $0.id == id }
        if ins.count == 1 && outs.count == 1 && !g.connections.contains(where: { $0.from == ins[0] && $0.to == outs[0] }) {
            try g.link(ins[0], outs[0])
        }
        return g
    }

    // MARK: Internals

    /// Replaces `target` (X → Y) with X → N → Y; N must have no connection.
    private mutating func splice(_ id: UUID, on target: GraphConnection) throws {
        connections.removeAll { $0.id == target.id }
        try link(target.from, id)
        try link(id, target.to)
        if topologicalOrder() == nil { throw ChainEditError.cycle }
    }

    /// Adds a valid connection or throws (never fails silently).
    private mutating func link(_ a: UUID, _ b: UUID) throws {
        do { try connect(from: a, to: b) }
        catch EditError.cycle { throw ChainEditError.cycle }
        catch EditError.invalidPorts { throw ChainEditError.invalidPorts }
        catch EditError.duplicate { return }
        catch { throw ChainEditError.unknownNode }
    }
}
