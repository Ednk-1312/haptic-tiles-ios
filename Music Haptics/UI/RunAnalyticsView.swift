import SwiftUI

/// Analytics for one gameplay run, computed locally from the run's replay
/// events. No telemetry — everything stays on device.
struct RunAnalyticsView: View {
    let analytics: RunAnalytics
    let title: String
    let difficulty: DifficultyLevel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                statGrid
                distribution
                timelineStrip
                progression
                sectionBreakdown
                Text("Analytics are computed locally from this run's gameplay events. Nothing is transmitted.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Run Analytics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(difficulty.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(difficultyColor, in: Capsule())
            Text(String(format: "%.1f%% accuracy", analytics.accuracy * 100))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)
                .padding(.top, 2)
            if analytics.judgedCount > 0 {
                Text("\(analytics.judgedCount) judged notes · mean |error| \(String(format: "%.0f", analytics.meanAbsErrorMs)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No judged notes in this run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var difficultyColor: Color {
        switch difficulty {
        case .easy: return .green.opacity(0.25)
        case .casual: return .mint.opacity(0.25)
        case .medium: return .blue.opacity(0.25)
        case .hard: return .orange.opacity(0.25)
        case .expert: return .red.opacity(0.25)
        case .extreme: return .purple.opacity(0.25)
        }
    }

    // MARK: - Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            statBox(value: String(format: "%.0f", analytics.meanAbsErrorMs), unit: "ms",
                    label: "Mean |err|", color: .primary)
            statBox(value: "\(signedBalance(analytics.earlyLateBalance))",
                    unit: "early − late", label: "Balance", color: balanceColor)
            statBox(value: "\(analytics.maxCombo)", unit: "max",
                    label: "Combo", color: .orange)
            statBox(value: "\(analytics.earlyCount)", unit: "taps",
                    label: "Early", color: .red)
            statBox(value: "\(analytics.accurateCount)", unit: "taps",
                    label: "Accurate", color: .green)
            statBox(value: "\(analytics.lateCount)", unit: "taps",
                    label: "Late", color: .blue)
        }
    }

    private func statBox(value: String, unit: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var balanceColor: Color {
        analytics.earlyLateBalance > 0 ? .red : (analytics.earlyLateBalance < 0 ? .blue : .green)
    }

    private func signedBalance(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    // MARK: - Judgment distribution

    private var distribution: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Judgments")
            if analytics.judgedCount > 0 {
                distributionBar(judgment: .perfect, count: analytics.perfectCount, color: .yellow)
                distributionBar(judgment: .great, count: analytics.greatCount, color: .green)
                distributionBar(judgment: .good, count: analytics.goodCount, color: .blue)
                distributionBar(judgment: .miss, count: analytics.missCount, color: .red)
            } else {
                Text("No judgments recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func distributionBar(judgment: Judgment, count: Int, color: Color) -> some View {
        let fraction = analytics.judgedCount > 0 ? Double(count) / Double(analytics.judgedCount) : 0
        return HStack(spacing: 10) {
            Text(judgment.displayName)
                .font(.caption.weight(.semibold))
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color).frame(width: max(geo.size.width * fraction, count > 0 ? 3 : 0))
                }
            }
            .frame(height: 10)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - Timeline strip

    private var timelineStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Timeline — where you tended to hit")
            if analytics.timeline.isEmpty {
                Text("No timeline data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(analytics.timeline.enumerated()), id: \.offset) { _, bucket in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bucketColor(bucket))
                            .frame(height: 34)
                    }
                }
                HStack(spacing: 12) {
                    legend(color: .red, label: "Early")
                    legend(color: .green, label: "Accurate")
                    legend(color: .blue, label: "Late")
                    legend(color: .secondary, label: "No notes")
                }
                .font(.caption2)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func bucketColor(_ bucket: RunAnalytics.TimelineBucket) -> Color {
        guard bucket.count > 0 else { return Color(.tertiarySystemFill) }
        if abs(bucket.meanErrorMs) <= RunAnalyticsCalculator.accurateThresholdMs { return .green }
        return bucket.meanErrorMs < 0 ? .red : .blue
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: - Progression sparklines

    private var progression: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Progression")
            sparkline(title: "Score", points: analytics.scoreProgression.map { (time: $0.time, value: Double($0.value)) },
                      color: .indigo, maxValue: Double(analytics.scoreProgression.map(\.value).max() ?? 0))
            sparkline(title: "Combo", points: analytics.comboProgression.map { (time: $0.time, value: Double($0.value)) },
                      color: .orange, maxValue: Double(analytics.maxCombo))
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func sparkline(title: String, points: [(time: Double, value: Double)],
                           color: Color, maxValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let span = max(points.map(\.time).max() ?? 0, 1)
                let peak = max(maxValue, 1)
                ZStack {
                    if points.count >= 2 {
                        Path { path in
                            let first = points[0]
                            path.move(to: CGPoint(x: 0, y: h - h * CGFloat(first.value / peak)))
                            for p in points {
                                let x = w * CGFloat(p.time / span)
                                let y = h - h * CGFloat(p.value / peak)
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                }
                .frame(width: w, height: h)
            }
            .frame(height: 44)
        }
    }

    // MARK: - Sections

    private var sectionBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("By section")
            if analytics.sections.isEmpty {
                Text("No sections were detected for this song.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(analytics.sections.enumerated()), id: \.offset) { _, section in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.label)
                                .font(.subheadline.weight(.semibold))
                            Text("\(section.judgedCount) notes · \(String(format: "%.0f", section.meanAbsErrorMs)) ms |err|")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(String(format: "%.1f%%", section.accuracy * 100))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(accuracyColor(section.accuracy))
                            HStack(spacing: 8) {
                                Text("\(section.earlyCount)E")
                                    .foregroundStyle(.red)
                                Text("\(section.accurateCount)A")
                                    .foregroundStyle(.green)
                                Text("\(section.lateCount)L")
                                    .foregroundStyle(.blue)
                            }
                            .font(.caption2.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                    if section.label != analytics.sections.last?.label {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func accuracyColor(_ accuracy: Double) -> Color {
        switch accuracy {
        case 0.9...: return .green
        case 0.75..<0.9: return .yellow
        case 0.5..<0.75: return .orange
        default: return .red
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
    }
}