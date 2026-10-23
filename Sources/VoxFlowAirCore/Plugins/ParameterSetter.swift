import Foundation
import AVFoundation

/// Sets an AU parameter by its display name and its *displayed* value
/// (e.g. "Threshold" = "-18.0"), regardless of the plugin's internal scale
/// (Waves often exposes 0…1000). The value actually applied is read back.
public enum ParameterSetter {
    public struct Applied: CustomStringConvertible, Sendable {
        public let name: String
        public let requested: String
        public let shown: String
        public let raw: Float
        public let ok: Bool
        public var description: String { "\(name) = \(shown)\(ok ? "" : "  ⚠︎ requested \(requested)")" }
    }

    public static func parameter(_ au: AUAudioUnit, _ name: String) -> AUParameter? {
        let all = au.parameterTree?.allParameters ?? []
        return all.first { $0.displayName == name } ?? all.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static func number(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let lower = cleaned.lowercased()
        if lower.hasPrefix("-inf") { return -1e9 }
        if lower.hasPrefix("inf") || lower.hasPrefix("+inf") || lower == "∞" { return 1e9 }
        var num = ""
        for ch in cleaned { if ch.isNumber || ch == "." || ch == "-" || ch == "+" { num.append(ch) } else if !num.isEmpty { break } }
        return Double(num)
    }

    @discardableResult
    public static func set(_ au: AUAudioUnit, _ name: String, _ target: String) -> Applied {
        guard let p = parameter(au, name) else { return Applied(name: name, requested: target, shown: "NOT FOUND", raw: .nan, ok: false) }
        // "raw:<value>": the plugin's internal value, for non-monotonic or clamped displays.
        if target.hasPrefix("raw:"), let v = Float(target.dropFirst(4)) {
            p.setValue(min(max(v, p.minValue), p.maxValue), originator: nil)
            let shown = p.currentValueString
            return Applied(name: p.displayName, requested: target, shown: shown, raw: p.value, ok: true)
        }
        if let strings = p.valueStrings, let idx = strings.firstIndex(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
            p.setValue(p.minValue + AUValue(idx), originator: nil)
        } else if let t = number(target) {
            // Binary search on the internal scale (display assumed monotonic).
            var lo = p.minValue, hi = p.maxValue
            let vLo = number(p.string(fromValue: &lo)) ?? 0, vHi = number(p.string(fromValue: &hi)) ?? 0
            let increasing = vHi >= vLo
            for _ in 0..<50 {
                var mid = (lo + hi) / 2
                let v = number(p.string(fromValue: &mid)) ?? 0
                if (v < t) == increasing { lo = mid } else { hi = mid }
            }
            var a = lo, b = hi
            let da = abs((number(p.string(fromValue: &a)) ?? 0) - t), db = abs((number(p.string(fromValue: &b)) ?? 0) - t)
            p.setValue(da <= db ? a : b, originator: nil)
        }
        let shown = p.currentValueString
        let ok: Bool = {
            if let strings = p.valueStrings, strings.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) { return shown.caseInsensitiveCompare(target) == .orderedSame }
            guard let a = number(shown), let b = number(target) else { return shown == target }
            return abs(a - b) <= max(0.06 * abs(b), 0.11)
        }()
        return Applied(name: p.displayName, requested: target, shown: shown, raw: p.value, ok: ok)
    }

    /// Reads back the displayed value of each requested parameter.
    public static func read(_ au: AUAudioUnit, _ names: [String]) -> [String: String] {
        var r: [String: String] = [:]
        for n in names { if let p = parameter(au, n) { r[n] = p.currentValueString } }
        return r
    }
}

extension AUParameter {
    /// Current value as the plugin displays it (e.g. "-18.0 dB").
    /// Passes the value explicitly: `string(fromValue: nil)` sends a null pointer
    /// to the plugin (allowed by the AU spec) and some JUCE plugins (Ablaze Screamer)
    /// dereference it and crash.
    public var currentValueString: String {
        var v = value
        return string(fromValue: &v)
    }
}
