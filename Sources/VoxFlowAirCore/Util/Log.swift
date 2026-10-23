import Foundation
import os

/// Diagnostic log: unified logging (Console.app) + a text file in
/// ~/Library/Logs/VoxFlowAir/VoxFlowAir.log. Never called from the audio thread.
public final class VFLog: @unchecked Sendable {
    public static let shared = VFLog()

    public enum Level: String { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "app")
    private let queue = DispatchQueue(label: "voxflowair.log")
    private var handle: FileHandle?
    public let fileURL: URL
    private var recent: [String] = []
    private let maxRecent = 500

    private init() {
        // VOXFLOWAIR_SUPPORT_DIR (tests): log kept apart from real data.
        let dir = ProcessInfo.processInfo.environment["VOXFLOWAIR_SUPPORT_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("Logs", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoxFlowAir", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("VoxFlowAir.log")
        // Simple rotation beyond 5 MB.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 5_000_000 {
            let old = dir.appendingPathComponent("VoxFlowAir.1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: fileURL, to: old)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    public func log(_ level: Level, _ message: String, file: String = #fileID) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let line = "\(ts) [\(level.rawValue)] \(message)"
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        queue.async {
            self.recent.append(line)
            if self.recent.count > self.maxRecent { self.recent.removeFirst(self.recent.count - self.maxRecent) }
            if let data = (line + "\n").data(using: .utf8) { try? self.handle?.write(contentsOf: data) }
        }
    }

    public func recentLines() -> [String] { queue.sync { recent } }
}

@inline(__always) public func vlog(_ level: VFLog.Level = .info, _ message: String) { VFLog.shared.log(level, message) }
