import Foundation
import AVFoundation
@testable import VoxFlowAirCore

/// Hardware-free test bench: feeds the real-time processor with a synthetic
/// signal and collects the virtual and monitoring outputs.
final class ProcessorHarness {
    let processor = RealtimeProcessor(maxFrames: 4096)
    var runtime: GraphRuntime!
    let frames = 512
    let sampleRate: Double = 48000
    var inL: [Float], inR: [Float]
    var vL: [Float], vR: [Float], mL: [Float], mR: [Float]
    private var phase: Double = 0

    init(graph: ProcessingGraph = .testGraph(), plugins: [UUID: AVAudioUnit] = [:]) throws {
        inL = .init(repeating: 0, count: frames); inR = inL
        vL = inL; vR = inL; mL = inL; mR = inL
        runtime = try GraphRuntime(sampleRate: sampleRate, processor: processor)
        _ = runtime.apply(graph, plugins: plugins, pluginStatus: [:])
    }

    /// Generates a 1 kHz sine of amplitude `amp` and runs `cycles` cycles.
    func run(cycles: Int = 20, amp: Float = 0.5, freq: Double = 1000) {
        for _ in 0..<cycles {
            for i in 0..<frames {
                let v = Float(sin(phase)) * amp
                inL[i] = v; inR[i] = v
                phase += 2 * .pi * freq / sampleRate
            }
            inL.withUnsafeBufferPointer { l in inR.withUnsafeBufferPointer { r in
                vL.withUnsafeMutableBufferPointer { vl in vR.withUnsafeMutableBufferPointer { vr in
                    mL.withUnsafeMutableBufferPointer { ml in mR.withUnsafeMutableBufferPointer { mr in
                        processor.process(frames: frames, inL: l.baseAddress, inR: r.baseAddress,
                                          virtualL: vl.baseAddress, virtualR: vr.baseAddress,
                                          monitorL: ml.baseAddress, monitorR: mr.baseAddress)
                    }}
                }}
            }}
        }
    }

    static func peak(_ a: [Float]) -> Float { a.map(abs).max() ?? 0 }
    static func rms(_ a: [Float]) -> Float { sqrt(a.map { $0 * $0 }.reduce(0, +) / Float(max(a.count, 1))) }
}

func approx(_ a: Float, _ b: Float, tol: Float = 0.02) -> Bool { abs(a - b) <= tol }

extension ProcessingGraph {
    /// Input → Gain → Output: the minimal chain most tests start from.
    static func testGraph() -> ProcessingGraph {
        let input = GraphNode(kind: .input, position: GraphPoint(x: 80, y: 220))
        let gain = GraphNode(kind: .gain, position: GraphPoint(x: 360, y: 220), parameters: ["gain": 0])
        let output = GraphNode(kind: .output, position: GraphPoint(x: 640, y: 220))
        return ProcessingGraph(nodes: [input, gain, output],
                               connections: [GraphConnection(from: input.id, to: gain.id),
                                             GraphConnection(from: gain.id, to: output.id)])
    }
}
