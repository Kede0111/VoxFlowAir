import Foundation
import AVFoundation

/// Records the raw signal (input, after input gain) and the processed signal
/// (chain output) simultaneously as 32-bit float WAV, to compare by ear and
/// analyze the chain on a real voice take.
/// The analysis buffers are read off the audio thread.
public final class ComparisonRecorder: @unchecked Sendable {
    public struct Result: Sendable { public let raw: URL; public let processed: URL; public let seconds: Double; public let gaps: Int }

    public static var directory: URL {
        let d = AppPaths.applicationSupport.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private let queue = DispatchQueue(label: "voxflowair.recorder", qos: .userInitiated)
    public private(set) var isRecording = false

    public init() {}

    public func record(meters: EngineMeters, sampleRate: Double, seconds: Double, label: String,
                       completion: @escaping (Result?, Error?) -> Void) {
        guard !isRecording else { completion(nil, RuntimeError(String(localized: "A recording is already in progress"))); return }
        isRecording = true
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = Self.directory.appendingPathComponent("\(stamp)-\(label)")
        let rawURL = base.appendingPathExtension("raw.wav"), procURL = base.appendingPathExtension("processed.wav")
        queue.async {
            do {
                let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
                let fRaw = try AVAudioFile(forWriting: rawURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let fProc = try AVAudioFile(forWriting: procURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let total = Int(seconds * sampleRate)
                var posIn = meters.inputTap.left.totalWritten, posOut = meters.outputTap.left.totalWritten
                var done = 0, gaps = 0
                let chunk = 4096
                let bIn = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
                let bOut = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
                func pull(_ tap: StereoAnalysisTap, _ pos: inout Int, _ buf: AVAudioPCMBuffer, _ file: AVAudioFile, max limit: Int) throws -> Int {
                    let avail = tap.left.totalWritten - pos
                    if avail > tap.left.capacity - chunk { gaps += 1; pos = tap.left.totalWritten - chunk } // fell behind: skip
                    let n = min(chunk, tap.left.totalWritten - pos, limit)
                    guard n > 0 else { return 0 }
                    _ = tap.left.read(from: pos, count: n, into: buf.floatChannelData![0])
                    _ = tap.right.read(from: pos, count: n, into: buf.floatChannelData![1])
                    buf.frameLength = AVAudioFrameCount(n)
                    try file.write(from: buf)
                    pos += n
                    return n
                }
                while done < total {
                    let a = try pull(meters.inputTap, &posIn, bIn, fRaw, max: total - done)
                    // The output follows the input (same audio cycle): write the same number of frames.
                    var b = 0
                    while b < a { let k = try pull(meters.outputTap, &posOut, bOut, fProc, max: a - b); if k == 0 { Thread.sleep(forTimeInterval: 0.005) }; b += k }
                    done += a
                    if a == 0 { Thread.sleep(forTimeInterval: 0.02) }
                }
                self.isRecording = false
                vlog(.info, "Comparison recording: \(rawURL.lastPathComponent) / \(procURL.lastPathComponent) (\(seconds) s, \(gaps) skip(s))")
                completion(Result(raw: rawURL, processed: procURL, seconds: seconds, gaps: gaps), nil)
            } catch {
                self.isRecording = false
                completion(nil, error)
            }
        }
    }
}
