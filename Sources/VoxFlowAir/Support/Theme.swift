import SwiftUI
import AppKit
import VoxFlowAirCore

/// VoxFlowAir palette: dark by default (visual reference), with a light variant.
/// Colors are there to read routing and state, not to decorate.
enum VF {
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
    static let bg = dyn(0x0E1013, 0xEEF0F3)
    static let canvas = dyn(0x121519, 0xF6F7F9)
    static let grid = dyn(0x1C2026, 0xE2E5EA)
    static let panel = dyn(0x171A1F, 0xFFFFFF)
    static let panel2 = dyn(0x1D2127, 0xF3F4F6)
    static let panel3 = dyn(0x252A31, 0xE8EAEE)
    static let border = dyn(0x2A3038, 0xD5D9DF)
    static let text = dyn(0xE7E9EC, 0x16191D)
    static let text2 = dyn(0x9AA3AE, 0x5B6470)
    static let text3 = dyn(0x6B7480, 0x8A929C)
    static let accent = dyn(0x4FA3FF, 0x1F7AE0)
    static let ok = dyn(0x3DD68C, 0x15A05E)
    static let warn = dyn(0xF5B53F, 0xC77F00)
    static let danger = dyn(0xF0555A, 0xD3313A)
    static let wire = dyn(0x7FB2E8, 0x3D7FC4)
    static let wireInactive = dyn(0x3A424D, 0xB8BFC8)

    /// Readable text on a solid tint (green, orange: dark text; red, blue: white).
    static func onTint(_ c: Color) -> Color {
        // WCAG relative luminance; keep the text color (black or white) with the most contrast.
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(ns.redComponent) + 0.7152 * lin(ns.greenComponent) + 0.0722 * lin(ns.blueComponent)
        let onBlack = (l + 0.05) / 0.05, onWhite = 1.05 / (l + 0.05)
        return onBlack >= onWhite ? Color.black.opacity(0.88) : .white
    }

    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let small = Font.system(size: 11)
    static let label = Font.system(size: 12, weight: .medium)
    static let title = Font.system(size: 13, weight: .semibold)

    static func color(for node: GraphNode, category: PluginCategory?) -> Color {
        switch node.kind {
        case .input: return dyn(0x2EC4B6, 0x109C8F)
        case .output: return dyn(0x4FA3FF, 0x1F7AE0)
        case .monitorOutput: return dyn(0xA78BFA, 0x7C5BD9)
        case .gain: return dyn(0x9AA8B8, 0x66768A)
        case .analyzer: return dyn(0xE3B341, 0xB8860B)
        case .audioUnit: return color(for: category ?? .other)
        }
    }

    static func color(for c: PluginCategory) -> Color {
        switch c {
        case .dynamics: return dyn(0xF59E0B, 0xC67C00)
        case .eq: return dyn(0x34D399, 0x0E9F6E)
        case .filter: return dyn(0x22D3EE, 0x0891B2)
        case .saturation: return dyn(0xF87171, 0xDC2626)
        case .temporal: return dyn(0x8B5CF6, 0x6D28D9)
        case .voice: return dyn(0xF472B6, 0xDB2777)
        case .pitch: return dyn(0xC084FC, 0x9333EA)
        case .utility: return dyn(0x94A3B8, 0x64748B)
        case .analyzer: return dyn(0xEAB308, 0xA16207)
        case .other: return dyn(0x7C8796, 0x64748B)
        }
    }

    static let groupColors: [Color] = [dyn(0x4FA3FF, 0x1F7AE0), dyn(0x34D399, 0x0E9F6E), dyn(0xF59E0B, 0xC67C00),
                                       dyn(0xF472B6, 0xDB2777), dyn(0x8B5CF6, 0x6D28D9), dyn(0x22D3EE, 0x0891B2)]

    static func symbol(for node: GraphNode, category: PluginCategory?) -> String {
        switch node.kind {
        case .input: return "mic.fill"
        case .output: return "arrow.up.forward.app"
        case .monitorOutput: return "headphones"
        case .gain: return "dial.medium"
        case .analyzer: return "waveform.badge.magnifyingglass"
        case .audioUnit: return (category ?? .other).symbol
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

func formatDB(_ db: Double, decimals: Int = 1) -> String {
    if db <= -119 { return "-∞" }
    return String(format: "%+.\(decimals)f dB", db)
}

func formatLevel(_ linear: Float) -> String {
    let db = linearToDB(linear)
    return db <= -119 ? "-∞" : String(format: "%.1f", db)
}

/// Main command button (Monitoring / Mute / Bypass), in native Liquid Glass:
/// tinted `.glassProminent` when the command is on, neutral `.glass` otherwise. The state stays
/// readable without color: different icon (slashed when off), label and indicator light.
/// The action runs immediately on click, with no blocking animation.
struct CommandToggle: View {
    let title: String
    let systemImage: String
    /// Icon when the command is off (nil: same icon).
    var offImage: String? = nil
    let isOn: Bool
    let onColor: Color
    /// Compact version (toolbar, menu bar): smaller text and margins.
    var compact = false
    var help: String = ""
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let label = HStack(spacing: compact ? 4 : 6) {
            Image(systemName: isOn ? systemImage : (offImage ?? systemImage))
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .frame(width: compact ? 13 : 16)
            Text(title).font(.system(size: compact ? 10 : 11, weight: .bold)).tracking(compact ? 0.3 : 0.6).lineLimit(1).fixedSize()
            // State indicator (filled / hollow shape): redundant with the color.
            Image(systemName: isOn ? "circle.fill" : "circle")
                .font(.system(size: 5, weight: .bold))
                .opacity(isOn ? 1 : 0.55)
        }
        .padding(.horizontal, compact ? 0 : 4)
        .frame(minWidth: compact ? 0 : 88)

        Group {
            if isOn {
                Button(action: action) { label.foregroundStyle(VF.onTint(onColor)) }
                    .buttonStyle(.glassProminent)
                    .tint(onColor)
            } else {
                Button(action: action) { label.foregroundStyle(contrast == .increased ? VF.text : VF.text2) }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(compact ? .small : .regular)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct PanelHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(VF.text3)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}
