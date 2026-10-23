import Testing
import Foundation
import AVFoundation
@testable import VoxFlowAirCore

/// Node editor: visual position, audio order and connections stay separate;
/// every chain operation is transactional (refusal = graph intact).
@Suite("Node editor: chain order")
struct ChainEditTests {
    /// Input → A → B → C → Output, named nodes so the order can be read.
    static func linear(_ names: [String] = ["A", "B", "C"]) -> (ProcessingGraph, [String: UUID]) {
        var g = ProcessingGraph.testGraph()
        let gain = g.nodes.first { $0.kind == .gain }!.id
        g.removeNode(gain)
        var ids: [String: UUID] = ["In": g.inputNode!.id, "Out": g.outputNode!.id]
        for n in names {
            let node = GraphNode(kind: .gain, title: n, position: .init(x: 0, y: 0), parameters: ["gain": 0])
            let ok = g.appendToMainChain(node)
            #expect(ok)
            ids[n] = node.id
        }
        return (g, ids)
    }

    static func titles(_ g: ProcessingGraph, _ chain: [UUID]) -> [String] {
        chain.map { id in
            let n = g.node(id)!
            return n.kind == .input ? "In" : (n.kind == .output ? "Out" : n.title)
        }
    }

    static func conn(_ g: ProcessingGraph, _ a: UUID, _ b: UUID) -> GraphConnection {
        g.connections.first { $0.from == a && $0.to == b }!
    }

    /// Routing only (no positions or connection identifiers).
    static func routing(_ g: ProcessingGraph) -> Set<[UUID]> { Set(g.connections.map { [$0.from, $0.to] }) }

    @Test("Visual move: no change to routing or order")
    func visualMoveKeepsRouting() {
        let (g, ids) = Self.linear()
        var moved = g
        for i in moved.nodes.indices { moved.nodes[i].position = GraphPoint(x: Double.random(in: -900...900), y: Double.random(in: -900...900)) }
        #expect(Self.routing(moved) == Self.routing(g))
        #expect(moved.connections == g.connections)
        #expect(moved.mainChain() == g.mainChain())
        #expect(moved.processingOrder() == g.processingOrder())
        #expect(Self.titles(moved, moved.mainChain()) == ["In", "A", "B", "C", "Out"])
        _ = ids
    }

    @Test("Linear reorder: C before A")
    func linearReorder() throws {
        let (g, ids) = Self.linear()
        let target = Self.conn(g, ids["In"]!, ids["A"]!)
        let r = try g.movingInChain(ids["C"]!, onto: target.id)
        #expect(Self.titles(r, r.mainChain()) == ["In", "C", "A", "B", "Out"])
        #expect(r.connections.count == g.connections.count, "no connection lost or added")
        #expect(GraphValidator.validate(r).filter { $0.severity >= .warning }.isEmpty)
        // Nodes keep their identity and settings.
        #expect(r.node(ids["C"]!) == g.node(ids["C"]!))
        // Optional visual position, independent of routing.
        let p = GraphPoint(x: 1234, y: 56)
        let r2 = try g.movingInChain(ids["C"]!, onto: target.id, position: p)
        #expect(r2.node(ids["C"]!)?.position == p)
        #expect(Self.routing(r2) == Self.routing(r))
    }

    @Test("Reorder: move A to the end of the chain and back")
    func moveToEndAndBack() throws {
        let (g, ids) = Self.linear()
        let end = try #require(g.mainChainConnection(into: ids["Out"]!))
        let r = try g.movingInChain(ids["A"]!, onto: end.id)
        #expect(Self.titles(r, r.mainChain()) == ["In", "B", "C", "A", "Out"])
        let back = try r.movingInChain(ids["A"]!, onto: Self.conn(r, ids["In"]!, ids["B"]!).id)
        #expect(Self.titles(back, back.mainChain()) == ["In", "A", "B", "C", "Out"])
        #expect(Self.routing(back) == Self.routing(g))
    }

    @Test("Inserting a new effect between two effects")
    func insertBetween() throws {
        let (g, ids) = Self.linear()
        let x = GraphNode(kind: .analyzer, title: "X", position: .init(x: 0, y: 0))
        let r = try g.inserting(x, on: Self.conn(g, ids["A"]!, ids["B"]!).id)
        #expect(Self.titles(r, r.mainChain()) == ["In", "A", "X", "B", "C", "Out"])
        // A node with no output (monitoring output) cannot be inserted: graph intact.
        let mon = GraphNode(kind: .monitorOutput, position: .init(x: 0, y: 0))
        #expect(throws: ChainEditError.invalidPorts) { _ = try g.inserting(mon, on: Self.conn(g, ids["A"]!, ids["B"]!).id) }
        var legacy = g
        let inserted = legacy.insert(mon, on: Self.conn(g, ids["A"]!, ids["B"]!).id)
        #expect(!inserted)
        #expect(legacy == g, "the old API no longer removes the connection on failure")
    }

    @Test("Appending to the chain: always right before the output, deterministic with branches")
    func appendDeterministic() throws {
        var (g, ids) = Self.linear(["A", "B"])
        // Short parallel branch: In → P → Out.
        let p = GraphNode(kind: .gain, title: "P", position: .init(x: 0, y: 0))
        g.addNode(p)
        try g.connect(from: ids["In"]!, to: p.id)
        try g.connect(from: p.id, to: ids["Out"]!)
        // Whatever the order of the connections array, the main chain is the longest one.
        for _ in 0..<5 {
            var shuffled = g
            shuffled.connections.shuffle()
            #expect(Self.titles(shuffled, shuffled.mainChain()) == ["In", "A", "B", "Out"])
            let z = GraphNode(kind: .gain, title: "Z", position: .init(x: 0, y: 0))
            let r = try shuffled.appendingToMainChain(z)
            #expect(Self.titles(r, r.mainChain()) == ["In", "A", "B", "Z", "Out"])
            #expect(r.incoming(ids["Out"]!).contains { $0.from == p.id }, "branch P is kept")
        }
        // Output disconnected: the node is connected to the end of the chain and to the output.
        var cut = g
        cut.connections.removeAll { $0.to == ids["Out"]! }
        let z = GraphNode(kind: .gain, title: "Z", position: .init(x: 0, y: 0))
        let r = try cut.appendingToMainChain(z)
        #expect(Self.titles(r, r.mainChain()) == ["In", "A", "B", "Z", "Out"])
    }

    @Test("Branches: kept by a move, branch node refused without changes")
    func branchesPreserved() throws {
        var (g, ids) = Self.linear()
        // A also feeds a dedicated monitoring output: A is a branch node.
        let mon = GraphNode(kind: .monitorOutput, position: .init(x: 0, y: 0))
        g.addNode(mon)
        try g.connect(from: ids["A"]!, to: mon.id)
        // Moving C before B leaves the A → Monitoring branch alone.
        let r = try g.movingInChain(ids["C"]!, onto: Self.conn(g, ids["A"]!, ids["B"]!).id)
        #expect(Self.titles(r, r.mainChain()) == ["In", "A", "C", "B", "Out"])
        #expect(r.connections.contains { $0.from == ids["A"]! && $0.to == mon.id })
        // A has two outputs: explicit refusal, graph intact.
        #expect(throws: ChainEditError.notLinear) { _ = try g.movingInChain(ids["A"]!, onto: Self.conn(g, ids["C"]!, ids["Out"]!).id) }
        #expect(g.moveInChainError(ids["A"]!, onto: Self.conn(g, ids["C"]!, ids["Out"]!).id) == .notLinear)
    }

    @Test("Drop targets: every connection except adjacent ones, preview = real operation")
    func dropTargets() throws {
        // Real chain of 7 effects, the 7th (“F6”) is dropped before the 1st.
        let names = ["E1", "E2", "E3", "E4", "E5", "E6", "F6"]
        let (g, ids) = Self.linear(names)
        let targets = g.chainDropTargets(for: ids["F6"]!)
        // 8 connections, 2 of which touch F6 (E6 → F6, F6 → Out): 6 targets, all valid.
        #expect(g.connections.count == 8)
        #expect(targets.count == 6)
        #expect(targets.values.allSatisfy { if case .success = $0 { true } else { false } })
        #expect(targets[Self.conn(g, ids["E6"]!, ids["F6"]!).id] == nil)
        #expect(targets[Self.conn(g, ids["F6"]!, ids["Out"]!).id] == nil)
        let first = Self.conn(g, ids["In"]!, ids["E1"]!)
        let preview = try targets[first.id]!.get()
        #expect(Self.titles(preview, preview.mainChain()) == ["In", "F6", "E1", "E2", "E3", "E4", "E5", "E6", "Out"])
        #expect(Self.routing(preview) == Self.routing(try g.movingInChain(ids["F6"]!, onto: first.id)), "same routing as the real app")
        #expect(preview.node(ids["F6"]!) == g.node(ids["F6"]!), "node settings kept")
        // Branch node: no valid target, each refusal carries its reason.
        var b = g
        let mon = GraphNode(kind: .monitorOutput, position: .init(x: 0, y: 0))
        b.addNode(mon)
        try b.connect(from: ids["E3"]!, to: mon.id)
        let refused = b.chainDropTargets(for: ids["E3"]!)
        #expect(!refused.isEmpty)
        #expect(refused.values.allSatisfy { if case .failure(.notLinear) = $0 { true } else { false } })
        // Input / output: fixed place everywhere.
        #expect(g.chainDropTargets(for: ids["In"]!).values.allSatisfy { if case .failure(.fixedNode) = $0 { true } else { false } })
    }

    @Test("Direct parallel: dropping a node on the connection that bypasses it does not remove the branch")
    func parallelDirectKept() throws {
        var (g, ids) = Self.linear()
        try g.connect(from: ids["A"]!, to: ids["C"]!) // A → C in parallel with A → B → C
        let direct = Self.conn(g, ids["A"]!, ids["C"]!)
        #expect(throws: ChainEditError.noChange) { _ = try g.movingInChain(ids["B"]!, onto: direct.id) }
    }

    @Test("Refusals: fixed input/output, adjacent connection has no effect, unknown node or connection")
    func refusals() {
        let (g, ids) = Self.linear()
        let c = Self.conn(g, ids["A"]!, ids["B"]!)
        #expect(throws: ChainEditError.fixedNode) { _ = try g.movingInChain(ids["In"]!, onto: c.id) }
        #expect(throws: ChainEditError.fixedNode) { _ = try g.movingInChain(ids["Out"]!, onto: c.id) }
        #expect(throws: ChainEditError.noChange) { _ = try g.movingInChain(ids["A"]!, onto: c.id) }
        #expect(throws: ChainEditError.noChange) { _ = try g.movingInChain(ids["B"]!, onto: c.id) }
        #expect(throws: ChainEditError.unknownNode) { _ = try g.movingInChain(UUID(), onto: c.id) }
        #expect(throws: ChainEditError.unknownConnection) { _ = try g.movingInChain(ids["A"]!, onto: UUID()) }
        // Half-connected node (one input only): refusal rather than silently losing the connection.
        var half = g
        let h = GraphNode(kind: .gain, title: "H", position: .init(x: 0, y: 0))
        half.addNode(h)
        try? half.connect(from: ids["A"]!, to: h.id)
        #expect(throws: ChainEditError.notLinear) { _ = try half.movingInChain(h.id, onto: Self.conn(half, ids["B"]!, ids["C"]!).id) }
    }

    @Test("Free node dropped on a connection: inserted")
    func freeNodeInserted() throws {
        var (g, ids) = Self.linear()
        let f = GraphNode(kind: .gain, title: "F", position: .init(x: 0, y: 0))
        g.addNode(f)
        let r = try g.movingInChain(f.id, onto: Self.conn(g, ids["B"]!, ids["C"]!).id)
        #expect(Self.titles(r, r.mainChain()) == ["In", "A", "B", "F", "C", "Out"])
    }

    @Test("Cycle refused without changing the graph")
    func cycleRefused() throws {
        var (g, ids) = Self.linear()
        let before = g
        #expect(throws: ProcessingGraph.EditError.cycle) { _ = try g.connect(from: ids["C"]!, to: ids["A"]!) }
        #expect(g == before)
        #expect(g.connectionError(from: ids["C"]!, to: ids["A"]!) == .cycle)
        #expect(g.connectionError(from: ids["A"]!, to: ids["C"]!) == nil, "branch A → C valid")
    }

    @Test("Invalid connections refused with a readable reason")
    func invalidConnections() {
        let (g, ids) = Self.linear()
        #expect(g.connectionError(from: ids["Out"]!, to: ids["A"]!) == .invalidPorts)
        #expect(g.connectionError(from: ids["A"]!, to: ids["In"]!) == .invalidPorts)
        #expect(g.connectionError(from: ids["A"]!, to: ids["A"]!) == .selfLoop)
        #expect(g.connectionError(from: ids["A"]!, to: ids["B"]!) == .duplicate)
        #expect(g.connectionError(from: UUID(), to: ids["B"]!) == .unknownNode)
    }

    @Test("Removal: neighbors reconnected, refused for the input and output")
    func removal() throws {
        let (g, ids) = Self.linear()
        let r = try g.removingNode(ids["B"]!)
        #expect(Self.titles(r, r.mainChain()) == ["In", "A", "C", "Out"])
        #expect(throws: ChainEditError.fixedNode) { _ = try g.removingNode(ids["In"]!) }
        #expect(throws: ChainEditError.fixedNode) { _ = try g.removingNode(ids["Out"]!) }
    }

    @Test("Displayed order = order imposed by the connections (topological)")
    func displayedOrderIsTopological() throws {
        var (g, ids) = Self.linear()
        let mon = GraphNode(kind: .monitorOutput, position: .init(x: 0, y: 0))
        g.addNode(mon)
        try g.connect(from: ids["B"]!, to: mon.id)
        g = try g.movingInChain(ids["C"]!, onto: Self.conn(g, ids["In"]!, ids["A"]!).id)
        let order = g.processingOrder()
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for c in g.connections { #expect(rank[c.from]! < rank[c.to]!, "every connection goes downstream") }
        let chain = g.mainChain()
        #expect(chain.map { rank[$0]! } == chain.map { rank[$0]! }.sorted(), "the displayed chain follows the processing order")
        #expect(g.reorderableMainChain() == [ids["C"]!, ids["A"]!, ids["B"]!])
    }

    @Test("Saving and reloading: identical positions, connections and order")
    func persistence() throws {
        var (g, ids) = Self.linear()
        g = try g.movingInChain(ids["C"]!, onto: Self.conn(g, ids["In"]!, ids["A"]!).id, position: GraphPoint(x: 77, y: 88))
        let dir = tempDir()
        let store = PresetStore(directory: dir)
        let p = try store.create(name: "Order", graph: g)
        let r = try #require(PresetStore(directory: dir).load().first { $0.id == p.id })
        #expect(r.graph == g)
        #expect(r.graph.node(ids["C"]!)?.position == GraphPoint(x: 77, y: 88))
        #expect(Self.titles(r.graph, r.graph.mainChain()) == ["In", "C", "A", "B", "Out"])
        #expect(r.formatVersion == 1, "the preset format does not change")
    }

    @Test("Compatibility: factory presets and the user's presets (copied) read back identically")
    func presetCompatibility() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources = [repo.appendingPathComponent("Tests/VoxFlowAirCoreTests/Fixtures")]
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoxFlowAir/Presets")
        if fm.fileExists(atPath: user.path) { sources.append(user) }
        // Copied to a temporary folder: the originals are never opened for writing.
        let copy = tempDir()
        var count = 0
        for dir in sources {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == PresetStore.fileExtension {
                let dest = copy.appendingPathComponent("\(count)-\(f.lastPathComponent)")
                try fm.copyItem(at: f, to: dest)
                count += 1
                let p = try PresetMigrator.decode(Data(contentsOf: dest))
                let again = try PresetMigrator.decode(PresetMigrator.encode(p))
                #expect(again.graph == p.graph, "\(f.lastPathComponent): identical round trip")
                #expect(p.graph.topologicalOrder() != nil, "\(f.lastPathComponent): no loop")
                // The main chain read by the new editor follows the existing connections.
                let chain = p.graph.mainChain()
                for (a, b) in zip(chain, chain.dropFirst()) {
                    #expect(p.graph.connections.contains { $0.from == a && $0.to == b }, "\(p.name): consistent chain")
                }
            }
        }
        print("Presets read back:", count)
        #expect(count >= 1)
    }
}

@Suite("Node editor: engine", .serialized)
@MainActor
struct ChainEngineTests {
    init() { setenv("VOXFLOWAIR_SUPPORT_DIR", tempDir().path, 1) }

    func engine() -> VoxFlowAirEngine {
        let dir = tempDir()
        let e = VoxFlowAirEngine(presetDirectory: dir.appendingPathComponent("p"), settingsURL: dir.appendingPathComponent("s.json"))
        e.launch(startAudio: false)
        return e
    }

    @Test("Engine: visual move without rewiring, undoable reorder, refusal without changes")
    func engineMoves() throws {
        let e = engine()
        defer { e.shutdown() }
        let a = try #require(e.addNode(kind: .gain, appendToChain: true))
        let b = try #require(e.addNode(kind: .analyzer, appendToChain: true))
        let routing = e.graph.connections
        e.moveNodes([a: GraphPoint(x: 999, y: 999)], registerUndo: true)
        #expect(e.graph.connections == routing, "visual move: identical routing")
        #expect(e.graph.node(a)?.position == GraphPoint(x: 999, y: 999))

        let into = try #require(e.graph.mainChainConnection(into: a))
        #expect(e.moveInChain(b, onto: into.id) == nil)
        let order = e.graph.reorderableMainChain()
        #expect(order.firstIndex(of: b)! < order.firstIndex(of: a)!)
        e.undo()
        #expect(e.graph.connections == routing, "⌘Z restores the previous order")

        // Refusal: the graph does not change and a notice is posted.
        let before = e.graph
        let notices = e.notices.count
        #expect(e.moveInChain(e.graph.inputNode!.id, onto: into.id) == .fixedNode)
        #expect(e.graph == before)
        #expect(e.notices.count == notices + 1)
        // Inspector: move before a node / to the end of the chain.
        #expect(e.moveInMainChain(b, before: a) == nil)
        let o2 = e.graph.reorderableMainChain()
        #expect(o2.firstIndex(of: b)! + 1 == o2.firstIndex(of: a)!)
        #expect(e.moveInMainChain(b, before: nil) == nil)
        #expect(e.graph.reorderableMainChain().last == b)
    }

    @Test("Audio: after a drop on a connection, the engine processes in the new order, plugin settings kept")
    func audioFollowsNewOrder() throws {
        // +20 dB → limiter → −20 dB: peaks brought down to about 0.1. The −20 dB (3rd) dropped before the 1st:
        // −20 dB → +20 dB → limiter, the 0.5 sine passes intact. So the order is audible at the virtual output.
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let limiter = AVAudioUnitEffect(audioComponentDescription: desc)
        let decay = try #require(limiter.auAudioUnit.parameterTree?.allParameters.first { $0.identifier.lowercased().contains("decay") } ?? limiter.auAudioUnit.parameterTree?.allParameters.first)
        decay.value = decay.minValue + (decay.maxValue - decay.minValue) * 0.37
        let setting = decay.value
        var g = ProcessingGraph.testGraph()
        g.removeNode(g.nodes.first { $0.kind == .gain }!.id)
        let up = GraphNode(kind: .gain, title: "+20", position: .init(x: 0, y: 0), parameters: ["gain": 20])
        let lim = GraphNode(kind: .audioUnit, title: "Limiter", position: .init(x: 0, y: 0))
        let down = GraphNode(kind: .gain, title: "-20", position: .init(x: 0, y: 0), parameters: ["gain": -20])
        for n in [up, lim, down] { let ok = g.appendToMainChain(n); #expect(ok) }
        let h = try ProcessorHarness(graph: g, plugins: [lim.id: limiter])
        h.run(cycles: 60)
        let before = ProcessorHarness.peak(h.vL)

        let first = try #require(g.mainChainConnection(into: up.id))
        let moved = try #require(g.chainDropTargets(for: down.id)[first.id]).get()
        #expect(ChainEditTests.titles(moved, moved.mainChain()) == ["In", "-20", "+20", "Limiter", "Out"])
        _ = h.runtime.apply(moved, plugins: [lim.id: limiter], pluginStatus: [:])
        h.run(cycles: 60)
        let after = ProcessorHarness.peak(h.vL)
        print("Virtual output peak: before \(before), after \(after)")
        #expect(before < 0.2, "initial order: limited then −20 dB")
        #expect(approx(after, 0.5, tol: 0.05), "new order: −20 dB then +20 dB, below the limiter threshold")
        #expect(decay.value == setting, "plugin setting kept (same instance)")
    }

    @Test("Engine: a reorder does not reload the plugin (same instance)")
    func pluginInstanceKept() async throws {
        let e = engine()
        defer { e.shutdown() }
        let info = try #require(e.plugins.first { $0.name == "AUDelay" } ?? e.plugins.first { $0.manufacturer == "Apple" })
        let p = try #require(e.addNode(kind: .audioUnit, plugin: info.reference, appendToChain: true))
        let g = try #require(e.addNode(kind: .gain, appendToChain: true))
        for _ in 0..<100 where e.pluginUnit(for: p) == nil { try await Task.sleep(for: .milliseconds(50)) }
        let unit = try #require(e.pluginUnit(for: p), "Apple plugin loaded")
        let into = try #require(e.graph.mainChainConnection(into: p))
        #expect(e.moveInChain(g, onto: into.id) == nil)
        #expect(e.pluginUnit(for: p) === unit, "same instance after the move")
        #expect(e.nodeStatus[p] == .ok)
        e.moveNodes([p: GraphPoint(x: 5, y: 5)], registerUndo: true)
        #expect(e.pluginUnit(for: p) === unit)
    }
}
