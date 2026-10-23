import Foundation
import Testing
import CoreAudio
@testable import VoxFlowAirCore

@Suite("Buffer between two clocks (virtual output, call return)")
struct DriftRingTests {
    /// Ramp: sample n has value n, so the read position can be read from the output.
    func push(_ ring: DriftRing, from start: Int, count n: Int) {
        let l = (0..<n).map { Float(start + $0) }
        l.withUnsafeBufferPointer { p in ring.push(p.baseAddress!, p.baseAddress!, count: n) }
    }

    @Test("After an underrun, reading resumes where it stopped, without replaying")
    func noReplayAfterUnderrun() {
        let ring = DriftRing()
        ring.prepare(producerFrames: 64, consumerFrames: 64)   // target 448
        var out = [Float](repeating: 0, count: 2 * 256)
        push(ring, from: 0, count: 600)
        var last: Float = -1
        var played = 0
        // Read until empty (underrun).
        while out.withUnsafeMutableBufferPointer({ ring.pull(into: $0.baseAddress!, stride: 2, frames: 256) }) {
            last = out[2 * 255]; played += 1
        }
        #expect(played >= 1)
        #expect(ring.underruns.value == 1)
        // The producer resumes: no value already played may reappear.
        push(ring, from: 600, count: 2000)
        #expect(out.withUnsafeMutableBufferPointer { ring.pull(into: $0.baseAddress!, stride: 2, frames: 256) })
        #expect(out[0] > last)
    }

    @Test("Nothing is read until the target is reached")
    func waitsForTarget() {
        let ring = DriftRing()
        ring.prepare(producerFrames: 256, consumerFrames: 256)   // target 576
        push(ring, from: 1, count: 500)
        var out = [Float](repeating: 1, count: 2 * 128)
        #expect(!out.withUnsafeMutableBufferPointer { ring.pull(into: $0.baseAddress!, stride: 2, frames: 128) })
        #expect(out.allSatisfy { $0 == 0 })
    }
}

/// Call return on the real BlackHole: `VOXFLOWAIR_HW=1`. Writes a tone into BlackHole for 2 s.
@Suite("Call return (hardware)", .enabled(if: ProcessInfo.processInfo.environment["VOXFLOWAIR_HW"] == "1"))
struct CallReturnHardwareTests {
    @Test("What plays into BlackHole comes out in the headphone mix")
    func blackHoleToMonitor() throws {
        guard let bh = AudioDeviceManager.deviceID(forUID: "BlackHole2ch_UID") else { return }
        let reader = CallReturnReader()
        try reader.start(deviceID: bh, name: "BlackHole 2ch", sampleRate: 48000, bufferFrames: 256)
        defer { reader.stop() }
        // “FaceTime”: 440 Hz tone at −20 dBFS played into BlackHole.
        var phase = 0.0
        var tone: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&tone, bh, nil) { _, _, _, out, _ in
            for b in UnsafeMutableAudioBufferListPointer(out) {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize) / 4 / max(ch, 1)
                for i in 0..<n { let v = Float(0.1 * sin(phase)); phase += 2 * .pi * 440 / 48000; for c in 0..<ch { p[i * ch + c] = v } }
            }
        }
        AudioDeviceStart(bh, tone)
        defer { AudioDeviceStop(bh, tone); AudioDeviceDestroyIOProcID(bh, tone!) }
        // “Engine”: 256-frame cycles at the 48 kHz rate.
        var l = [Float](repeating: 0, count: 256), r = l
        var loud = 0, cycles = 0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 2 {
            l = [Float](repeating: 0, count: 256); r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in reader.mix(intoL: lp.baseAddress!, r: rp.baseAddress!, frames: 256) } }
            if cycles > 40, (l.map { abs($0) }.max() ?? 0) > 0.05 { loud += 1 }
            cycles += 1
            Thread.sleep(forTimeInterval: 256.0 / 48000)
        }
        print("Call return: \(loud)/\(cycles - 41) cycles with the tone, underruns \(reader.ring.underruns.value)")
        #expect(Double(loud) > Double(cycles - 41) * 0.9)
    }
}
