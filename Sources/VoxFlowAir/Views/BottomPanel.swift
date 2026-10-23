import SwiftUI
import VoxFlowAirCore

/// Bottom area: input | analyzers | loudness | output.
/// The dividers can be dragged with the mouse (widths are remembered). When space runs short, the
/// cards switch to a compact layout, then the loudness column collapses: nothing gets clipped.
struct BottomPanel: View {
    @AppStorage("bottomPanel.ioWidth") private var ioWidth: Double = 220
    @AppStorage("bottomPanel.loudnessWidth") private var loudnessWidth: Double = 170

    static let ioMin = 140.0, ioMax = 340.0, loudMin = 140.0, loudMax = 280.0, analyzerMin = 300.0, gap = 8.0

    var body: some View {
        GeometryReader { g in
            let avail = max(g.size.width - 20, 0)
            let showLoudness = avail >= 2 * Self.ioMin + Self.analyzerMin + Self.loudMin + 3 * Self.gap
            let loud = showLoudness ? min(max(loudnessWidth, Self.loudMin), Self.loudMax) : 0
            let room = avail - Self.analyzerMin - loud - (showLoudness ? 3 : 2) * Self.gap
            let io = max(min(ioWidth, Self.ioMax, room / 2), Self.ioMin)
            // All widths are explicit: their sum fits exactly in the available space.
            let analyzer = max(avail - 2 * io - loud - (showLoudness ? 3 : 2) * Self.gap, 0)
            HStack(spacing: 0) {
                IOCard(isInput: true, compact: io < 200).frame(width: io)
                PanelDivider(help: "Drag to widen the input and output") { ioWidth = clampIO(ioWidth + $0) }
                AnalyzerCard().frame(width: analyzer).clipped()
                if showLoudness {
                    PanelDivider(help: "Drag to adjust the loudness width") { loudnessWidth = min(max(loudnessWidth - $0, Self.loudMin), Self.loudMax) }
                    LoudnessColumn().frame(width: loud)
                }
                PanelDivider(help: "Drag to widen the input and output") { ioWidth = clampIO(ioWidth - $0) }
                IOCard(isInput: false, compact: io < 200).frame(width: io)
            }
            .padding(10)
        }
    }

    func clampIO(_ v: Double) -> Double { min(max(v, Self.ioMin), Self.ioMax) }
}

/// Draggable divider between two cards of the bottom panel.
struct PanelDivider: View {
    let help: LocalizedStringKey
    let onDrag: (Double) -> Void
    @State private var last: CGFloat = 0
    @State private var hover = false
    var body: some View {
        Capsule().fill(hover ? VF.accent.opacity(0.7) : VF.border)
            .frame(width: 2, height: 28)
            .frame(width: BottomPanel.gap)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in onDrag(Double(v.translation.width - last)); last = v.translation.width }
                .onEnded { _ in last = 0 })
            .help(help)
            .accessibilityHidden(true)
    }
}

extension AppState {
    var analysisTap: StereoAnalysisTap? {
        switch analysisSource {
        case .input: return engine.processor.meters.inputTap
        case .output: return engine.processor.meters.outputTap
        case .node(let id): return engine.analyzerTap(for: id) ?? engine.processor.meters.outputTap
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(VF.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VF.border))
    }
}

/// Input or Output card: meter, value, actual waveform, format.
struct IOCard: View {
    @Environment(AppState.self) private var app
    let isInput: Bool
    /// Narrow layout: meter and value only, no waveform or format.
    var compact = false
    var body: some View {
        let e = app.engine
        let m = app.meters
        let level = isInput ? m.input : m.virtualOut
        let tap = isInput ? e.processor.meters.inputTap : e.processor.meters.outputTap
        let clip = isInput ? m.clipInput : m.clipOutput
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isInput ? "mic" : "dot.radiowaves.left.and.right").foregroundStyle(VF.text2)
                    Text("\(Text(isInput ? "Input: " : "Output: ").foregroundStyle(VF.text2))\(Text(isInput ? (e.activeInput?.name ?? "—") : (e.activeVirtual?.name ?? String(localized: "none"))))")
                        .truncationMode(.tail)
                        .help(isInput ? (e.activeInput?.name ?? "") : (e.activeVirtual?.name ?? ""))
                    Spacer(minLength: 2)
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).foregroundStyle(VF.text3)
                }
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 8) {
                    HorizontalMeter(level: level).frame(height: 14)
                    Text(level.maxPeak > 0.000_001 ? String(format: "%.1f dB", linearToDB(level.maxPeak)) : "-∞")
                        .font(.system(size: compact ? 12 : 14, weight: .medium, design: .monospaced)).lineLimit(1).fixedSize()
                        .frame(minWidth: compact ? 52 : 66, alignment: .trailing)
                    Circle().fill(clip ? VF.danger : VF.panel3).frame(width: 8, height: 8)
                        .onTapGesture { m.resetClips() }.help(clip ? "Clipping — click to clear" : "No clipping")
                }
                if compact {
                    WaveformStrip(tap: tap, color: VF.accent)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
                    Text(formatLine(isInput: isInput)).font(.system(size: 10, design: .monospaced)).foregroundStyle(VF.text2).lineLimit(1)
                } else {
                HStack(spacing: 10) {
                    WaveformStrip(tap: tap, color: VF.accent).frame(minWidth: 60)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.latency.sampleRate > 0 ? String(format: "%.1f kHz", e.latency.sampleRate / 1000) : "— kHz")
                        let bits = isInput ? e.inputBitDepth : e.virtualBitDepth
                        Text(bits.map { "\($0) bits" } ?? "— bits").help("Device bit depth; internal processing in 32-bit float")
                        if !isInput && e.settings.muteVirtual { Text("MUTE").foregroundStyle(VF.danger).bold() }
                        if !isInput {
                            switch e.loopbackStatus {
                            case .confirmed: Label("verified", systemImage: "checkmark.seal.fill").foregroundStyle(VF.ok).help(e.loopbackStatus.label)
                            case .noReturn: Label("no return", systemImage: "exclamationmark.triangle.fill").foregroundStyle(VF.danger).help(e.loopbackStatus.label)
                            default: EmptyView()
                            }
                        }
                    }
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(VF.text2).frame(width: 62, alignment: .leading)
                }
                }
            }
            .padding(10)
        }
    }

    func formatLine(isInput: Bool) -> String {
        let e = app.engine
        let khz = e.latency.sampleRate > 0 ? String(format: "%.1f kHz", e.latency.sampleRate / 1000) : "— kHz"
        let bits = (isInput ? e.inputBitDepth : e.virtualBitDepth).map { "\($0) b" } ?? "— b"
        var parts = [khz, bits]
        if !isInput && e.settings.muteVirtual { parts.append("MUTE") }
        if !isInput, case .confirmed = e.loopbackStatus { parts.append(String(localized: "verified ✓")) }
        return parts.joined(separator: " · ")
    }
}

/// Scrolling waveform (peak envelope of the actual signal).
struct WaveformStrip: View {
    let tap: StereoAnalysisTap
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            // Reading the date is required: otherwise SwiftUI does not redraw the Canvas on every tick.
            let now = timeline.date
            Canvas { ctx, size in
                _ = now
                let n = 8192
                var buf = [Float](repeating: 0, count: n)
                buf.withUnsafeMutableBufferPointer { _ = tap.left.readLatest(into: $0.baseAddress!, count: n) }
                let cols = max(Int(size.width / 2), 1)
                let per = n / cols
                let mid = size.height / 2
                var p = Path()
                for c in 0..<cols {
                    var pk: Float = 0
                    for k in 0..<per { pk = max(pk, abs(buf[c * per + k])) }
                    let h = max(CGFloat(meterFraction(pk)) * mid * 0.95, 0.5)
                    let x = CGFloat(c) * 2 + 1
                    p.move(to: .init(x: x, y: mid - h)); p.addLine(to: .init(x: x, y: mid + h))
                }
                ctx.stroke(p, with: .color(color.opacity(0.85)), lineWidth: 1.2)
            }
        }
    }
}

struct AnalyzerCard: View {
    @Environment(AppState.self) private var app

    var tabs: some View {
        tabPicker.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
    }

    var tabMenu: some View {
        tabPicker.pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
    }

    var tabPicker: some View {
        @Bindable var a = app
        return Picker("View", selection: $a.bottomTab) {
            ForEach(AppState.BottomTab.allCases) { t in Text(t.title).tag(t) }
        }
    }

    var sourcePicker: some View {
        @Bindable var a = app
        return Picker("Source", selection: $a.analysisSource) {
            Text("Output (processed)").tag(AppState.AnalysisSource.output)
            Text("Input (mic)").tag(AppState.AnalysisSource.input)
            ForEach(app.engine.graph.nodes.filter { $0.kind == .analyzer }) { n in
                Text("Analyzer: \(n.title)").tag(AppState.AnalysisSource.node(n.id))
            }
        }
        .labelsHidden().controlSize(.small)
    }

    var sourceMenu: some View {
        Menu { sourcePicker.pickerStyle(.inline) } label: { Image(systemName: "scope") }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .help("Analyzed source")
    }

    var body: some View {
        @Bindable var a = app
        Card {
            VStack(spacing: 0) {
                // Native tab headers (system segmented control); when space runs short,
                // the source moves into a compact menu, then the tabs into a menu.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { tabs; Spacer(minLength: 6); sourcePicker.frame(width: 140) }
                    HStack(spacing: 6) { tabs; Spacer(minLength: 4); sourceMenu }
                    HStack(spacing: 6) { tabMenu; Spacer(minLength: 4); sourceMenu }
                }
                .padding(6)
                Divider().overlay(VF.border)
                Group {
                    switch app.bottomTab {
                    case .levels: LevelsView()
                    case .spectrum: SpectrumView()
                    case .scope: ScopeView()
                    case .loudness: CorrelationView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct LevelsView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let m = app.meters
        let e = app.engine
        HStack(alignment: .top, spacing: 14) {
            MeterScale().padding(.top, 11).padding(.bottom, 30)
            VerticalMeter(title: "INPUT", level: m.input, clip: m.clipInput, onClipReset: m.resetClips)
            VerticalMeter(title: "PROCESSED", level: m.processed, clip: m.clipOutput, dimmed: e.bypassProcessing, onClipReset: m.resetClips)
            VerticalMeter(title: "VIRTUAL", level: m.virtualOut, dimmed: e.settings.muteVirtual)
            VerticalMeter(title: "PHONES", level: m.monitorOut, dimmed: !e.settings.monitorEnabled)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                gainRow("Input gain", value: Binding(get: { e.settings.inputGainDB }, set: { e.settings.inputGainDB = ($0 * 2).rounded() / 2 }), range: -24...24)
                gainRow("Virtual output", value: Binding(get: { e.settings.virtualGainDB }, set: { e.settings.virtualGainDB = ($0 * 2).rounded() / 2 }), range: -40...12)
                gainRow("Monitoring", value: Binding(get: { e.settings.monitorGainDB }, set: { e.settings.monitorGainDB = ($0 * 2).rounded() / 2 }), range: -60...12)
                HStack(spacing: 12) {
                    stat("Load", String(format: "%.0f %%", m.load * 100))
                    stat("Overloads", "\(m.overloads)")
                    stat("Near overruns", "\(m.nearOverruns)")
                    stat("Errors", "\(m.renderErrors + m.inputErrors)")
                    Button("Reset") { e.resetCounters(); m.resetClips() }.controlSize(.small)
                }
                HStack {
                    Button { app.recordComparison(seconds: 20) } label: {
                        Label(app.recordingUntil == nil ? "Record 20 s (Raw + Processed)" : "Recording…", systemImage: "record.circle")
                    }
                    .controlSize(.small).disabled(app.recordingUntil != nil)
                    .help("Records the unprocessed microphone and the processed signal at the same time (WAV) to compare by ear.")
                    if app.lastRecording != nil {
                        Button("Show in Finder") { if let r = app.lastRecording { NSWorkspace.shared.activateFileViewerSelecting([r.raw, r.processed]) } }.controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    func gainRow(_ t: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(t).font(VF.small).foregroundStyle(VF.text2).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
            Text(formatDB(value.wrappedValue)).font(VF.mono).frame(width: 64, alignment: .trailing)
            Button { value.wrappedValue = 0 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help(Text(verbatim: "0 dB"))
        }
    }

    func stat(_ k: LocalizedStringKey, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9)).foregroundStyle(VF.text3)
            Text(v).font(VF.mono)
        }
    }
}

/// Spectrum analyzer (4096-point FFT, log scale).
struct SpectrumView: View {
    @Environment(AppState.self) private var app
    @State private var analyzer = SpectrumAnalyzer(size: 4096)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            // Reading the date is required: otherwise SwiftUI does not redraw the Canvas on every tick.
            let now = timeline.date
            Canvas { ctx, size in
                _ = now
                guard let tap = app.analysisTap else { return }
                let sr = max(app.engine.latency.sampleRate, 44100)
                let db = analyzer.update(from: tap.left)
                let left: CGFloat = 28, bottom: CGFloat = 16
                let w = size.width - left, h = size.height - bottom
                let minF = 20.0, maxF = min(20000, sr / 2)
                func x(_ f: Double) -> CGFloat { left + CGFloat(log10(f / minF) / log10(maxF / minF)) * w }
                func y(_ d: Float) -> CGFloat { h * CGFloat(1 - (min(max(d, -90), 0) + 90) / 90) }
                for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] where f <= maxF {
                    let px = x(f)
                    ctx.stroke(Path { $0.move(to: .init(x: px, y: 0)); $0.addLine(to: .init(x: px, y: h)) }, with: .color(VF.grid), lineWidth: 1)
                    ctx.draw(Text(verbatim: f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9)).foregroundStyle(VF.text3), at: .init(x: px, y: size.height - 7))
                }
                for d in stride(from: 0, through: -80, by: -20) {
                    let py = y(Float(d))
                    ctx.stroke(Path { $0.move(to: .init(x: left, y: py)); $0.addLine(to: .init(x: size.width, y: py)) }, with: .color(VF.grid), lineWidth: 1)
                    ctx.draw(Text(verbatim: "\(d)").font(.system(size: 9)).foregroundStyle(VF.text3), at: .init(x: 12, y: py))
                }
                var path = Path()
                var started = false
                for i in 1..<db.count {
                    let f = analyzer.frequency(bin: i, sampleRate: sr)
                    if f < minF || f > maxF { continue }
                    let p = CGPoint(x: x(f), y: y(db[i]))
                    if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                }
                var fill = path
                fill.addLine(to: .init(x: size.width, y: h)); fill.addLine(to: .init(x: left, y: h))
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [VF.accent.opacity(0.45), VF.accent.opacity(0.04)]), startPoint: .zero, endPoint: .init(x: 0, y: h)))
                ctx.stroke(path, with: .color(VF.accent), lineWidth: 1.4)
            }
        }
        .padding(8)
    }
}

/// Oscilloscope (triggered on rising zero crossing).
struct ScopeView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            // Reading the date is required: otherwise SwiftUI does not redraw the Canvas on every tick.
            let now = timeline.date
            Canvas { ctx, size in
                _ = now
                guard let tap = app.analysisTap else { return }
                var l = [Float](repeating: 0, count: 4096), r = l
                l.withUnsafeMutableBufferPointer { _ = tap.left.readLatest(into: $0.baseAddress!, count: 4096) }
                r.withUnsafeMutableBufferPointer { _ = tap.right.readLatest(into: $0.baseAddress!, count: 4096) }
                let window = 1024
                var start = 4096 - window - 1
                var i = 4096 - window - 1
                while i > 1 { if l[i - 1] < 0 && l[i] >= 0 { start = i; break }; i -= 1 }
                let mid = size.height / 2
                ctx.stroke(Path { $0.move(to: .init(x: 0, y: mid)); $0.addLine(to: .init(x: size.width, y: mid)) }, with: .color(VF.grid))
                for (buf, color) in [(r, VF.warn.opacity(0.7)), (l, VF.ok)] {
                    var p = Path()
                    for k in 0..<window {
                        let px = CGFloat(k) / CGFloat(window) * size.width
                        let py = mid - CGFloat(buf[start + k]) * mid * 0.95
                        if k == 0 { p.move(to: .init(x: px, y: py)) } else { p.addLine(to: .init(x: px, y: py)) }
                    }
                    ctx.stroke(p, with: .color(color), lineWidth: 1.2)
                }
                ctx.draw(Text(verbatim: "L").font(.system(size: 10, weight: .bold)).foregroundStyle(VF.ok), at: .init(x: 12, y: 12))
                ctx.draw(Text(verbatim: "R").font(.system(size: 10, weight: .bold)).foregroundStyle(VF.warn), at: .init(x: 26, y: 12))
                ctx.draw(Text(String(format: "%.1f ms", Double(window) / max(app.engine.latency.sampleRate, 1) * 1000)).font(.system(size: 9)).foregroundStyle(VF.text3), at: .init(x: size.width - 30, y: 12))
            }
        }
        .padding(8)
    }
}

/// Goniometer (M/S Lissajous) and phase correlation.
struct CorrelationView: View {
    @Environment(AppState.self) private var app
    @State private var correlation: Float = 0
    var body: some View {
        HStack(spacing: 24) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                // Reading the date is required: otherwise SwiftUI does not redraw the Canvas on every tick.
                let now = timeline.date
                Canvas { ctx, size in
                    _ = now
                    guard let tap = app.analysisTap else { return }
                    let n = 2048
                    var l = [Float](repeating: 0, count: n), r = l
                    l.withUnsafeMutableBufferPointer { _ = tap.left.readLatest(into: $0.baseAddress!, count: n) }
                    r.withUnsafeMutableBufferPointer { _ = tap.right.readLatest(into: $0.baseAddress!, count: n) }
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), rad = min(size.width, size.height) / 2 * 0.9
                    ctx.stroke(Path { $0.move(to: .init(x: c.x, y: c.y - rad)); $0.addLine(to: .init(x: c.x, y: c.y + rad)) }, with: .color(VF.grid))
                    ctx.stroke(Path { $0.move(to: .init(x: c.x - rad, y: c.y)); $0.addLine(to: .init(x: c.x + rad, y: c.y)) }, with: .color(VF.grid))
                    var p = Path()
                    for k in stride(from: 0, to: n, by: 2) {
                        let side = CGFloat(l[k] - r[k]) * 0.707, mid = CGFloat(l[k] + r[k]) * 0.707
                        p.addRect(CGRect(x: c.x + side * rad, y: c.y - mid * rad, width: 1.2, height: 1.2))
                    }
                    ctx.fill(p, with: .color(VF.ok.opacity(0.7)))
                }
            }
            .frame(width: 130)
            VStack(alignment: .leading, spacing: 6) {
                Text("Phase correlation").font(VF.label).foregroundStyle(VF.text2)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(VF.panel3)
                        Rectangle().fill(VF.text3).frame(width: 1).offset(x: g.size.width / 2)
                        Circle().fill(correlation < 0 ? VF.danger : VF.ok).frame(width: 10, height: 10)
                            .offset(x: (CGFloat(correlation) + 1) / 2 * (g.size.width - 10))
                    }
                }.frame(height: 14)
                HStack { Text(verbatim: "-1"); Spacer(); Text(verbatim: "0"); Spacer(); Text(verbatim: "+1") }.font(.system(size: 9)).foregroundStyle(VF.text3)
                Text(String(format: "%+.2f", correlation)).font(.system(size: 22, weight: .medium, design: .monospaced))
                Text("A duplicated mono microphone reads +1. A negative value indicates a phase inversion.")
                    .font(.system(size: 10)).foregroundStyle(VF.text3)
            }
            .frame(maxWidth: 280)
            Spacer()
        }
        .padding(12)
        .onReceive(Timer.publish(every: 1 / 15, on: .main, in: .common).autoconnect()) { _ in
            if let tap = app.analysisTap { correlation = stereoCorrelation(left: tap.left, right: tap.right, count: 4096) }
        }
    }
}

/// EBU R128 loudness column (always visible): integrated, LRA, true peak, momentary.
struct LoudnessColumn: View {
    @Environment(AppState.self) private var app
    @State private var meter: LoudnessMeter?
    @State private var lastSource: AppState.AnalysisSource?
    @State private var values = (m: -Double.infinity, s: -Double.infinity, i: -Double.infinity, lra: 0.0, tp: -Double.infinity)
    @State private var gap = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: "LUFS (\(sourceName))").font(.system(size: 10)).foregroundStyle(VF.text2)
                    Spacer()
                    Button { meter?.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).foregroundStyle(VF.text3).help("Reset the integrated measurement")
                }
                HStack(alignment: .top, spacing: 10) {
                    lufsBar(values.m).frame(width: 14)
                    lufsBar(values.s).frame(width: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        big(values.i, "INT")
                        big(values.lra, "LRA", isRange: true)
                        big(values.tp, "TP")
                        Text(String(format: "M %@  S %@", fmt(values.m), fmt(values.s)))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(VF.text3)
                    }
                }
                if gap { Text("Signal gap: approximate measurement").font(.system(size: 9)).foregroundStyle(VF.warn) }
            }
            .padding(10)
        }
        .help("ITU-R BS.1770 / EBU R128 loudness: INT = integrated (gates -70 / -10), LRA = loudness range, TP = approximate true peak (×4), M = 400 ms, S = 3 s.")
        .onReceive(Timer.publish(every: 1 / 15, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    var sourceName: String {
        switch app.analysisSource { case .input: return String(localized: "input"); case .output: return String(localized: "output"); case .node: return String(localized: "analyzer") }
    }

    func fmt(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "—" }

    func big(_ v: Double, _ unit: String, isRange: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isRange ? String(format: "%.1f", v) : fmt(v)).font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(unit == "TP" && v > -1 ? VF.danger : VF.text)
            Text(unit).font(.system(size: 10, weight: .semibold)).foregroundStyle(VF.text2)
        }
    }

    func lufsBar(_ v: Double) -> some View {
        GeometryReader { g in
            let frac = v.isFinite ? CGFloat(min(max((v + 60) / 60, 0), 1)) : 0
            ZStack(alignment: .bottom) {
                Rectangle().fill(VF.panel3)
                MeterGradient.fillV.mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * frac) }
                Rectangle().fill(VF.text2).frame(height: 1).offset(y: -g.size.height * CGFloat(44.0 / 60.0)) // -16 LUFS marker
            }.clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    func tick() {
        guard let tap = app.analysisTap else { return }
        let sr = app.engine.latency.sampleRate > 0 ? app.engine.latency.sampleRate : 48000
        if meter == nil || meter!.sampleRate != sr || lastSource != app.analysisSource {
            meter = LoudnessMeter(sampleRate: sr); lastSource = app.analysisSource
        }
        let mtr = meter!
        mtr.update(left: tap.left, right: tap.right)
        values = (mtr.momentaryLUFS, mtr.shortTermLUFS, mtr.integratedLUFS, mtr.loudnessRange, mtr.truePeakDB)
        gap = mtr.gapDetected
    }
}
