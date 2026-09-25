import AppKit
import SwiftUI

struct BarSegment: Identifiable {
    let label: String
    let value: Double
    let color: Color
    var id: String { label }
}

struct StackedBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geo.size.width * segment.value / total - 1))
                        .help(segment.label)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.55)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PressureBadge: View {
    let level: Int32

    var body: some View {
        let (text, color): (String, Color) = switch level {
        case 4: ("Kritik", .red)
        case 2: ("Uyarı", .orange)
        default: ("Normal", .green)
        }
        Label("Bellek baskısı: \(text)", systemImage: "circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk == .safe ? "Güvenli" : "Dikkat")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(risk == .safe ? Color.green : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((risk == .safe ? Color.green : Color.orange).opacity(0.12), in: Capsule())
    }
}

extension Finding.Level {
    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension CleanReport.Status {
    var icon: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .partial: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .partial: .orange
        case .failed: .red
        }
    }
}

extension MemoryStats {
    var segments: [BarSegment] {
        [
            BarSegment(label: "Uygulamalar", value: Double(app), color: .blue),
            BarSegment(label: "Çekirdek (wired)", value: Double(wired), color: .orange),
            BarSegment(label: "Sıkıştırılmış", value: Double(compressed), color: .purple),
            BarSegment(label: "Önbellek", value: Double(cached), color: .teal.opacity(0.6)),
            BarSegment(label: "Boş", value: Double(free), color: .gray.opacity(0.25)),
        ]
    }
}

struct FindingRow: View {
    let finding: Finding
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.icon)
                .font(.title2)
                .foregroundStyle(finding.level.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).fontWeight(.semibold)
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let title = finding.actionTitle {
                Button(title, action: onAction)
            }
        }
        .padding(12)
        .background(finding.level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
