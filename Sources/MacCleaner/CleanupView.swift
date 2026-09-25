import AppKit
import SwiftUI

struct CleanupView: View {
    @Environment(AppState.self) private var app
    @Environment(JunkScanner.self) private var scanner
    @Environment(ReportStore.self) private var reports
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding()
            Divider()
            content
            if scanner.phase != .idle && scanner.phase != .scanning && !scanner.items.isEmpty {
                Divider()
                bottomBar
            }
        }
        .navigationTitle("Disk Temizliği")
        .toolbar {
            ToolbarItem {
                Button { Task { await scanner.scan() } } label: {
                    Label(scanner.phase == .idle ? "Tara" : "Yeniden Tara", systemImage: "magnifyingglass")
                }
                .disabled(scanner.isBusy)
            }
        }
        .sheet(isPresented: $confirming) {
            ConfirmCleanView(items: scanner.selected, onCancel: { confirming = false }) {
                confirming = false
                Task { await clean() }
            }
        }
        .overlay {
            if scanner.phase == .cleaning { cleaningOverlay }
        }
        .task {
            if UserDefaults.standard.bool(forKey: "scan"), scanner.phase == .idle { await scanner.scan() }
        }
    }

    // MARK: Sections

    private var header: some View {
        let disk = scanner.disk
        let reclaimable = scanner.phase == .ready ? min(scanner.totalSize, disk.used) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Fmt.disk(disk.free)) boş").font(.title2.bold()).monospacedDigit()
                Text("/ \(Fmt.disk(disk.total)) · \(Fmt.disk(disk.used)) kullanılıyor").foregroundStyle(.secondary)
                Spacer()
                if let last = scanner.lastScan {
                    Text("Son tarama: \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // The reclaimable part is carved out of "used".
            StackedBar(segments: [
                BarSegment(label: "Kullanılan", value: Double(disk.used - reclaimable), color: .blue),
                BarSegment(label: "Temizlenebilir", value: Double(reclaimable), color: .orange),
                BarSegment(label: "Boş", value: Double(disk.free), color: .gray.opacity(0.25)),
            ])
            if scanner.phase == .ready && !scanner.items.isEmpty {
                HStack(spacing: 16) {
                    LegendDot(color: .blue, label: "Kullanılan", value: Fmt.disk(disk.used))
                    LegendDot(color: .orange, label: "Temizlenebilir", value: Fmt.disk(scanner.totalSize))
                    LegendDot(color: .gray.opacity(0.4), label: "Boş", value: Fmt.disk(disk.free))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch scanner.phase {
        case .idle:
            ContentUnavailableView {
                Label("Mac'ini tara", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Önbellekler, derleme klasörleri, eski simülatörler, Chrome kopyaları ve büyük indirmeler taranır. Sen onaylamadan hiçbir şey silinmez.")
            } actions: {
                Button("Taramayı Başlat") { Task { await scanner.scan() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .scanning:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(scanner.status).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .cleaning:
            if scanner.items.isEmpty {
                ContentUnavailableView("Temizlenecek bir şey bulunamadı", systemImage: "checkmark.seal",
                                       description: Text("Mac'in temiz görünüyor."))
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if !scanner.warnings.isEmpty {
                Section {
                    ForEach(scanner.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                }
            }
            ForEach(JunkCategory.allCases) { category in
                let items = scanner.items(in: category)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            JunkRow(item: item, selected: binding(for: item.id))
                        }
                    } header: {
                        CategoryHeader(category: category, items: items) { scanner.setAll(in: category, $0) }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(scanner.selected.count) öğe seçili").fontWeight(.medium)
                Text("Tahmini kazanç: \(Fmt.disk(scanner.selectedSize))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Yalnızca güvenlileri seç") { scanner.selectSafe() }
            Button("Seçimi kaldır") { scanner.setAll(in: nil, false) }
            Button { confirming = true } label: { Label("Temizle…", systemImage: "trash") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(scanner.selected.isEmpty || scanner.isBusy)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var cleaningOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Temizleniyor…").font(.headline)
                ProgressView(value: scanner.cleanProgress).frame(width: 340)
                Text(scanner.status).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(width: 340)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Actions

    /// Bound by id so rows stay valid while items are removed after a clean.
    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { scanner.items.first { $0.id == id }?.selected ?? false },
                set: { scanner.setSelected(id, $0) })
    }

    private func clean() async {
        let report = await scanner.clean()
        reports.add(report)
        app.presentedReport = report
    }
}

struct CategoryHeader: View {
    let category: JunkCategory
    let items: [JunkItem]
    let setAll: (Bool) -> Void

    var body: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let selectedCount = items.filter(\.selected).count
        HStack {
            Label(category.title, systemImage: category.icon).font(.headline)
            Text(Fmt.disk(total)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text("\(selectedCount)/\(items.count) seçili").font(.caption).foregroundStyle(.secondary)
            Button(selectedCount == items.count ? "Hiçbiri" : "Tümü") { setAll(selectedCount != items.count) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct JunkRow: View {
    let item: JunkItem
    @Binding var selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $selected).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium)
                    RiskBadge(risk: item.risk)
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note = item.note {
                    Label(note, systemImage: item.risk == .caution ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(item.risk == .caution ? Color.orange : Color.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.disk(item.size)).monospacedDigit().fontWeight(.semibold)
                if let date = item.modified {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selected.toggle() }
        .contextMenu {
            if let path = item.revealPath {
                Button("Finder'da Göster") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
        }
    }
}

struct ConfirmCleanView: View {
    let items: [JunkItem]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let toTrash = items.filter(\.movesToTrash).count
        let permanent = items.count - toTrash
        let caution = items.filter { $0.risk == .caution }.count
        VStack(alignment: .leading, spacing: 14) {
            Label("\(items.count) öğe temizlenecek", systemImage: "trash").font(.title2.bold())
            Text("Tahmini kazanç: \(Fmt.disk(total))").foregroundStyle(.secondary)
            List(items) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    if item.risk == .caution { RiskBadge(risk: .caution) }
                    Spacer()
                    Text(Fmt.disk(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)
            VStack(alignment: .leading, spacing: 6) {
                if permanent > 0 {
                    Label("\(permanent) öğe kalıcı olarak silinir, geri alınamaz.", systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                }
                if toTrash > 0 {
                    Label("\(toTrash) dosya Çöp Kutusu'na taşınır.", systemImage: "trash")
                }
                if caution > 0 {
                    Label("\(caution) öğe \"Dikkat\" işaretli; notlarını okuduğundan emin ol.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Temizle", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 580, height: 540)
    }
}
