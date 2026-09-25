import AppKit
import Darwin
import Foundation
import Observation

// MARK: - System memory

struct MemoryStats {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var compressedOriginal: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Int32 = 1
    var bootTime = Date()

    /// Same definition as Activity Monitor's "Memory Used".
    var used: UInt64 { app + wired + compressed }
    var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }

    static func sample() -> MemoryStats {
        var m = MemoryStats()
        m.total = Sys.value("hw.memsize", as: UInt64.self) ?? 0

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.compressedOriginal = UInt64(vm.total_uncompressed_pages_in_compressor) * page
            m.cached = (UInt64(vm.external_page_count) + purgeable) * page
            let accounted = m.used + m.cached
            m.free = m.total > accounted ? m.total - accounted : UInt64(vm.free_count) * page
        }
        if let swap = Sys.value("vm.swapusage", as: xsw_usage.self) {
            m.swapTotal = swap.xsu_total
            m.swapUsed = swap.xsu_used
        }
        m.pressure = Sys.value("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1
        if let boot = Sys.value("kern.boottime", as: timeval.self) {
            m.bootTime = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        }
        return m
    }
}

// MARK: - Processes

struct ProcInfo: Identifiable, Hashable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let path: String
    let command: String
    let name: String
    let memory: UInt64
    let compressed: UInt64
    let elapsed: TimeInterval
    let responsible: Int32
    let translated: Bool

    var id: Int32 { pid }
    var isMine: Bool { uid == getuid() }

    /// The innermost `.app` whose main executable this process is.
    var appBundle: String? {
        guard let r = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    var displayName: String {
        if let bundle = appBundle { return (bundle.lastPathComponent as NSString).deletingPathExtension }
        return name
    }

    var isAppleService: Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}

enum ProcessSampler {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Private libsystem call Activity Monitor uses to attribute helpers to their app.
    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    /// `top` is setuid root, so unlike `proc_pid_rusage` it can read the footprint of root daemons too.
    static func collect() -> [ProcInfo] {
        var memory: [Int32: (UInt64, UInt64)] = [:]
        let top = Shell.run("/usr/bin/top", ["-l", "1", "-o", "mem", "-stats", "pid,mem,cmprs"])
        var inTable = false
        for line in top.out.split(separator: "\n") {
            if line.hasPrefix("PID") { inTable = true; continue }
            guard inTable else { continue }
            let fields = line.split(separator: " ")
            guard fields.count >= 3, let pid = Int32(fields[0].filter(\.isNumber)) else { continue }
            memory[pid] = (parseSize(fields[1]), parseSize(fields[2]))
        }

        let ps = Shell.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,etime=,command="])
        var result: [ProcInfo] = []
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for line in ps.out.split(separator: "\n") {
            var rest = Substring(line)
            func nextField() -> Substring? {
                rest = rest.drop(while: { $0 == " " })
                guard !rest.isEmpty else { return nil }
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                defer { rest = rest[end...] }
                return rest[rest.startIndex..<end]
            }
            guard let f0 = nextField(), let f1 = nextField(), let f2 = nextField(), let f3 = nextField(),
                  let pid = Int32(f0), let ppid = Int32(f1), let uid = UInt32(f2) else { continue }
            let command = String(rest.drop(while: { $0 == " " }))
            let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0
                ? String(cString: pathBuffer)
                : String(command.split(separator: " ").first ?? "")
            let mem = memory[pid] ?? (0, 0)
            let responsible = responsibleFn?(pid) ?? pid
            result.append(ProcInfo(pid: pid, ppid: ppid, uid: uid, path: path, command: command,
                                   name: path.lastPathComponent.isEmpty ? command : path.lastPathComponent,
                                   memory: mem.0, compressed: mem.1, elapsed: parseElapsed(f3),
                                   responsible: responsible > 0 ? responsible : pid,
                                   translated: isTranslated(pid)))
        }
        if let kernel = memory[0], !result.contains(where: { $0.pid == 0 }) {
            result.append(ProcInfo(pid: 0, ppid: 0, uid: 0, path: "", command: "kernel_task", name: "kernel_task",
                                   memory: kernel.0, compressed: kernel.1,
                                   elapsed: ProcessInfo.processInfo.systemUptime, responsible: 0, translated: false))
        }
        return result
    }

    /// Rosetta-translated processes carry P_TRANSLATED (0x20000) in their proc flags.
    static func isTranslated(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return (info.kp_proc.p_flag & 0x0002_0000) != 0
    }

    static func parseSize(_ raw: Substring) -> UInt64 {
        let text = raw.filter { $0.isNumber || $0 == "." || $0.isLetter }
        guard let unit = text.last, unit.isLetter else { return UInt64(text) ?? 0 }
        let number = Double(text.dropLast()) ?? 0
        let multiplier: Double
        switch unit {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_048_576
        case "G": multiplier = 1_073_741_824
        case "T": multiplier = 1_099_511_627_776
        default: multiplier = 1
        }
        return UInt64(number * multiplier)
    }

    /// `ps` etime: `[[dd-]hh:]mm:ss`
    static func parseElapsed(_ raw: Substring) -> TimeInterval {
        var days = 0.0
        var rest = raw
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let seconds = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86_400 + seconds
    }
}

// MARK: - Table rows

struct KillTarget: Hashable {
    let name: String
    let pids: [Int32]
    let mainPID: Int32
    let memory: UInt64
}

struct MemRow: Identifiable, Hashable {
    let id: String
    let name: String
    let iconPath: String?
    let path: String
    let pids: [Int32]
    let leaderPID: Int32
    let memory: UInt64
    let compressed: UInt64
    let count: Int
    let elapsed: TimeInterval
    let isMine: Bool
    let isProtected: Bool

    var owner: String { isMine ? "Sen" : "Sistem" }
    var canQuit: Bool { isMine && !isProtected }
    var target: KillTarget { KillTarget(name: name, pids: pids, mainPID: leaderPID, memory: memory) }

    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "loginwindow", "WindowServer", "MacCleaner",
        "Dock", "SystemUIServer", "ControlCenter", "WindowManager",
    ]

    init(leader: ProcInfo, members: [ProcInfo], grouped: Bool) {
        id = (grouped ? "g" : "p") + String(leader.pid)
        name = leader.displayName
        iconPath = leader.appBundle ?? (leader.path.isEmpty ? nil : leader.path)
        path = leader.appBundle ?? leader.path
        pids = members.map(\.pid)
        leaderPID = leader.pid
        memory = members.reduce(0) { $0 + $1.memory }
        compressed = members.reduce(0) { $0 + $1.compressed }
        count = members.count
        elapsed = leader.elapsed
        isMine = members.allSatisfy(\.isMine)
        let me = getpid()
        isProtected = members.contains { $0.pid <= 1 || $0.pid == me || Self.protectedNames.contains($0.name) }
    }
}

// MARK: - Findings

struct Finding: Identifiable {
    enum Level: Int, Comparable {
        case info, warning, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    enum Action {
        case kill([Int32])
        case restart
        case none
    }

    let id: String
    let level: Level
    let icon: String
    let title: String
    let detail: String
    var action: Action = .none
    var actionTitle: String? = nil
}

enum FindingEngine {
    static let essentialServices: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "ControlCenter", "WindowManager", "NotificationCenter",
        "loginwindow", "Spotlight", "TextInputMenuAgent", "universalaccessd",
    ]

    static func evaluate(stats: MemoryStats, procs: [ProcInfo]) -> [Finding] {
        var out: [Finding] = []
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let total = max(stats.total, 1)

        let days = Int(stats.uptime / 86_400)
        if days >= 7 {
            out.append(Finding(
                id: "uptime", level: days >= 30 ? .critical : .warning, icon: "clock.arrow.circlepath",
                title: "Mac \(days) gündür yeniden başlatılmadı",
                detail: "Uzun süre açık kalan Mac'te sistem servisleri ve çekirdek bellek sızdırır. Bu bellek yalnızca yeniden başlatınca geri gelir.",
                action: .restart, actionTitle: "Yeniden Başlat…"))
        }

        for p in procs where !p.isMine && p.pid > 0 && p.memory > UInt64(2 * GB) {
            out.append(Finding(
                id: "sys-\(p.pid)", level: .critical, icon: "exclamationmark.triangle.fill",
                title: "\(p.name) \(Fmt.mem(p.memory)) kullanıyor",
                detail: "Bu bir sistem servisi (root). Güvenle kapatılamaz; kullandığı bellek yeniden başlatınca geri gelir.",
                action: .restart, actionTitle: "Yeniden Başlat…"))
        }

        if Double(stats.wired) / Double(total) > 0.25 {
            out.append(Finding(
                id: "wired", level: .warning, icon: "lock.fill",
                title: "Çekirdek belleği (wired) yüksek: \(Fmt.mem(stats.wired))",
                detail: "Normalde toplam belleğin %10–15'i civarındadır. Bu bellek sıkıştırılamaz ve diske taşınamaz; yeniden başlatınca düşer."))
        }

        if stats.swapUsed > UInt64(4 * GB) {
            out.append(Finding(
                id: "swap", level: stats.swapUsed > UInt64(8 * GB) ? .critical : .warning, icon: "externaldrive.fill.badge.exclamationmark",
                title: "Swap kullanımı yüksek: \(Fmt.mem(stats.swapUsed))",
                detail: "RAM yetmediği için bellek diske yazılıyor; donma ve yavaşlamanın başlıca sebebi budur."))
        }

        // xcdevice observers that Flutter/Xcode left behind (their `script` wrapper was reparented to launchd).
        var xcdevice: [Int32] = []
        var xcdeviceMemory: UInt64 = 0
        for p in procs where p.command.contains("xcdevice observe") && p.isMine {
            let parent = byPID[p.ppid]
            let wrapperOrphaned = parent.map { $0.command.hasPrefix("/usr/bin/script") && $0.ppid == 1 } ?? false
            guard p.ppid == 1 || wrapperOrphaned else { continue }
            xcdevice.append(p.pid)
            xcdeviceMemory += p.memory
            if let parent, wrapperOrphaned {
                xcdevice.append(parent.pid)
                xcdeviceMemory += parent.memory
            }
        }
        if !xcdevice.isEmpty {
            out.append(Finding(
                id: "xcdevice", level: .warning, icon: "iphone.slash",
                title: "Sahipsiz xcdevice süreçleri (\(xcdevice.count)) · \(Fmt.mem(xcdeviceMemory))",
                detail: "Flutter veya Xcode'un iPhone algılamak için başlatıp kapatmadığı süreçler. Kapatmak güvenli; gerektiğinde yeniden açılırlar.",
                action: .kill(xcdevice), actionTitle: "Kapat"))
        }

        let orphanDart = procs.filter {
            $0.isMine && $0.ppid == 1 &&
                (["dart", "dartvm", "dartaotruntime"].contains($0.name) ||
                    $0.command.contains("flutter_tools.snapshot") || $0.command.contains("analysis_server"))
        }
        if !orphanDart.isEmpty {
            out.append(Finding(
                id: "dart", level: .warning, icon: "bird",
                title: "Sahipsiz Flutter/Dart süreçleri (\(orphanDart.count)) · \(Fmt.mem(orphanDart.reduce(0) { $0 + $1.memory }))",
                detail: "Kapatılan terminal veya IDE oturumlarından geride kalmış. Kapatmak güvenli.",
                action: .kill(orphanDart.map(\.pid)), actionTitle: "Kapat"))
        }

        let daemons = procs.filter {
            $0.isMine && ($0.command.contains("GradleDaemon") || $0.command.contains("KotlinCompileDaemon"))
        }
        if !daemons.isEmpty {
            out.append(Finding(
                id: "gradle", level: .info, icon: "gearshape.2",
                title: "Gradle/Kotlin arka plan süreçleri (\(daemons.count)) · \(Fmt.mem(daemons.reduce(0) { $0 + $1.memory }))",
                detail: "Derleme bittikten sonra da bellekte kalırlar. Kapatmak güvenli; sonraki derleme biraz daha yavaş başlar.",
                action: .kill(daemons.map(\.pid)), actionTitle: "Kapat"))
        }

        for p in procs where p.isMine && p.isAppleService && p.memory > UInt64(500 * MB) && !essentialServices.contains(p.name) {
            out.append(Finding(
                id: "svc-\(p.pid)", level: .warning, icon: "gauge.with.dots.needle.100percent",
                title: "\(p.name) servisi şişmiş: \(Fmt.mem(p.memory))",
                detail: "macOS'un arka plan servislerinden biri. Kapatırsan sistem gerektiğinde otomatik olarak yeniden başlatır.",
                action: .kill([p.pid]), actionTitle: "Kapat"))
        }

        let translated = procs.filter { $0.isMine && $0.translated }
        if !translated.isEmpty {
            let names = Array(Set(translated.map { byPID[$0.responsible]?.displayName ?? $0.displayName })).sorted()
            out.append(Finding(
                id: "rosetta", level: .warning, icon: "cpu",
                title: "Rosetta ile çalışan süreçler (\(translated.count)) · \(Fmt.mem(translated.reduce(0) { $0 + $1.memory }))",
                detail: "\(names.prefix(5).joined(separator: ", ")) Intel çevirisiyle çalışıyor; daha fazla bellek ve işlemci harcar. Uygulamanın Bilgi Al penceresindeki \"Rosetta kullanarak aç\" seçeneğini kapatıp uygulamayı yeniden başlat."))
        }

        let chrome = procs.filter { $0.path.contains("Google Chrome.app/") }.reduce(UInt64(0)) { $0 + $1.memory }
        if chrome > UInt64(6 * GB) {
            out.append(Finding(
                id: "chrome", level: .info, icon: "globe",
                title: "Google Chrome \(Fmt.mem(chrome)) kullanıyor",
                detail: "Chrome → Ayarlar → Performans → Bellek Tasarrufu'nu açarsan kullanmadığın sekmelerin belleği boşaltılır."))
        }

        return out.sorted { $0.level > $1.level }
    }
}

// MARK: - Monitor

@MainActor
@Observable
final class MemoryMonitor {
    var stats = MemoryStats.sample()
    var processes: [ProcInfo] = []
    var findings: [Finding] = []
    var lastUpdate: Date?
    var busy: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var refreshing = false

    init() {
        Task { await refreshProcesses() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stats = MemoryStats.sample()
                self.tick += 1
                if self.tick % 2 == 0 { await self.refreshProcesses() }
            }
        }
    }

    func refreshProcesses() async {
        guard !refreshing else { return }
        refreshing = true
        let procs = await Task.detached(priority: .utility) { ProcessSampler.collect() }.value
        processes = procs
        stats = MemoryStats.sample()
        findings = FindingEngine.evaluate(stats: stats, procs: procs)
        lastUpdate = Date()
        refreshing = false
    }

    func rows(grouped: Bool, search: String) -> [MemRow] {
        var rows: [MemRow]
        if grouped {
            let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            var groups: [Int32: [ProcInfo]] = [:]
            for p in processes {
                let key = (p.responsible != p.pid && byPID[p.responsible] != nil) ? p.responsible : p.pid
                groups[key, default: []].append(p)
            }
            rows = groups.compactMap { key, members in
                byPID[key].map { MemRow(leader: $0, members: members, grouped: true) }
            }
        } else {
            rows = processes.map { MemRow(leader: $0, members: [$0], grouped: false) }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { rows = rows.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return rows
    }

    // MARK: Actions

    func terminate(_ targets: [KillTarget], force: Bool, reason: String) async -> CleanReport {
        let start = Date()
        let before = MemoryStats.sample()
        busy = force ? "Zorla kapatılıyor…" : "Kapatılıyor…"
        for target in targets {
            let app = NSRunningApplication(processIdentifier: target.mainPID)
            if let app, app.bundleURL != nil {
                _ = force ? app.forceTerminate() : app.terminate()
            }
            if force || app?.bundleURL == nil {
                for pid in target.pids { kill(pid, force ? SIGKILL : SIGTERM) }
            }
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            if targets.allSatisfy({ !Self.isAlive($0.mainPID) }) { break }
        }
        busy = "Bellek ölçülüyor…"
        try? await Task.sleep(for: .seconds(2))
        let after = MemoryStats.sample()
        await refreshProcesses()
        busy = nil

        let entries = targets.map { t -> CleanReport.Entry in
            let alive = t.pids.filter(Self.isAlive)
            let status: CleanReport.Status = alive.isEmpty ? .ok : (alive.count < t.pids.count ? .partial : .failed)
            let message: String? = alive.isEmpty ? nil
                : (force ? "\(alive.count) süreç kapanmadı" : "Hâlâ çalışıyor; Zorla Kapat'ı deneyebilirsin")
            return CleanReport.Entry(title: t.name, category: reason,
                                     detail: "PID " + t.pids.map(String.init).joined(separator: ", "),
                                     bytes: Int64(clamping: t.memory), status: status, message: message)
        }
        return CleanReport(kind: .memory, date: start, duration: Date().timeIntervalSince(start), entries: entries,
                           memUsedBefore: Int64(clamping: before.used), memUsedAfter: Int64(clamping: after.used),
                           swapUsedBefore: Int64(clamping: before.swapUsed), swapUsedAfter: Int64(clamping: after.swapUsed))
    }

    /// Flushes the file cache with `purge`; macOS asks for the admin password.
    func purge() async -> CleanReport? {
        let start = Date()
        let before = MemoryStats.sample()
        busy = "Önbellek boşaltılıyor…"
        let result = await Task.detached {
            Shell.run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"])
        }.value
        defer { busy = nil }
        if result.err.contains("-128") { return nil } // user cancelled the password prompt
        try? await Task.sleep(for: .seconds(1))
        let after = MemoryStats.sample()
        stats = after
        let freed = Int64(clamping: before.cached) - Int64(clamping: after.cached)
        let entry = CleanReport.Entry(
            title: "Disk önbelleği boşaltıldı (purge)", category: "Bellek önbelleği",
            detail: "Önbellek: \(Fmt.mem(before.cached)) → \(Fmt.mem(after.cached))",
            bytes: max(0, freed), status: result.ok ? .ok : .failed,
            message: result.ok ? nil : result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        return CleanReport(kind: .memory, date: start, duration: Date().timeIntervalSince(start), entries: [entry],
                           memUsedBefore: Int64(clamping: before.used), memUsedAfter: Int64(clamping: after.used),
                           swapUsedBefore: Int64(clamping: before.swapUsed), swapUsedAfter: Int64(clamping: after.swapUsed))
    }

    /// Shows the standard macOS restart confirmation.
    func requestRestart() {
        Task.detached {
            Shell.run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrrst»"])
        }
    }

    nonisolated static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
}
