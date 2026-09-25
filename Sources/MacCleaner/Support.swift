import AppKit
import Darwin
import Foundation

let MB: Int64 = 1_048_576
let GB: Int64 = 1_073_741_824

// MARK: - Shell

enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    /// Runs a command synchronously. Call from a background context.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        // Read stderr concurrently so a full pipe can't deadlock the child.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - sysctl

enum Sys {
    static func value<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard sysctlbyname(name, buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.load(as: T.self)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static var cpuName: String { string("machdep.cpu.brand_string") ?? "Mac" }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - Disk

struct DiskInfo: Equatable {
    let total: Int64
    let free: Int64
    var used: Int64 { total - free }

    static func current() -> DiskInfo {
        var s = statfs()
        for path in ["/System/Volumes/Data", "/"] where statfs(path, &s) == 0 {
            let block = Int64(s.f_bsize)
            return DiskInfo(total: Int64(s.f_blocks) * block, free: Int64(s.f_bavail) * block)
        }
        return DiskInfo(total: 0, free: 0)
    }
}

// MARK: - Formatting

enum Fmt {
    static func mem(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func mem(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    static func disk(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let d = total / 86_400, h = (total % 86_400) / 3_600, m = (total % 3_600) / 60
        if d > 0 { return h > 0 ? "\(d) gün \(h) sa" : "\(d) gün" }
        if h > 0 { return "\(h) sa \(m) dk" }
        if m > 0 { return "\(m) dk \(total % 60) sn" }
        return "\(total) sn"
    }
}

// MARK: - Paths

extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }

    func appendingPath(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }

    var parentPath: String { (self as NSString).deletingLastPathComponent }

    /// `/private/var/...` and `/var/...` point to the same place; compare them in one form.
    var normalizedPrivate: String { hasPrefix("/private/var/") ? String(dropFirst(8)) : self }

    var tildePath: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}

// MARK: - Icons

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String?) -> NSImage {
        let key = path ?? ""
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let path, !path.isEmpty {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        }
        cache[key] = image
        return image
    }
}
