import Foundation

/// Local diagnostic control (off by default): active only if the file
/// "~/Library/Application Support/VoxFlowAir/control/ENABLED" exists.
/// A JSON command dropped in control/command.json is executed and the response
/// written to control/response.json. Used by automated stability tests
/// (buffer, preset loading, statistics, recording).
@MainActor
public final class LocalControl {
    public static var directory: URL { AppPaths.applicationSupport.appendingPathComponent("control", isDirectory: true) }
    private weak var engine: VoxFlowAirEngine?
    private var timer: Timer?
    private let recorder = ComparisonRecorder()
    /// Extra commands provided by the app (name → handler, response merged).
    public var extraCommands: [String: ([String: Any]) -> [String: Any]] = [:]

    public init(engine: VoxFlowAirEngine) { self.engine = engine }

    public func start() {
        let dir = Self.directory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("ENABLED").path) else { return }
        vlog(.warning, "Local diagnostic control ACTIVE (\(dir.path)).")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let cmdURL = Self.directory.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: cmdURL),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(at: cmdURL)
        guard let e = engine else { return }
        var out: [String: Any] = ["cmd": cmd["cmd"] ?? "", "date": ISO8601DateFormatter().string(from: Date())]
        switch cmd["cmd"] as? String {
        case "reloadPresets":
            out["presets"] = e.reloadPresetsFromDisk().map(\.name)
        case "loadPreset":
            if let name = cmd["name"] as? String, let p = e.presets.first(where: { $0.name == name }) { e.loadPreset(p.id); out["ok"] = true }
            else { out["ok"] = false }
        case "setBuffer":
            if let f = cmd["frames"] as? Int { e.setBufferFrames(f); out["ok"] = true }
        case "resetCounters":
            e.resetCounters(); out["ok"] = true
        case "bypass":
            e.bypassProcessing = (cmd["on"] as? Bool) ?? false; out["ok"] = true
        case "record":
            let sec = (cmd["seconds"] as? Double) ?? 20
            recorder.record(meters: e.processor.meters, sampleRate: e.latency.sampleRate, seconds: sec, label: (cmd["label"] as? String) ?? "test") { r, err in
                let o: [String: Any] = r.map { ["raw": $0.raw.path, "processed": $0.processed.path, "gaps": $0.gaps] } ?? ["error": "\(err.map { "\($0)" } ?? "?")"]
                Self.write(o, name: "record.json")
            }
            out["ok"] = true
        default:
            if let name = cmd["cmd"] as? String, let handler = extraCommands[name] {
                out.merge(handler(cmd)) { $1 }
            }
        }
        out["stats"] = e.statsSnapshot()
        Self.write(out, name: "response.json")
    }

    static func write(_ obj: [String: Any], name: String) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}
