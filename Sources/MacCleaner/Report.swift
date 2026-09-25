import Foundation
import Observation

struct CleanReport: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case disk, memory }
    enum Status: String, Codable { case ok, partial, failed }

    struct Entry: Codable, Hashable, Identifiable {
        var id = UUID()
        var title: String
        var category: String
        var detail: String
        var bytes: Int64
        var status: Status
        var message: String?
    }

    var id = UUID()
    var kind: Kind
    var date: Date
    var duration: TimeInterval
    var entries: [Entry]
    var diskFreeBefore: Int64 = 0
    var diskFreeAfter: Int64 = 0
    var memUsedBefore: Int64 = 0
    var memUsedAfter: Int64 = 0
    var swapUsedBefore: Int64 = 0
    var swapUsedAfter: Int64 = 0

    var estimated: Int64 { entries.filter { $0.status != .failed }.reduce(0) { $0 + $1.bytes } }
    var actualDiskFreed: Int64 { diskFreeAfter - diskFreeBefore }
    var memFreed: Int64 { memUsedBefore - memUsedAfter }
    var okCount: Int { entries.filter { $0.status == .ok }.count }
    var problemCount: Int { entries.count - okCount }

    var title: String { kind == .disk ? "Disk temizliği" : "Bellek temizliği" }

    var headline: String {
        kind == .disk
            ? "\(Fmt.disk(max(0, actualDiskFreed))) disk alanı boşaldı"
            : "\(Fmt.mem(max(0, memFreed))) bellek boşaldı"
    }

    func size(_ bytes: Int64) -> String { kind == .disk ? Fmt.disk(bytes) : Fmt.mem(bytes) }

    func markdown() -> String {
        var md = "# MacCleaner: \(title)\n\n"
        md += "- Tarih: \(date.formatted(date: .long, time: .shortened))\n"
        md += "- Süre: \(Fmt.duration(duration))\n"
        md += "- Sonuç: **\(headline)**\n\n"
        md += "| Ölçüm | Önce | Sonra | Fark |\n|---|---|---|---|\n"
        if kind == .disk {
            md += "| Boş disk alanı | \(Fmt.disk(diskFreeBefore)) | \(Fmt.disk(diskFreeAfter)) | \(Fmt.disk(actualDiskFreed)) |\n"
            md += "\nSeçilen öğelerin toplam boyutu (tahmini): \(Fmt.disk(estimated))\n"
        } else {
            md += "| Kullanılan bellek | \(Fmt.mem(memUsedBefore)) | \(Fmt.mem(memUsedAfter)) | \(Fmt.mem(memUsedBefore - memUsedAfter)) |\n"
            md += "| Swap | \(Fmt.mem(swapUsedBefore)) | \(Fmt.mem(swapUsedAfter)) | \(Fmt.mem(swapUsedBefore - swapUsedAfter)) |\n"
        }
        md += "\n## Yapılanlar (\(okCount) başarılı, \(problemCount) sorunlu)\n\n"
        md += "| Durum | Öğe | Kategori | Boyut | Not |\n|---|---|---|---|---|\n"
        for e in entries {
            let mark = e.status == .ok ? "✅" : (e.status == .partial ? "⚠️" : "❌")
            let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "\\|") }
            md += "| \(mark) | \(cell(e.title)) | \(cell(e.category)) | \(e.bytes == 0 ? "—" : size(e.bytes)) | \(cell(e.message ?? "")) |\n"
        }
        return md
    }
}

@MainActor
@Observable
final class ReportStore {
    var reports: [CleanReport] = []
    var selectedID: UUID?

    let folder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("MacCleaner/Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        reports = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(CleanReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func add(_ report: CleanReport) {
        reports.insert(report, at: 0)
        selectedID = report.id
        if let data = try? Self.encoder.encode(report) {
            try? data.write(to: file(for: report))
        }
    }

    func delete(_ report: CleanReport) {
        try? FileManager.default.removeItem(at: file(for: report))
        reports.removeAll { $0.id == report.id }
        if selectedID == report.id { selectedID = reports.first?.id }
    }

    private func file(for report: CleanReport) -> URL {
        let stamp = report.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("\(stamp)-\(report.kind.rawValue)-\(report.id.uuidString.prefix(8)).json")
    }
}
