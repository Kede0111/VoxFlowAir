import SwiftUI
import VoxFlowAirCore

/// Meter scale: -60 dBFS … 0 dBFS.
func meterFraction(_ linear: Float) -> CGFloat {
    let db = linearToDB(linear)
    return CGFloat(min(max((db + 60) / 60, 0), 1))
}

struct MeterGradient {
    static let fill = LinearGradient(stops: [
        .init(color: Color(red: 0.20, green: 0.80, blue: 0.55), location: 0),
        .init(color: Color(red: 0.20, green: 0.80, blue: 0.55), location: 0.70),
        .init(color: Color(red: 0.96, green: 0.76, blue: 0.25), location: 0.88),
        .init(color: Color(red: 0.94, green: 0.33, blue: 0.35), location: 1.0),
    ], startPoint: .leading, endPoint: .trailing)
    static let fillV = LinearGradient(stops: [
        .init(color: Color(red: 0.20, green: 0.80, blue: 0.55), location: 0),
        .init(color: Color(red: 0.20, green: 0.80, blue: 0.55), location: 0.70),
        .init(color: Color(red: 0.96, green: 0.76, blue: 0.25), location: 0.88),
        .init(color: Color(red: 0.94, green: 0.33, blue: 0.35), location: 1.0),
    ], startPoint: .bottom, endPoint: .top)
}

/// Compact horizontal stereo bar (nodes, menu bar).
struct HorizontalMeter: View {
    let level: MeterHub.Level
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 1) {
                bar(level.peakL, hold: level.holdL, w: geo.size.width)
                bar(level.peakR, hold: level.holdR, w: geo.size.width)
            }
        }
    }
    func bar(_ v: Float, hold: Float, w: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(VF.panel3)
            MeterGradient.fill.mask(alignment: .leading) { Rectangle().frame(width: w * meterFraction(v)) }
            Rectangle().fill(VF.text).frame(width: 1.5).offset(x: max(0, w * meterFraction(hold) - 1.5)).opacity(hold > 0.001 ? 0.8 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
    }
}

/// Vertical stereo meter with scale, peak hold and clip indicator.
struct VerticalMeter: View {
    let title: LocalizedStringKey
    let level: MeterHub.Level
    var clip: Bool = false
    var dimmed: Bool = false
    var onClipReset: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 5) {
            Button { onClipReset?() } label: {
                RoundedRectangle(cornerRadius: 2).fill(clip ? VF.danger : VF.panel3).frame(width: 30, height: 6)
            }.buttonStyle(.plain).help(clip ? "Clipping detected — click to reset" : "No clipping")
            HStack(alignment: .bottom, spacing: 3) {
                channel(level.peakL, rms: level.rmsL, hold: level.holdL)
                channel(level.peakR, rms: level.rmsR, hold: level.holdR)
            }
            .opacity(dimmed ? 0.35 : 1)
            Text(formatLevel(level.maxPeak)).font(.system(size: 10, design: .monospaced)).foregroundStyle(VF.text2)
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.text2).lineLimit(1)
        }
    }

    func channel(_ peak: Float, rms: Float, hold: Float) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(VF.panel3)
                MeterGradient.fillV.mask(alignment: .bottom) { Rectangle().frame(height: h * meterFraction(peak)) }.opacity(0.55)
                MeterGradient.fillV.mask(alignment: .bottom) { Rectangle().frame(height: h * meterFraction(rms)) }
                Rectangle().fill(VF.text).frame(height: 1.5).offset(y: -max(0, h * meterFraction(hold) - 1.5)).opacity(hold > 0.001 ? 0.9 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(width: 13)
    }
}

struct MeterScale: View {
    var body: some View {
        GeometryReader { geo in
            ForEach([0, -6, -12, -18, -24, -36, -48, -60], id: \.self) { db in
                Text(verbatim: "\(db)").font(.system(size: 8, design: .monospaced)).foregroundStyle(VF.text3)
                    .position(x: 10, y: geo.size.height * (1 - CGFloat(db + 60) / 60))
            }
        }
        .frame(width: 20)
    }
}
