import AppKit
import Observation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, memory, cleanup, reports

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Genel Bakış"
        case .memory: "Bellek"
        case .cleanup: "Disk Temizliği"
        case .reports: "Raporlar"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .memory: "memorychip"
        case .cleanup: "externaldrive.badge.minus"
        case .reports: "doc.text.magnifyingglass"
        }
    }
}

@MainActor
@Observable
final class AppState {
    var section: SidebarItem? = .overview
    var presentedReport: CleanReport?

    /// `open MacCleaner.app --args -section cleanup -scan YES` opens a section (and starts a scan) directly.
    init() {
        if let raw = UserDefaults.standard.string(forKey: "section"), let item = SidebarItem(rawValue: raw) {
            section = item
        }
    }
}

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()
    @State private var memory = MemoryMonitor()
    @State private var scanner = JunkScanner()
    @State private var reports = ReportStore()

    var body: some Scene {
        WindowGroup("MacCleaner") {
            ContentView()
                .environment(app)
                .environment(memory)
                .environment(scanner)
                .environment(reports)
                .frame(minWidth: 1_040, minHeight: 700)
        }
        .defaultSize(width: 1_240, height: 900)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(MemoryMonitor.self) private var monitor

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $app.section) { item in
                Label(item.title, systemImage: item.icon)
                    .badge(item == .memory ? monitor.findings.filter { $0.level != .info }.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch app.section ?? .overview {
            case .overview: OverviewView()
            case .memory: MemoryView()
            case .cleanup: CleanupView()
            case .reports: ReportsView()
            }
        }
        .sheet(item: $app.presentedReport) { ReportSheet(report: $0) }
    }
}
