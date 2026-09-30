import SwiftUI
import Charts
import PerifitCore

struct LivePlot: View {
    @ObservedObject var model: SessionModel
    @Binding var rawChannels: Bool
    @Binding var seconds: Double
    private var end: Double { max(seconds, model.chart.last?.id ?? 0) }
    private var start: Double { max(0, end-seconds) }
    private var reports: [Feedback] {
        model.feedback.filter { !$0.removed && [.closer, .edge, .tooClose, .orgasm].contains($0.kind) && $0.time >= start && $0.time <= end }
    }
    var body: some View {
        let points = model.chart.filter { $0.id >= start && $0.id <= end }
        let maximum = max(1, points.reduce(rawChannels ? 0.0 : Double(model.controllerSettings.sensitivity)) {
            max($0, rawChannels ? max($1.base, $1.tip) : max($1.pressure, $1.score))
        }) * 1.05
        GroupBox("Live pressure") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Signals", selection: $rawChannels) {
                        Text("Both pressure channels").tag(true)
                        Text("Control signal + score").tag(false)
                    }.pickerStyle(.segmented).labelsHidden()
                    Picker("Window", selection: $seconds) {
                        Text("20s").tag(20.0); Text("60s").tag(60.0)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
                }
                if !reports.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(reports.suffix(3)) { report in
                            Text("\(report.kind.title) · \(report.time, specifier: "%.1f")s")
                                .font(.caption).monospacedDigit().foregroundStyle(markerColor(report.kind))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(markerColor(report.kind).opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                }
            Chart {
                RuleMark(y: .value("Baseline", 0)).foregroundStyle(.clear)
                    if !rawChannels {
                        RuleMark(y: .value("Edge reference", model.controllerSettings.effectiveEdgeTarget))
                            .foregroundStyle(.teal.opacity(0.65)).lineStyle(StrokeStyle(dash: [3, 3]))
                        RuleMark(y: .value("Near-orgasm cutoff", model.controllerSettings.sensitivity))
                            .foregroundStyle(.red.opacity(0.8)).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                    ForEach(reports) { report in
                        RuleMark(x: .value("Report", report.time)).foregroundStyle(markerColor(report.kind).opacity(0.6))
                            .lineStyle(StrokeStyle(dash: [3, 3]))
                    }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...maximum)
            .chartPlotStyle { plot in
                // Draw two paths instead of rebuilding 1,200 chart marks on the controller's thread.
                plot.background {
                    Canvas { context, size in
                        context.stroke(Self.signalPath(points, value: rawChannels ? \.base : \.pressure,
                            start: start, end: end, maximum: maximum, size: size), with: .color(.teal), lineWidth: 2)
                        context.stroke(Self.signalPath(points, value: rawChannels ? \.tip : \.score,
                            start: start, end: end, maximum: maximum, size: size),
                            with: .color(rawChannels ? .blue : .indigo), lineWidth: 2)
                    }.clipped()
                }
            }
            .chartLegend(.hidden)
            .chartXAxisLabel("Session seconds")
            .chartYAxisLabel(rawChannels ? "Sensor counts" : "Conditioned / heuristic units")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rawChannels ? "Live pressure channels" : "Live control signal and score")
            .accessibilityValue(rawChannels ? "Base \(model.sampleBase), tip \(model.sampleTip)" : "Pressure \(Int(points.last?.pressure ?? 0)), score \(model.snapshot.score)")
                .frame(height: 230).padding(.top, 12)
                HStack {
                    Label(rawChannels ? "Base pressure" : "Conditioned pressure", systemImage: "line.diagonal").foregroundStyle(.teal)
                    Label(rawChannels ? "Tip pressure" : "Heuristic score", systemImage: "line.diagonal").foregroundStyle(rawChannels ? .blue : .indigo)
                }.font(.caption)
                HStack {
                    Text("Base \(model.sampleBase) · Tip \(model.sampleTip)").monospacedDigit()
                    Spacer()
                    Text(model.snapshot.riskReason ?? model.snapshot.detectionName)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    static func signalPath(_ points: [ChartPoint], value: KeyPath<ChartPoint, Double>,
                           start: Double, end: Double, maximum: Double, size: CGSize) -> Path {
        var path = Path(), segment: Int?
        for point in points {
            let position = CGPoint(x: (point.id - start) / (end - start) * size.width,
                                   y: (1 - point[keyPath: value] / maximum) * size.height)
            if segment == point.segment { path.addLine(to: position) }
            else { path.move(to: position) }
            segment = point.segment
        }
        return path
    }
    private func markerColor(_ kind: FeedbackKind) -> Color {
        kind == .closer ? .indigo : kind == .edge ? .teal : kind == .tooClose ? .orange : .red
    }
}
