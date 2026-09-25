import AppKit
import SwiftUI

struct MemoryView: View {
    @Environment(AppState.self) private var app
    @Environment(MemoryMonitor.self) private var monitor
    @Environment(ReportStore.self) private var reports

    @State private var grouped = true
    @State private var search = ""
    @State private var selection = Set<MemRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\MemRow.memory, order: .reverse)]
    @State private var showFindings = true
    @State private var pending: PendingKill?

    struct PendingKill: Identifiable {
        let id = UUID()
        let targets: [KillTarget]
        let force: Bool
        let reason: String
    }

    private var rows: [MemRow] { monitor.rows(grouped: grouped, search: search).sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            summary.padding()
            if !monitor.findings.isEmpty { findings }
            Divider()
            table
            Divider()
            bottomBar
        }
        .navigationTitle("Bellek")
        .searchable(text: $search, placement: .toolbar, prompt: "Süreç ara")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $grouped) { Label("Uygulamaya göre grupla", systemImage: "square.stack.3d.up") }
                    .help("Yardımcı süreçleri ait oldukları uygulamanın altında topla")
                Button { Task { await purge() } } label: { Label("Önbelleği Boşalt", systemImage: "wind") }
                    .help("Dosya önbelleğini boşaltır (purge). Yönetici şifresi ister.")
                Button { Task { await monitor.refreshProcesses() } } label: { Label("Yenile", systemImage: "arrow.clockwise") }
            }
        }
        .alert(pending?.force == true ? "Zorla kapatılsın mı?" : "Kapatılsın mı?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { request in
            Button(request.force ? "Zorla Kapat" : "Kapat", role: .destructive) { Task { await run(request) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { request in
            let lines = request.targets.prefix(12).map { "• \($0.name): \(Fmt.mem($0.memory))" }
            let more = request.targets.count > 12 ? "\n… ve \(request.targets.count - 12) süreç daha" : ""
            let warning = request.force ? "\n\nKaydedilmemiş veriler kaybolabilir." : ""
            Text(lines.joined(separator: "\n") + more + warning)
        }
        .overlay {
            if let busy = monitor.busy {
                ProgressView(busy)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Sections

    private var summary: some View {
        let stats = monitor.stats
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Fmt.mem(stats.used)) / \(Fmt.mem(stats.total))").font(.title2.bold()).monospacedDigit()
                Text("kullanımda").foregroundStyle(.secondary)
                Spacer()
                PressureBadge(level: stats.pressure)
            }
            StackedBar(segments: stats.segments)
            HStack(spacing: 18) {
                ForEach(stats.segments) { LegendDot(color: $0.color, label: $0.label, value: Fmt.mem(UInt64($0.value))) }
            }
            HStack(spacing: 18) {
                Label("Swap: \(Fmt.mem(stats.swapUsed)) / \(Fmt.mem(stats.swapTotal))", systemImage: "externaldrive")
                Label("Sıkıştırılan veri: \(Fmt.mem(stats.compressedOriginal)) → \(Fmt.mem(stats.compressed))",
                      systemImage: "arrow.down.right.and.arrow.up.left")
                Label("Açık kalma süresi: \(Fmt.duration(stats.uptime))", systemImage: "clock")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var findings: some View {
        DisclosureGroup(isExpanded: $showFindings) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(monitor.findings) { finding in
                        FindingRow(finding: finding) { act(on: finding) }
                    }
                }
            }
            .frame(maxHeight: 220)
            .padding(.top, 6)
        } label: {
            Label("Tespitler (\(monitor.findings.count))", systemImage: "stethoscope").font(.headline)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Ad", value: \.name) { row in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(row.iconPath)).resizable().frame(width: 18, height: 18)
                    Text(row.name).lineLimit(1)
                    if row.count > 1 {
                        Text("\(row.count) süreç").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 220, ideal: 340)
            TableColumn("Bellek", value: \.memory) { row in
                Text(Fmt.mem(row.memory)).monospacedDigit()
                    .fontWeight(row.memory >= UInt64(GB) ? .semibold : .regular)
                    .foregroundStyle(row.memory >= UInt64(4 * GB) ? Color.red : Color.primary)
            }
            .width(min: 80, ideal: 95)
            TableColumn("Sıkıştırılmış", value: \.compressed) { row in
                Text(Fmt.mem(row.compressed)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Çalışma süresi", value: \.elapsed) { row in
                Text(Fmt.duration(row.elapsed)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Sahibi", value: \.owner) { row in
                Text(row.owner).foregroundStyle(row.isMine ? .primary : .secondary)
            }
            .width(min: 50, ideal: 60)
        }
        .contextMenu(forSelectionType: MemRow.ID.self) { ids in
            let targets = targets(for: ids)
            Button("Çık") { ask(targets, force: false) }.disabled(targets.isEmpty)
            Button("Zorla Kapat") { ask(targets, force: true) }.disabled(targets.isEmpty)
            if let row = rows.first(where: { ids.contains($0.id) }), !row.path.isEmpty {
                Divider()
                Button("Finder'da Göster") { NSWorkspace.shared.selectFile(row.path, inFileViewerRootedAtPath: "") }
            }
        }
    }

    private var bottomBar: some View {
        let selected = targets(for: selection)
        return HStack(spacing: 10) {
            Text("\(monitor.processes.count) süreç · Güncellendi: \(monitor.lastUpdate?.formatted(date: .omitted, time: .standard) ?? "—")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !selection.isEmpty && selected.isEmpty {
                Text("Sistem süreçleri buradan kapatılamaz.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Çık") { ask(selected, force: false) }.disabled(selected.isEmpty)
            Button("Zorla Kapat") { ask(selected, force: true) }.disabled(selected.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func targets(for ids: Set<MemRow.ID>) -> [KillTarget] {
        rows.filter { ids.contains($0.id) && $0.canQuit }.map(\.target)
    }

    private func ask(_ targets: [KillTarget], force: Bool) {
        guard !targets.isEmpty else { return }
        pending = PendingKill(targets: targets, force: force, reason: "Elle kapatılan")
    }

    private func act(on finding: Finding) {
        switch finding.action {
        case .kill(let pids):
            let targets = monitor.processes.filter { pids.contains($0.pid) }.map {
                KillTarget(name: $0.name, pids: [$0.pid], mainPID: $0.pid, memory: $0.memory)
            }
            guard !targets.isEmpty else { return }
            pending = PendingKill(targets: targets, force: false, reason: finding.title)
        case .restart:
            monitor.requestRestart()
        case .none:
            break
        }
    }

    private func run(_ request: PendingKill) async {
        let report = await monitor.terminate(request.targets, force: request.force, reason: request.reason)
        selection = []
        reports.add(report)
        app.presentedReport = report
    }

    private func purge() async {
        guard let report = await monitor.purge() else { return }
        reports.add(report)
        app.presentedReport = report
    }
}
