import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReportsView: View {
    @Environment(ReportStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            List(store.reports, selection: $store.selectedID) { report in
                VStack(alignment: .leading, spacing: 2) {
                    Label(report.title, systemImage: report.kind == .disk ? "internaldrive" : "memorychip")
                        .fontWeight(.medium)
                    Text(report.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(report.headline).font(.caption).foregroundStyle(.green)
                }
                .padding(.vertical, 3)
            }
            .frame(width: 240)

            Divider()

            Group {
                if let report = store.reports.first(where: { $0.id == store.selectedID }) ?? store.reports.first {
                    ReportDetailView(report: report, allowDelete: true)
                } else {
                    ContentUnavailableView("Henüz rapor yok", systemImage: "doc.text",
                                           description: Text("Bir temizlik yaptığında raporu burada görünür."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Raporlar")
        .toolbar {
            ToolbarItem {
                Button { NSWorkspace.shared.open(store.folder) } label: { Label("Rapor klasörü", systemImage: "folder") }
            }
        }
    }
}

struct ReportSheet: View {
    let report: CleanReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ReportDetailView(report: report, allowDelete: false)
            Divider()
            HStack {
                Text("Rapor kaydedildi; Raporlar bölümünden tekrar açabilirsin.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Tamam") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 780, height: 620)
    }
}

struct ReportDetailView: View {
    let report: CleanReport
    let allowDelete: Bool
    @Environment(ReportStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.title).font(.title.bold())
                        Text("\(report.date.formatted(date: .long, time: .shortened)) · Süre: \(Fmt.duration(report.duration))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Markdown olarak kopyala") { copy() }
                        Button("Markdown dosyası olarak kaydet…") { save() }
                        if allowDelete {
                            Divider()
                            Button("Raporu sil", role: .destructive) { store.delete(report) }
                        }
                    } label: {
                        Label("Dışa aktar", systemImage: "square.and.arrow.up")
                    }
                    .fixedSize()
                }

                Text(report.headline).font(.title2.bold()).foregroundStyle(.green)
                stats

                if report.kind == .disk, report.estimated > 0,
                   Double(report.actualDiskFreed) < Double(report.estimated) * 0.8 {
                    Label("Gerçek kazanç tahminden az. APFS'de kopyalar (Chrome kopyaları, simülatörler gibi) veriyi paylaştığı için boyut ölçümü bazı verileri birden çok kez sayar. macOS silinen alanı birkaç dakika boyunca geri kazanmaya devam edebilir.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Yapılanlar").font(.headline)
                VStack(spacing: 0) {
                    ForEach(report.entries) { entry in
                        EntryRow(entry: entry, size: entry.bytes == 0 ? "—" : report.size(entry.bytes))
                        if entry.id != report.entries.last?.id { Divider() }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(24)
        }
    }

    @ViewBuilder private var stats: some View {
        let issues = report.problemCount
        HStack(spacing: 12) {
            if report.kind == .disk {
                StatTile(title: "Gerçekte boşalan", value: Fmt.disk(max(0, report.actualDiskFreed)),
                         subtitle: "disk ölçümüyle", tint: .green)
                StatTile(title: "Tahmini", value: Fmt.disk(report.estimated), subtitle: "seçilen öğelerin boyutu", tint: .blue)
                StatTile(title: "Boş alan", value: "\(Fmt.disk(report.diskFreeBefore)) → \(Fmt.disk(report.diskFreeAfter))")
            } else {
                StatTile(title: "Kullanılan bellek", value: "\(Fmt.mem(report.memUsedBefore)) → \(Fmt.mem(report.memUsedAfter))",
                         subtitle: "fark: \(Fmt.mem(report.memFreed))", tint: .green)
                StatTile(title: "Swap", value: "\(Fmt.mem(report.swapUsedBefore)) → \(Fmt.mem(report.swapUsedAfter))")
                StatTile(title: "Hedeflenen", value: Fmt.mem(report.estimated), subtitle: "kapatılanların belleği", tint: .blue)
            }
            StatTile(title: "İşlem", value: "\(report.okCount) başarılı",
                     subtitle: issues > 0 ? "\(issues) sorunlu" : "sorunsuz", tint: issues > 0 ? .orange : .green)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown(), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "MacCleaner-\(report.kind.rawValue)-\(report.date.formatted(.iso8601.year().month().day())).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? report.markdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct EntryRow: View {
    let entry: CleanReport.Entry
    let size: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.status.icon).foregroundStyle(entry.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).fontWeight(.medium)
                Text(entry.detail.isEmpty ? entry.category : "\(entry.category) · \(entry.detail)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let message = entry.message {
                    Text(message).font(.caption).foregroundStyle(entry.status == .ok ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            Text(size).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
