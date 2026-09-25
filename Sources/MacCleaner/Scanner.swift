import AppKit
import Darwin
import Foundation
import Observation
import Security

// MARK: - Model

enum JunkCategory: String, CaseIterable, Identifiable, Codable {
    case system, leftovers, xcode, projects, devCaches, android, personal

    var id: String { rawValue }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .system: "Sistem ve tarayıcılar"
        case .leftovers: "Silinmiş uygulama kalıntıları"
        case .xcode: "Xcode ve iOS"
        case .projects: "Proje derleme klasörleri"
        case .devCaches: "Geliştirici önbellekleri"
        case .android: "Android"
        case .personal: "Büyük dosyalar (İndirilenler)"
        }
    }

    var icon: String {
        switch self {
        case .system: "macwindow"
        case .leftovers: "app.dashed"
        case .xcode: "hammer"
        case .projects: "folder.badge.gearshape"
        case .devCaches: "shippingbox"
        case .android: "candybarphone"
        case .personal: "arrow.down.circle"
        }
    }
}

enum Risk: String, Codable {
    case safe, caution
}

struct Command: Hashable {
    let path: String
    let args: [String]
    var ignoreFailure = false
}

enum Deletion: Hashable {
    /// Delete these paths entirely.
    case remove([String])
    /// Delete everything inside the folder but keep the folder.
    case removeContents(String)
    /// Move to the Trash (used for personal files).
    case trash([String])
    /// Run commands in order (simctl etc.).
    case run([Command])
}

struct JunkItem: Identifiable, Hashable {
    let id: String
    let category: JunkCategory
    let title: String
    let detail: String
    let note: String?
    let risk: Risk
    let deletion: Deletion
    let sizePaths: [String]
    let knownSize: Int64
    var size: Int64 = 0
    var selected: Bool
    let modified: Date?
    /// Shown even when smaller than 1 MB (e.g. a broken launch agent).
    let keepSmall: Bool

    init(_ id: String, _ category: JunkCategory, title: String, detail: String, note: String? = nil,
         risk: Risk, deletion: Deletion, sizePaths: [String] = [], knownSize: Int64 = 0,
         selected: Bool? = nil, modified: Date? = nil, keepSmall: Bool = false) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.note = note
        self.risk = risk
        self.deletion = deletion
        self.sizePaths = sizePaths
        self.knownSize = knownSize
        self.selected = selected ?? (risk == .safe)
        self.modified = modified
        self.keepSmall = keepSmall
    }

    var revealPath: String? {
        if let first = sizePaths.first { return first }
        if case .trash(let paths) = deletion { return paths.first }
        return nil
    }

    var movesToTrash: Bool {
        if case .trash = deletion { return true }
        return false
    }
}

// MARK: - Scanner state

@MainActor
@Observable
final class JunkScanner {
    enum Phase: Equatable { case idle, scanning, ready, cleaning }

    var phase: Phase = .idle
    var items: [JunkItem] = []
    var warnings: [String] = []
    var status = ""
    var cleanProgress: Double = 0
    var lastScan: Date?
    var disk = DiskInfo.current()

    var selected: [JunkItem] { items.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func items(in category: JunkCategory) -> [JunkItem] { items.filter { $0.category == category } }

    func setSelected(_ id: String, _ value: Bool) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].selected = value }
    }

    func setAll(in category: JunkCategory?, _ value: Bool) {
        for i in items.indices where category == nil || items[i].category == category {
            items[i].selected = value
        }
    }

    func selectSafe() {
        for i in items.indices { items[i].selected = items[i].risk == .safe }
    }

    func refreshDisk() { disk = DiskInfo.current() }

    func scan() async {
        guard !isBusy else { return }
        phase = .scanning
        status = "Hazırlanıyor…"
        warnings = []
        let update: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
        let (found, notes) = await Task.detached(priority: .userInitiated) {
            let engine = ScanEngine(progress: update)
            let result = engine.run()
            return (result, engine.warnings)
        }.value
        items = found
        warnings = notes
        lastScan = Date()
        disk = DiskInfo.current()
        phase = .ready
    }

    func clean() async -> CleanReport {
        let chosen = selected
        phase = .cleaning
        cleanProgress = 0
        let start = Date()
        let before = DiskInfo.current()
        var entries: [CleanReport.Entry] = []
        var cleaned = Set<String>()

        for (index, item) in chosen.enumerated() {
            status = item.title
            let deletion = item.deletion
            let (result, message) = await Task.detached(priority: .userInitiated) { Cleaner.perform(deletion) }.value
            let bytes = item.movesToTrash ? 0 : item.size
            entries.append(CleanReport.Entry(title: item.title, category: item.category.title, detail: item.detail,
                                             bytes: bytes, status: result,
                                             message: message ?? (item.movesToTrash ? "Çöp Kutusu'na taşındı (\(Fmt.disk(item.size)))" : nil)))
            if result != .failed { cleaned.insert(item.id) }
            cleanProgress = Double(index + 1) / Double(max(chosen.count, 1))
        }

        // APFS releases blocks asynchronously; give it a moment before measuring.
        status = "Boşalan alan ölçülüyor…"
        try? await Task.sleep(for: .seconds(3))
        let after = DiskInfo.current()
        disk = after
        items.removeAll { cleaned.contains($0.id) }
        phase = .ready
        return CleanReport(kind: .disk, date: start, duration: Date().timeIntervalSince(start), entries: entries,
                           diskFreeBefore: before.free, diskFreeAfter: after.free)
    }
}

// MARK: - Deletion

enum Cleaner {
    static func perform(_ deletion: Deletion) -> (CleanReport.Status, String?) {
        let fm = FileManager.default
        var errors: [String] = []
        var done = 0

        func remove(_ path: String) {
            do {
                try fm.removeItem(atPath: path)
                done += 1
            } catch let error as NSError where error.code == NSFileNoSuchFileError {
                done += 1
            } catch {
                errors.append((error as NSError).localizedDescription)
            }
        }

        switch deletion {
        case .remove(let paths):
            paths.forEach(remove)
        case .removeContents(let dir):
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { remove(dir.appendingPath(name)) }
        case .trash(let paths):
            for path in paths {
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    done += 1
                } catch {
                    errors.append((error as NSError).localizedDescription)
                }
            }
        case .run(let commands):
            for command in commands {
                let result = Shell.run(command.path, command.args)
                if result.ok || command.ignoreFailure {
                    done += 1
                } else {
                    let err = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    errors.append(err.isEmpty ? "Komut başarısız (\(result.status))" : err)
                }
            }
        }

        guard let first = errors.first else { return (.ok, nil) }
        let message = errors.count == 1 ? first : "\(errors.count) hata. İlki: \(first)"
        return (done > 0 ? .partial : .failed, message)
    }
}

// MARK: - Scan engine

private struct RunningSnapshot {
    var execPaths: [String] = []
    var names: Set<String> = []
    var commands: [String] = []

    static func take() -> RunningSnapshot {
        var snapshot = RunningSnapshot()
        let ps = Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="])
        var buffer = [CChar](repeating: 0, count: 4096)
        for line in ps.out.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            snapshot.commands.append(String(trimmed[space...].drop(while: { $0 == " " })))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                snapshot.execPaths.append(path.normalizedPrivate)
                snapshot.names.insert(path.lastPathComponent)
            }
        }
        return snapshot
    }

    func isRunning(_ name: String) -> Bool { names.contains(name) }
}

private struct ProjectSummary {
    var gradleVersions: Set<String> = []
    var ndkVersions: Set<String> = []
    var usesFlutterNdk = false
    var count = 0
}

final class ScanEngine {
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private let progress: (String) -> Void
    private var running = RunningSnapshot()
    private var projects = ProjectSummary()
    private(set) var warnings: [String] = []

    init(progress: @escaping (String) -> Void) {
        self.progress = progress
    }

    func run() -> [JunkItem] {
        running = RunningSnapshot.take()
        var items: [JunkItem] = []
        progress("Sistem ve tarayıcı dosyaları taranıyor…")
        items += systemItems()
        progress("Xcode, simülatörler ve arşivler taranıyor…")
        items += xcodeItems()
        progress("Projeler aranıyor…")
        items += projectItems()
        progress("Geliştirici önbellekleri taranıyor…")
        items += devCacheItems()
        progress("Android SDK ve emülatörler taranıyor…")
        items += androidItems()
        progress("İndirilenler taranıyor…")
        items += personalItems()
        progress("Silinmiş uygulamaların kalıntıları aranıyor…")
        items += leftoverItems(excluding: Set(items.flatMap(\.sizePaths)))
        progress("Boyutlar hesaplanıyor (\(items.count) öğe)…")
        measure(&items)
        return items
            .filter { $0.size >= MB || $0.keepSmall }
            .sorted { ($0.category.order, -$0.size) < ($1.category.order, -$1.size) }
    }

    // MARK: Helpers

    private func h(_ relative: String) -> String { home.appendingPath(relative) }
    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    private func isDir(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func children(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
            .filter { $0 != ".DS_Store" }
            .sorted()
            .map { path.appendingPath($0) }
    }

    private func mdate(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func created(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func json(_ text: String) -> Any? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private func measure(_ items: inout [JunkItem]) {
        let paths = items.map(\.sizePaths)
        var sizes = [Int64](repeating: 0, count: items.count)
        sizes.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                buffer[i] = paths[i].isEmpty ? 0 : Self.du(paths[i])
            }
        }
        for i in items.indices { items[i].size = items[i].knownSize + sizes[i] }
    }

    static func du(_ paths: [String]) -> Int64 {
        let result = Shell.run("/usr/bin/du", ["-sk"] + paths)
        return result.out.split(separator: "\n").reduce(Int64(0)) { total, line in
            total + (Int64(line.split(separator: "\t").first.map(String.init) ?? "") ?? 0) * 1_024
        }
    }

    // MARK: System & browsers

    private func systemItems() -> [JunkItem] {
        var items: [JunkItem] = []

        // Chromium-based apps clone their bundle into …/X/<bundle id>.code_sign_clone at launch and keep
        // it for code-signature checks while running; clones left by crashes or updates pile up until reboot.
        let cloneRoot = (NSTemporaryDirectory() as NSString).deletingLastPathComponent.appendingPath("X")
        for dir in children(cloneRoot) where dir.hasSuffix(".code_sign_clone") {
            let clones = children(dir).filter { $0.lastPathComponent.hasPrefix("code_sign_clone.") }
            guard !clones.isEmpty else { continue }
            let bundleID = dir.lastPathComponent.replacingOccurrences(of: ".code_sign_clone", with: "")
            let appName = clones.lazy
                .compactMap { clone in self.children(clone).first { $0.hasSuffix(".app") || $0.hasSuffix(".app.bundle") } }
                .first
                .map { $0.lastPathComponent.replacingOccurrences(of: ".bundle", with: "").replacingOccurrences(of: ".app", with: "") }
                ?? bundleID
            // The running app executes from /Applications, not from the clone, so exec paths can't tell
            // which clone is live. Keep every clone created since the app launched; if unsure, keep all.
            var keep = Set(clones.filter { clone in
                let prefix = clone.normalizedPrivate + "/"
                return running.execPaths.contains { $0.hasPrefix(prefix) }
            })
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if !instances.isEmpty || running.isRunning(appName) {
                if let launched = instances.compactMap(\.launchDate).min() {
                    keep.formUnion(clones.filter { (created($0) ?? .distantFuture) >= launched.addingTimeInterval(-120) })
                    if keep.isEmpty, let newest = clones.max(by: { (created($0) ?? .distantPast) < (created($1) ?? .distantPast) }) {
                        keep.insert(newest)
                    }
                } else {
                    keep = Set(clones)
                }
            }
            let old = clones.filter { !keep.contains($0) }
            guard !old.isEmpty else { continue }
            items.append(JunkItem(
                "clone-\(dir)", .system,
                title: "\(appName): \(old.count) eski kod imzası kopyası",
                detail: "macOS'un uygulamayı açarken oluşturduğu kopyalar; normalde yeniden başlatınca silinir",
                note: "Kullanımdaki kopyaya dokunulmaz. Kopyalar veriyi paylaştığı için gerçek kazanç gösterilenden az olabilir.",
                risk: .safe, deletion: .remove(old), sizePaths: old))
        }

        let browsers: [(name: String, path: String, process: String)] = [
            ("Google Chrome", "Library/Caches/Google/Chrome", "Google Chrome"),
            ("Brave", "Library/Caches/BraveSoftware", "Brave Browser"),
            ("Microsoft Edge", "Library/Caches/Microsoft Edge", "Microsoft Edge"),
            ("Firefox", "Library/Caches/Firefox", "firefox"),
            ("Arc", "Library/Caches/Arc", "Arc"),
            ("Opera", "Library/Caches/com.operasoftware.Opera", "Opera"),
        ]
        for browser in browsers where isDir(h(browser.path)) {
            let open = running.isRunning(browser.process)
            items.append(JunkItem(
                "browser-\(browser.name)", .system,
                title: "\(browser.name) önbelleği", detail: h(browser.path).tildePath,
                note: open ? "\(browser.name) şu an açık. Önce kapatman önerilir; açıkken silinirse sayfalar yeniden yüklenir."
                    : "Siteler ilk açılışta biraz daha yavaş yüklenebilir.",
                risk: open ? .caution : .safe, deletion: .removeContents(h(browser.path)), sizePaths: [h(browser.path)]))
        }

        let logs = h("Library/Logs")
        if isDir(logs) {
            items.append(JunkItem("user-logs", .system, title: "Kullanıcı logları", detail: logs.tildePath,
                                  risk: .safe, deletion: .removeContents(logs), sizePaths: [logs]))
        }

        let trash = h(".Trash")
        do {
            let contents = try fm.contentsOfDirectory(atPath: trash).filter { $0 != ".DS_Store" }
            if !contents.isEmpty {
                items.append(JunkItem("trash", .system, title: "Çöp Kutusu (\(contents.count) öğe)", detail: "~/.Trash",
                                      note: "Kalıcı olarak silinir, geri alınamaz.",
                                      risk: .caution, deletion: .removeContents(trash), sizePaths: [trash]))
            }
        } catch {
            warnings.append("Çöp Kutusu okunamadı. Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi'nden MacCleaner'a izin verirsen o da taranır.")
        }

        for path in children(h("Library/Caches")) {
            let name = path.lastPathComponent.lowercased()
            guard !name.hasPrefix("com.apple."), name.contains("updater") || name.hasSuffix(".shipit") else { continue }
            items.append(JunkItem("updater-\(path)", .system, title: "Güncelleme kalıntısı: \(path.lastPathComponent)",
                                  detail: path.tildePath, note: "Uygulamaların indirip bıraktığı eski güncelleme dosyaları.",
                                  risk: .safe, deletion: .removeContents(path), sizePaths: [path]))
        }
        return items
    }

    // MARK: Xcode & iOS

    private func xcodeItems() -> [JunkItem] {
        var items: [JunkItem] = []
        let xcodeOpen = running.isRunning("Xcode") || running.isRunning("xcodebuild")

        let derived = h("Library/Developer/Xcode/DerivedData")
        if isDir(derived) {
            items.append(JunkItem(
                "xcode-derived", .xcode, title: "Xcode DerivedData", detail: derived.tildePath,
                note: xcodeOpen ? "Xcode açık; süren bir derleme bozulabilir. Önce Xcode'u kapat."
                    : "Derleme ara dosyaları. Sonraki derleme daha uzun sürer.",
                risk: xcodeOpen ? .caution : .safe, deletion: .removeContents(derived), sizePaths: [derived]))
        }

        let distribution = children(NSTemporaryDirectory()).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("XcodeDistPipeline.") || name.hasSuffix(".xcdistributionlogs")
        }
        if !distribution.isEmpty {
            items.append(JunkItem("xcode-dist", .xcode, title: "Xcode yükleme geçici dosyaları (\(distribution.count))",
                                  detail: "App Store'a yükleme sırasında geride kalan dosyalar",
                                  risk: .safe, deletion: .remove(distribution), sizePaths: distribution))
        }

        let deltas = h("Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas")
        if isDir(deltas) {
            items.append(JunkItem("coredevice-deltas", .xcode, title: "Cihaza yükleme önbelleği",
                                  detail: "Uygulamaları iPhone'a yüklerken tutulan fark dosyaları",
                                  risk: .safe, deletion: .removeContents(deltas), sizePaths: [deltas]))
        }

        items += simulatorItems()
        items += archiveItems()

        for supportDir in children(h("Library/Developer/Xcode")) where supportDir.hasSuffix("DeviceSupport") {
            for dir in children(supportDir) where isDir(dir) {
                items.append(JunkItem(
                    "devicesupport-\(dir)", .xcode, title: "Cihaz destek dosyaları: \(dir.lastPathComponent)",
                    detail: supportDir.lastPathComponent,
                    note: "Cihazı tekrar bağladığında Xcode birkaç dakikada yeniden oluşturur.",
                    risk: .caution, deletion: .remove([dir]), sizePaths: [dir], modified: mdate(dir)))
            }
        }
        return items
    }

    private func simulatorItems() -> [JunkItem] {
        let xcrun = "/usr/bin/xcrun"
        guard let root = json(Shell.run(xcrun, ["simctl", "list", "devices", "-j"]).out) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }

        func dataSize(_ device: [String: Any]) -> Int64 { (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0 }
        var items: [JunkItem] = []

        let unavailable = devices.values.flatMap { $0 }.filter { ($0["isAvailable"] as? Bool) == false }
        if !unavailable.isEmpty {
            items.append(JunkItem(
                "sim-unavailable", .xcode, title: "Kullanılamayan simülatörler (\(unavailable.count))",
                detail: "Runtime'ı silinmiş ya da bu Xcode'un desteklemediği simülatörler",
                risk: .safe, deletion: .run([Command(path: xcrun, args: ["simctl", "delete", "unavailable"])]),
                knownSize: unavailable.reduce(0) { $0 + dataSize($1) }))
        }

        var handled = Set<String>()
        if let runtimes = json(Shell.run(xcrun, ["simctl", "runtime", "list", "-j"]).out) as? [String: [String: Any]] {
            let byPlatform = Dictionary(grouping: runtimes) { $0.value["platformIdentifier"] as? String ?? "" }
            for (platform, list) in byPlatform {
                let newestFirst = list.sorted {
                    ($0.value["version"] as? String ?? "").compare($1.value["version"] as? String ?? "", options: .numeric) == .orderedDescending
                }
                for (runtimeID, info) in newestFirst.dropFirst() where (info["deletable"] as? Bool) != false {
                    let version = info["version"] as? String ?? "?"
                    let simDevices = devices[info["runtimeIdentifier"] as? String ?? ""] ?? []
                    var commands: [Command] = []
                    for device in simDevices {
                        guard let udid = device["udid"] as? String else { continue }
                        handled.insert(udid)
                        commands.append(Command(path: xcrun, args: ["simctl", "shutdown", udid], ignoreFailure: true))
                        commands.append(Command(path: xcrun, args: ["simctl", "delete", udid]))
                    }
                    commands.append(Command(path: xcrun, args: ["simctl", "runtime", "delete", runtimeID]))
                    let names = simDevices.compactMap { $0["name"] as? String }
                    items.append(JunkItem(
                        "sim-runtime-\(runtimeID)", .xcode,
                        title: "\(platformName(platform)) \(version) simülatör runtime'ı",
                        detail: names.isEmpty ? "Bu sürüme ait simülatör yok"
                            : "\(names.count) simülatörüyle birlikte: " + names.joined(separator: ", "),
                        note: "Bu sürümde test etmen gerekirse Xcode → Settings → Components'tan yeniden indirebilirsin.",
                        risk: .caution, deletion: .run(commands),
                        knownSize: ((info["sizeBytes"] as? NSNumber)?.int64Value ?? 0) + simDevices.reduce(0) { $0 + dataSize($1) }))
                }
            }
        }

        for (runtime, list) in devices {
            for device in list {
                guard let udid = device["udid"] as? String, !handled.contains(udid),
                      (device["isAvailable"] as? Bool) != false, dataSize(device) > 1_000_000_000 else { continue }
                items.append(JunkItem(
                    "sim-data-\(udid)", .xcode,
                    title: "Simülatör verisi: \(device["name"] as? String ?? udid) (\(runtimeLabel(runtime)))",
                    detail: "Yüklü uygulamalar, fotoğraflar ve önbellekler",
                    note: "Simülatör silinmez; içi fabrika ayarlarına döner.",
                    risk: .caution,
                    deletion: .run([Command(path: xcrun, args: ["simctl", "shutdown", udid], ignoreFailure: true),
                                    Command(path: xcrun, args: ["simctl", "erase", udid])]),
                    knownSize: dataSize(device)))
            }
        }
        return items
    }

    private func platformName(_ id: String) -> String {
        if id.contains("iphone") { return "iOS" }
        if id.contains("watch") { return "watchOS" }
        if id.contains("appletv") { return "tvOS" }
        if id.contains("xr") { return "visionOS" }
        return id
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` → `iOS 26.4`
    private func runtimeLabel(_ id: String) -> String {
        let parts = (id.components(separatedBy: ".").last ?? id).split(separator: "-")
        guard let os = parts.first else { return id }
        return "\(os) " + parts.dropFirst().joined(separator: ".")
    }

    private func archiveItems() -> [JunkItem] {
        struct Archive {
            let path: String
            let bundle: String
            let version: String
            let date: Date
        }
        var archives: [Archive] = []
        for day in children(h("Library/Developer/Xcode/Archives")) {
            for path in children(day) where path.hasSuffix(".xcarchive") {
                guard let data = fm.contents(atPath: path.appendingPath("Info.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                let props = plist["ApplicationProperties"] as? [String: Any]
                archives.append(Archive(
                    path: path,
                    bundle: props?["CFBundleIdentifier"] as? String ?? plist["Name"] as? String ?? "?",
                    version: props?["CFBundleShortVersionString"] as? String ?? "?",
                    date: plist["CreationDate"] as? Date ?? mdate(path) ?? .distantPast))
            }
        }
        var items: [JunkItem] = []
        for (bundle, list) in Dictionary(grouping: archives, by: \.bundle) {
            let newestFirst = list.sorted { $0.date > $1.date }
            guard let latest = newestFirst.first, newestFirst.count > 1 else { continue }
            let old = newestFirst.dropFirst().map(\.path)
            items.append(JunkItem(
                "archives-\(bundle)", .xcode, title: "\(bundle): \(old.count) eski arşiv",
                detail: "Korunacak: v\(latest.version), \(latest.date.formatted(date: .abbreviated, time: .omitted))",
                note: "Eski sürümlerin dSYM dosyaları da silinir.",
                risk: .caution, deletion: .remove(old), sizePaths: old, modified: newestFirst[1].date))
        }
        return items
    }

    // MARK: Projects

    private func projectItems() -> [JunkItem] {
        let candidates = ["Documents", "Desktop", "Developer", "Projects", "Code", "src", "workspace", "dev",
                          "StudioProjects", "AndroidStudioProjects", "flutter_projects"]
        var seen = Set<String>()
        let roots = candidates.map(h).filter { isDir($0) && seen.insert($0.lowercased()).inserted }
        let skip: Set<String> = ["node_modules", "build", "Pods", "DerivedData", "venv", "__pycache__", "dist",
                                 "target", "vendor", "Carthage", "ephemeral", "Library"]
        var items: [JunkItem] = []
        for root in roots {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = url.lastPathComponent
                if name.hasPrefix(".") || skip.contains(name) || enumerator.level > 7 {
                    enumerator.skipDescendants()
                    continue
                }
                inspectProject(url.path, into: &items)
            }
        }
        return items
    }

    private func inspectProject(_ dir: String, into items: inout [JunkItem]) {
        func has(_ file: String) -> Bool { exists(dir.appendingPath(file)) }
        func existing(_ names: [String]) -> [String] { names.map { dir.appendingPath($0) }.filter(isDir) }
        let name = dir.lastPathComponent

        // Record which Gradle/NDK versions are in use (Flutter's android/ folder included).
        if let text = try? String(contentsOfFile: dir.appendingPath("gradle/wrapper/gradle-wrapper.properties"), encoding: .utf8),
           let version = firstMatch(#"gradle-([0-9][0-9A-Za-z.\-]*?)-(?:bin|all)\.zip"#, in: text) {
            projects.gradleVersions.insert(version)
        }
        for file in ["app/build.gradle", "app/build.gradle.kts"] {
            guard let text = try? String(contentsOfFile: dir.appendingPath(file), encoding: .utf8) else { continue }
            if let version = firstMatch(#"ndkVersion\s*=?\s*"([0-9.]+)""#, in: text) { projects.ndkVersions.insert(version) }
            if text.contains("flutter.ndkVersion") { projects.usesFlutterNdk = true }
        }

        if has("pubspec.yaml") {
            projects.count += 1
            let targets = existing(["build", ".dart_tool", "ios/build", "android/build", "android/app/build", "macos/build"])
            if !targets.isEmpty {
                items.append(JunkItem("flutter-\(dir)", .projects, title: "\(name) (Flutter)", detail: dir.tildePath,
                                      note: "flutter clean ile aynı; sonraki derleme daha uzun sürer.",
                                      risk: .safe, deletion: .remove(targets), sizePaths: targets, modified: mdate(dir)))
            }
        } else if (has("settings.gradle") || has("settings.gradle.kts")) && !exists(dir.parentPath.appendingPath("pubspec.yaml")) {
            projects.count += 1
            let targets = existing(["build", "app/build", ".gradle"])
            if !targets.isEmpty {
                items.append(JunkItem("gradle-\(dir)", .projects, title: "\(name) (Gradle)", detail: dir.tildePath,
                                      note: "Derleme çıktıları; sonraki derlemede yeniden oluşur.",
                                      risk: .safe, deletion: .remove(targets), sizePaths: targets, modified: mdate(dir)))
            }
        }

        if has("Package.swift"), isDir(dir.appendingPath(".build")) {
            let target = dir.appendingPath(".build")
            items.append(JunkItem("swiftpm-\(dir)", .projects, title: "\(name) (Swift paketi)", detail: dir.tildePath,
                                  note: "Derleme çıktıları; swift build yeniden oluşturur.",
                                  risk: .safe, deletion: .remove([target]), sizePaths: [target], modified: mdate(dir)))
        }

        if has("package.json") {
            let modules = dir.appendingPath("node_modules")
            if isDir(modules) {
                items.append(JunkItem("node-\(dir)", .projects, title: "\(name): node_modules", detail: dir.tildePath,
                                      note: "Projeyi tekrar çalıştırmadan önce npm/pnpm install gerekir.",
                                      risk: .caution, deletion: .remove([modules]), sizePaths: [modules], modified: mdate(dir)))
            }
            let next = dir.appendingPath(".next")
            if isDir(next) {
                items.append(JunkItem("next-\(dir)", .projects, title: "\(name): .next derleme önbelleği", detail: dir.tildePath,
                                      note: "Next.js bir sonraki çalıştırmada yeniden oluşturur.",
                                      risk: .safe, deletion: .remove([next]), sizePaths: [next], modified: mdate(dir)))
            }
        }
    }

    // MARK: Developer caches

    private func devCacheItems() -> [JunkItem] {
        var items: [JunkItem] = []
        let caches: [(id: String, title: String, path: String, risk: Risk, note: String?)] = [
            ("npm", "npm önbelleği", ".npm/_cacache", .safe, "Paketler gerektiğinde yeniden indirilir."),
            ("yarn", "Yarn önbelleği", "Library/Caches/Yarn", .safe, nil),
            ("pnpm-cache", "pnpm önbelleği", "Library/Caches/pnpm", .safe, nil),
            ("pnpm-store", "pnpm paket deposu", "Library/pnpm/store", .caution, "pnpm projelerinde paketler yeniden indirilir. Önerilen yol: pnpm store prune."),
            ("pip", "pip önbelleği", "Library/Caches/pip", .safe, nil),
            ("uv", "uv önbelleği", ".cache/uv", .safe, nil),
            ("brew", "Homebrew indirme önbelleği", "Library/Caches/Homebrew", .safe, nil),
            ("pods", "CocoaPods önbelleği", "Library/Caches/CocoaPods", .safe, "pod install paketleri yeniden indirir."),
            ("swiftpm", "Swift Package Manager önbelleği", "Library/Caches/org.swift.swiftpm", .safe, nil),
            ("dartserver", "Dart analiz önbelleği", ".dartServer", .safe, "IDE ilk açılışta projeleri yeniden tarar."),
            ("gobuild", "Go derleme önbelleği", "Library/Caches/go-build", .safe, nil),
            ("nodegyp", "node-gyp önbelleği", "Library/Caches/node-gyp", .safe, nil),
            ("typescript", "TypeScript önbelleği", "Library/Caches/typescript", .safe, nil),
            ("pubcache", "Flutter/Dart paket önbelleği (pub-cache)", ".pub-cache", .caution, "Tüm paketler yeniden indirilir; dart pub global ile kurulan araçlar silinir."),
            ("playwright", "Playwright tarayıcıları", "Library/Caches/ms-playwright", .caution, "Playwright kullanan araçlar tarayıcıları yeniden indirir."),
            ("huggingface", "Hugging Face modelleri", ".cache/huggingface", .caution, "İndirilmiş yapay zeka modelleri; kullanırsan yeniden indirilir."),
        ]
        for cache in caches where isDir(h(cache.path)) {
            items.append(JunkItem("cache-\(cache.id)", .devCaches, title: cache.title, detail: h(cache.path).tildePath,
                                  note: cache.note, risk: cache.risk, deletion: .removeContents(h(cache.path)),
                                  sizePaths: [h(cache.path)]))
        }

        // Gradle versions no scanned project uses.
        if projects.count > 0 {
            for path in children(h(".gradle/caches")) {
                let version = path.lastPathComponent
                guard firstMatch(#"^(\d+\.\d+(?:\.\d+)?(?:-rc-\d+)?)$"#, in: version) != nil,
                      !projects.gradleVersions.contains(version) else { continue }
                items.append(JunkItem("gradle-cache-\(version)", .devCaches, title: "Gradle \(version) önbelleği",
                                      detail: path.tildePath,
                                      note: "Taranan projelerin hiçbiri Gradle \(version) kullanmıyor; gerekirse yeniden indirilir.",
                                      risk: .safe, deletion: .remove([path]), sizePaths: [path]))
            }
            for path in children(h(".gradle/wrapper/dists")) {
                guard let version = firstMatch(#"^gradle-(.+)-(?:bin|all)$"#, in: path.lastPathComponent),
                      !projects.gradleVersions.contains(version) else { continue }
                items.append(JunkItem("gradle-dist-\(path.lastPathComponent)", .devCaches, title: "Gradle \(version) dağıtımı",
                                      detail: path.tildePath,
                                      note: "Taranan projelerin hiçbiri bu sürümü kullanmıyor; gerekirse yeniden indirilir.",
                                      risk: .safe, deletion: .remove([path]), sizePaths: [path]))
            }
        }
        let daemonLogs = children(h(".gradle/daemon")).flatMap { children($0) }.filter { $0.hasSuffix(".log") }
        if !daemonLogs.isEmpty {
            items.append(JunkItem("gradle-logs", .devCaches, title: "Gradle arka plan logları", detail: "~/.gradle/daemon",
                                  risk: .safe, deletion: .remove(daemonLogs), sizePaths: daemonLogs))
        }

        let dumps = children(home).filter {
            let name = $0.lastPathComponent
            return name.hasSuffix(".hprof") || name.hasPrefix("java_error_in") || name.hasPrefix("hs_err_pid")
        }
        if !dumps.isEmpty {
            items.append(JunkItem("java-dumps", .devCaches, title: "Java çökme dökümleri (\(dumps.count))",
                                  detail: "Android Studio veya Java çöktüğünde ev klasörüne bırakılan dosyalar",
                                  risk: .safe, deletion: .remove(dumps), sizePaths: dumps))
        }

        // Data of IDE versions that were superseded by a newer install (Android Studio, JetBrains).
        var ide: [String: [String: [String]]] = [:]
        for base in ["Library/Caches/Google", "Library/Application Support/Google", "Library/Logs/Google",
                     "Library/Caches/JetBrains", "Library/Application Support/JetBrains", "Library/Logs/JetBrains"] {
            for path in children(h(base)) {
                let name = path.lastPathComponent
                guard let version = firstMatch(#"^[A-Za-z]+?(\d{4}\.\d+(?:\.\d+)?)$"#, in: name) else { continue }
                let product = String(name.dropLast(version.count))
                ide[product, default: [:]][version, default: []].append(path)
            }
        }
        for (product, versions) in ide where versions.count > 1 {
            let newestFirst = versions.keys.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            let pretty = product == "AndroidStudio" ? "Android Studio" : product
            for version in newestFirst.dropFirst() {
                let paths = versions[version] ?? []
                items.append(JunkItem("ide-\(product)-\(version)", .devCaches, title: "\(pretty) \(version) (eski sürüm verileri)",
                                      detail: "Güncel sürüm: \(newestFirst[0])", note: "Eski sürümün önbellek, ayar ve logları.",
                                      risk: .safe, deletion: .remove(paths), sizePaths: paths))
            }
        }
        return items
    }

    // MARK: Android

    private func androidItems() -> [JunkItem] {
        var items: [JunkItem] = []
        let sdk = [h("Library/Android/sdk"), h("Android/sdk"), ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? ""]
            .first { !$0.isEmpty && isDir($0) }

        if let sdk, projects.count > 0 {
            var referenced = projects.ndkVersions
            var defaultUnknown = false
            if projects.usesFlutterNdk {
                if let version = flutterDefaultNdk() { referenced.insert(version) } else { defaultUnknown = true }
            }
            for path in children(sdk.appendingPath("ndk")) where isDir(path) && !referenced.contains(path.lastPathComponent) {
                let version = path.lastPathComponent
                items.append(JunkItem(
                    "ndk-\(version)", .android, title: "Kullanılmayan NDK \(version)", detail: path.tildePath,
                    note: defaultUnknown ? "Flutter'ın varsayılan NDK sürümü tespit edilemedi; emin değilsen seçme."
                        : "Taranan projelerin hiçbiri bu sürümü istemiyor; gerekirse Android Studio yeniden indirir.",
                    risk: defaultUnknown ? .caution : .safe, deletion: .remove([path]), sizePaths: [path]))
            }
        }

        for avd in children(h(".android/avd")) where avd.hasSuffix(".avd") {
            let name = (avd.lastPathComponent as NSString).deletingPathExtension
            if running.commands.contains(where: { $0.contains("qemu") && $0.contains("-avd \(name)") }) {
                warnings.append("\(name) emülatörü açık olduğu için verisi taranmadı.")
                continue
            }
            let userData = children(avd).filter {
                let file = $0.lastPathComponent
                return file.hasPrefix("userdata-qemu.img") || file.hasPrefix("cache.img") ||
                    ["multiinstance.lock", "read-snapshot.txt", "snapshot.trace"].contains(file)
            } + children(avd.appendingPath("snapshots"))
            guard !userData.isEmpty else { continue }
            items.append(JunkItem(
                "avd-\(name)", .android, title: "Emülatör verisi: \(name)", detail: avd.tildePath,
                note: "Emülatör kalır; içindeki uygulamalar ve veriler silinir, ilk açılış soğuk başlatma olur.",
                risk: .caution, deletion: .remove(userData), sizePaths: userData, modified: mdate(avd)))
        }

        let toolCache = h(".android/cache")
        if isDir(toolCache) {
            items.append(JunkItem("android-cache", .android, title: "Android araç önbelleği", detail: toolCache.tildePath,
                                  risk: .safe, deletion: .removeContents(toolCache), sizePaths: [toolCache]))
        }
        return items
    }

    /// Reads `flutter.ndkVersion` from the installed Flutter SDK.
    private func flutterDefaultNdk() -> String? {
        let candidates = ["/opt/homebrew/bin/flutter", "/usr/local/bin/flutter", h("flutter/bin/flutter"),
                          h("development/flutter/bin/flutter"), h("fvm/default/bin/flutter")]
        for candidate in candidates where exists(candidate) {
            let sdk = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path.parentPath.parentPath
            for file in ["packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt",
                         "packages/flutter_tools/gradle/src/main/groovy/flutter.groovy"] {
                guard let text = try? String(contentsOfFile: sdk.appendingPath(file), encoding: .utf8) else { continue }
                if let version = firstMatch(#"val ndkVersion:\s*String\s*=\s*"([0-9.]+)""#, in: text)
                    ?? firstMatch(#"ndkVersion\s*=\s*"([0-9.]+)""#, in: text) {
                    return version
                }
            }
        }
        return nil
    }

    // MARK: Leftovers of removed apps

    private struct AppInventory {
        var bundleIDs: Set<String> = []
        /// App names; also matched as prefixes ("Antigravity IDE" → Antigravity).
        var names: Set<String> = []
        /// Command-line tools and process names; exact matches only (`open` must not claim "OpenASO").
        var commands: Set<String> = []
        var teamIDs: Set<String> = []
    }

    /// Apple services that keep human-named folders in Application Support.
    private static let systemSupportFolders: Set<String> = [
        "addressbook", "animoji", "appstore", "callhistorydb", "callhistorytransactions", "clouddocs",
        "controlcenter", "crashreporter", "differentialprivacy", "diskimages", "facetime", "fileprovider",
        "icloud", "knowledge", "mobilesync", "music", "networkserviceproxy", "sesstorage", "spotlight",
        "syncservices", "dock", "accessibility", "coreparsec", "photos", "safari", "mail", "maps", "books",
        "podcasts", "messages", "notes", "reminders", "calendars", "shortcuts", "siri", "wallet", "freeform",
        "journal", "passwords", "quicklook", "cloudkit", "applemediaservices", "homekit",
    ]

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func leftoverItems(excluding covered: Set<String>) -> [JunkItem] {
        struct Group {
            var name: String
            var bundleID: String?
            var paths: [String] = []
            var places: Set<String> = []
        }
        let inventory = appInventory()
        let library = h("Library")
        var groups: [String: Group] = [:]

        func looksLikeBundleID(_ text: String) -> Bool {
            firstMatch(#"^([A-Za-z0-9-]+(?:\.[A-Za-z0-9_-]+){2,})$"#, in: text) != nil
        }
        func add(_ path: String, key: String, name: String, place: String) {
            // Paths another category already offers (e.g. SwiftPM cache) aren't listed twice.
            guard !covered.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { return }
            groups[key, default: Group(name: name)].paths.append(path)
            groups[key]?.places.insert(place)
        }

        let namedByID: [(dir: String, suffix: String?)] = [
            ("Containers", nil), ("Caches", nil), ("HTTPStorages", ".binarycookies"), ("WebKit", nil),
            ("Application Support", nil), ("Saved Application State", ".savedState"), ("Preferences", ".plist"),
        ]
        for (dir, suffix) in namedByID {
            for path in children(library.appendingPath(dir)) {
                var id = path.lastPathComponent
                if let suffix, id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
                guard looksLikeBundleID(id), !isOwned(id, team: nil, vendorWide: false, by: inventory) else { continue }
                add(path, key: id.lowercased(), name: id, place: dir)
            }
        }

        // Group containers are shared by a vendor's apps: match by signing team or vendor prefix.
        for path in children(library.appendingPath("Group Containers")) {
            var id = path.lastPathComponent
            var team: String?
            if let prefix = firstMatch(#"^([A-Z0-9]{10})\."#, in: id) {
                team = prefix
                id = String(id.dropFirst(prefix.count + 1))
            }
            if id.hasPrefix("group.") { id = String(id.dropFirst(6)) }
            guard team != nil || id.split(separator: ".").count >= 2,
                  !isOwned(id, team: team, vendorWide: true, by: inventory) else { continue }
            add(path, key: id.lowercased(), name: path.lastPathComponent, place: "Group Containers")
        }

        for path in children(library.appendingPath("Application Support")) where isDir(path) {
            let name = path.lastPathComponent
            guard !looksLikeBundleID(name), !isOwned(humanName: name, by: inventory) else { continue }
            let key = "name:" + Self.normalized(name)
            add(path, key: key, name: name, place: "Application Support")
            let cache = library.appendingPath("Caches").appendingPath(name)
            if isDir(cache) { add(cache, key: key, name: name, place: "Caches") }
        }

        // Fold extensions and helpers into their app (com.foo.app.widget → com.foo.app).
        var merged: [String: Group] = [:]
        for key in groups.keys.sorted(by: { $0.count < $1.count }) {
            guard let group = groups[key] else { continue }
            if let root = merged.keys.first(where: { !$0.hasPrefix("name:") && key.hasPrefix($0 + ".") }) {
                merged[root]?.paths += group.paths
                merged[root]?.places.formUnion(group.places)
            } else {
                merged[key] = group
            }
        }
        // A human-named folder joins the bundle-id group it names ("OpenASO" → com.thirdtech.openaso).
        for key in merged.keys.filter({ $0.hasPrefix("name:") }) {
            let name = String(key.dropFirst(5))
            guard let target = merged.keys.first(where: {
                      !$0.hasPrefix("name:") && $0.split(separator: ".").contains { Self.normalized(String($0)) == name }
                  }),
                  var group = merged[target],
                  let human = merged.removeValue(forKey: key) else { continue }
            group.paths += human.paths
            group.places.formUnion(human.places)
            group.bundleID = group.name
            group.name = human.name
            merged[target] = group
        }

        var items: [JunkItem] = []
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for (key, group) in merged {
            // Data touched in the last month belongs to something still in use, even if we couldn't match it.
            guard let last = group.paths.compactMap(lastActivity).max(), last < cutoff else { continue }
            items.append(JunkItem(
                "leftover-\(key)", .leftovers, title: group.name,
                detail: group.places.sorted().joined(separator: ", ") + (group.bundleID.map { " · \($0)" } ?? ""),
                note: "Bu verilere ait kurulu bir uygulama bulunamadı. Uygulamayı yeniden kurarsan ayarları ve verileri sıfırdan başlar.",
                risk: .caution, deletion: .remove(group.paths), sizePaths: group.paths, modified: last))
        }

        for path in children(library.appendingPath("LaunchAgents")) where path.hasSuffix(".plist") {
            guard let data = fm.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
                  program.hasPrefix("/"), !program.hasPrefix("/Volumes/"), !exists(program) else { continue }
            let label = plist["Label"] as? String ?? (path.lastPathComponent as NSString).deletingPathExtension
            items.append(JunkItem(
                "agent-\(path)", .leftovers, title: "Sahipsiz arka plan görevi: \(label)",
                detail: "Çalıştırdığı program artık yok: \(program.tildePath)",
                note: "Her oturum açılışında boşuna başlatılmaya çalışılır; silmek güvenli.",
                risk: .safe,
                deletion: .run([Command(path: "/bin/launchctl", args: ["bootout", "gui/\(getuid())/\(label)"], ignoreFailure: true),
                                Command(path: "/bin/rm", args: ["-f", path])]),
                sizePaths: [path], keepSmall: true))
        }
        return items
    }

    private func appInventory() -> AppInventory {
        var inventory = AppInventory()

        func add(bundle path: String) {
            guard let plistPath = [path.appendingPath("Contents/Info.plist"), path.appendingPath("WrappedBundle/Info.plist")]
                .first(where: exists),
                let data = fm.contents(atPath: plistPath),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return }
            if let id = info["CFBundleIdentifier"] as? String { inventory.bundleIDs.insert(id.lowercased()) }
            for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let name = info[key] as? String { inventory.names.insert(Self.normalized(name)) }
            }
            inventory.names.insert(Self.normalized((path.lastPathComponent as NSString).deletingPathExtension))
        }

        for root in ["/Applications", "/System/Applications", h("Applications"), "/System/Library/CoreServices"] {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else {
                    if enumerator.level >= 3 { enumerator.skipDescendants() }
                    continue
                }
                enumerator.skipDescendants()
                add(bundle: url.path)
                // Helpers and extensions don't always extend the app's own bundle id.
                for sub in ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/PlugIns",
                            "Contents/XPCServices", "Contents/Helpers"] {
                    children(url.path.appendingPath(sub)).forEach { add(bundle: $0) }
                }
                if !url.path.hasPrefix("/System/"), let team = teamID(of: url.path) { inventory.teamIDs.insert(team) }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { inventory.bundleIDs.insert(id.lowercased()) }
            if let name = app.localizedName { inventory.names.insert(Self.normalized(name)) }
        }
        running.names.forEach { inventory.commands.insert(Self.normalized($0)) }
        // Command-line tools and Homebrew packages keep data in Application Support too (go, dart, mysql…).
        for dir in ["/opt/homebrew/bin", "/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/bin",
                    "/usr/local/Cellar", "/usr/local/Caskroom", "/usr/bin", h(".local/bin"), h("go/bin"),
                    h(".cargo/bin"), h(".pub-cache/bin")] {
            children(dir).forEach { inventory.commands.insert(Self.normalized($0.lastPathComponent)) }
        }
        inventory.names.remove("")
        inventory.commands.remove("")
        return inventory
    }

    private func teamID(of path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether an installed or running app plausibly owns data named after this bundle id.
    private func isOwned(_ rawID: String, team: String?, vendorWide: Bool, by inventory: AppInventory) -> Bool {
        let id = rawID.lowercased()
        if id.contains("apple") || id.hasPrefix("is.workflow") { return true }
        if let team, inventory.teamIDs.contains(team) { return true }
        if inventory.bundleIDs.contains(id) { return true }
        let parts = id.split(separator: ".").map(String.init)
        // A parent id is installed (extension or helper: com.foo.app.widget → com.foo.app)…
        let minimum = vendorWide ? 2 : 3
        if parts.count > minimum {
            for n in minimum..<parts.count where inventory.bundleIDs.contains(parts.prefix(n).joined(separator: ".")) {
                return true
            }
        }
        // …or this is a vendor-level folder of an installed app (com.foo → com.foo.app).
        if inventory.bundleIDs.contains(where: { $0.hasPrefix(id + ".") }) { return true }
        if vendorWide, parts.count >= 2 {
            let vendor = parts.prefix(2).joined(separator: ".") + "."
            if inventory.bundleIDs.contains(where: { $0.hasPrefix(vendor) }) { return true }
        }
        // LaunchServices also knows apps outside the usual folders (e.g. run from Downloads).
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: rawID)
            .contains { !$0.path.contains("/.Trash/") && exists($0.path) }
    }

    private func isOwned(humanName name: String, by inventory: AppInventory) -> Bool {
        let key = Self.normalized(name)
        guard key.count > 2, !Self.systemSupportFolders.contains(key) else { return true }
        // Apple daemons keep lowercase folders named after themselves (contactsd, tipsd…).
        if name == name.lowercased(), name.hasSuffix("d"), !name.contains(" ") { return true }
        let withoutVersion = String(key.reversed().drop(while: \.isNumber).reversed())
        for candidate in [key, withoutVersion] where inventory.names.contains(candidate) || inventory.commands.contains(candidate) {
            return true
        }
        // Vendor folders ("Google", "BraveSoftware") and suffixed ones ("Antigravity IDE").
        if inventory.names.contains(where: { $0.count >= 4 && key.count >= 4 && (key.hasPrefix($0) || $0.hasPrefix(key)) }) {
            return true
        }
        return inventory.bundleIDs.contains { $0.split(separator: ".").contains { Self.normalized(String($0)) == key } }
    }

    /// Latest modification within two levels; data an app still uses keeps changing.
    private func lastActivity(_ path: String) -> Date? {
        var latest = mdate(path)
        for child in children(path).prefix(200) {
            for date in [mdate(child)] + children(child).prefix(100).map(mdate) {
                if let date, date > (latest ?? .distantPast) { latest = date }
            }
        }
        return latest
    }

    // MARK: Personal files

    private func personalItems() -> [JunkItem] {
        let downloads = h("Downloads")
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: downloads), includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let installerTypes: Set<String> = ["dmg", "pkg", "xip", "iso", "apk", "xapk", "ipa"]
        var found: [(path: String, size: Int64, date: Date?, installer: Bool)] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            let installer = installerTypes.contains(url.pathExtension.lowercased())
            if size >= 200 * MB || (installer && size >= 20 * MB) {
                found.append((url.path, size, values.contentModificationDate, installer))
            }
        }
        return found.sorted { $0.size > $1.size }.prefix(60).map { file in
            JunkItem(
                "download-\(file.path)", .personal, title: file.path.lastPathComponent,
                detail: file.path.parentPath.tildePath,
                note: file.installer ? "Kurulum dosyası; uygulama kurulduysa gereksizdir. Çöp Kutusu'na taşınır."
                    : "Çöp Kutusu'na taşınır; yer açmak için Çöp Kutusu'nu boşaltman gerekir.",
                risk: .caution, deletion: .trash([file.path]), knownSize: file.size, modified: file.date)
        }
    }
}
