import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var app
    @Environment(MemoryMonitor.self) private var monitor
    @Environment(JunkScanner.self) private var scanner
    @Environment(ReportStore.self) private var reports

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacCleaner").font(.largeTitle.bold())
                    Text("\(Sys.cpuName) · \(Fmt.mem(monitor.stats.total)) RAM · \(Sys.osVersion) · \(Fmt.duration(monitor.stats.uptime)) açık")
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    memoryCard
                    diskCard
                }

                if !monitor.findings.isEmpty { findingsCard }

                if let last = reports.reports.first { lastReportCard(last) }
            }
            .padding(24)
        }
        .navigationTitle("Genel Bakış")
        .onAppear { scanner.refreshDisk() }
    }

    private var memoryCard: some View {
        Card(title: "Bellek", icon: "memorychip") {
            let stats = monitor.stats
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.mem(stats.used)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                Text("/ \(Fmt.mem(stats.total)) kullanımda").foregroundStyle(.secondary)
            }
            StackedBar(segments: stats.segments)
            PressureBadge(level: stats.pressure)
            Text("Swap: \(Fmt.mem(stats.swapUsed)) · Sıkıştırılmış: \(Fmt.mem(stats.compressed))")
                .font(.callout).foregroundStyle(.secondary)
            Button("Belleği incele") { app.section = .memory }
        }
    }

    private var diskCard: some View {
        Card(title: "Disk", icon: "internaldrive") {
            let disk = scanner.disk
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.disk(disk.free)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                Text("boş / \(Fmt.disk(disk.total))").foregroundStyle(.secondary)
            }
            StackedBar(segments: [
                BarSegment(label: "Kullanılan", value: Double(disk.used), color: .blue),
                BarSegment(label: "Boş", value: Double(disk.free), color: .gray.opacity(0.25)),
            ])
            if scanner.phase == .ready {
                Text("Son taramada \(scanner.items.count) öğe, \(Fmt.disk(scanner.totalSize)) temizlenebilir alan bulundu.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Önbellekleri, derleme klasörlerini ve eski dosyaları bulmak için tara.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button(scanner.phase == .ready ? "Sonuçları göster" : "Çöp taraması başlat") {
                app.section = .cleanup
                if scanner.phase == .idle { Task { await scanner.scan() } }
            }
            .disabled(scanner.isBusy)
        }
    }

    private var findingsCard: some View {
        Card(title: "Tespitler", icon: "stethoscope") {
            ForEach(monitor.findings.prefix(5)) { finding in
                HStack(spacing: 10) {
                    Image(systemName: finding.icon).foregroundStyle(finding.level.color).frame(width: 22)
                    Text(finding.title)
                }
            }
            if monitor.findings.count > 5 {
                Text("+\(monitor.findings.count - 5) tespit daha").font(.caption).foregroundStyle(.secondary)
            }
            Button("Ayrıntılar ve çözümler") { app.section = .memory }
        }
    }

    private func lastReportCard(_ report: CleanReport) -> some View {
        Card(title: "Son rapor", icon: "doc.text") {
            Text("\(report.title) · \(report.date.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
            Text(report.headline).font(.title3.bold()).foregroundStyle(.green)
            Button("Raporu aç") {
                reports.selectedID = report.id
                app.section = .reports
            }
        }
    }
}
