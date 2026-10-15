import AppKit
import ViejaCore

struct Browser {
    let id: String
    let url: URL
    var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

enum Browsers {
    static func all(config: Config, includeHidden: Bool = false) -> [Browser] {
        let me = Bundle.main.bundleIdentifier
        let hidden = includeHidden ? [] : Set(config.hiddenBrowsers)
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .compactMap { u -> Browser? in
                guard let id = Bundle(url: u)?.bundleIdentifier, id != me, !hidden.contains(id),
                      seen.insert(id).inserted else { return nil }
                return Browser(id: id, url: u)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Opens `url` in the app with `bundleID`. Returns false if the app is not installed.
    @discardableResult
    static func open(_ url: URL, in bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        if let pid = runningOrionProfile(bundleID), makeTab(url, in: pid) { return true }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err { NSLog("vieja: open failed: %@", err.localizedDescription) }
        }
        return true
    }

    // ponytail: Orion profile apps are bash wrappers that exec /Applications/Orion.app with `-P <uuid>`, so
    // LaunchServices registers every profile as com.kagi.kagimacOS and NSWorkspace may hand the URL to the
    // wrong one. Find the profile's process by argv and create the tab there directly. Generalize if another
    // browser ships wrapper-script profiles.
    private static func runningOrionProfile(_ bundleID: String) -> pid_t? {
        let prefix = "com.kagi.kagimacOS."
        guard bundleID.hasPrefix(prefix) else { return nil }
        let uuid = String(bundleID.dropFirst(prefix.count))
        // not NSWorkspace.runningApplications: LaunchServices lists the profile process with pid -1
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(n, 0)).first { arguments(of: $0).contains(uuid) }
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        // layout: argc (Int32), exec path, NULs, argv[0..argc], env...
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        let parts = buf[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Array(parts.dropFirst().prefix(argc))
    }

    /// AppleScript `make new tab with properties {URL: url}` sent to `pid`. Not a plain get-URL event: Orion
    /// treats that as an external link and forwards it per "Open External Links In" (lands in the wrong profile).
    private static func makeTab(_ url: URL, in pid: pid_t) -> Bool {
        let code = { (s: String) in s.utf8.reduce(FourCharCode(0)) { $0 << 8 | FourCharCode($1) } }
        let props = NSAppleEventDescriptor.record()
        props.setDescriptor(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: code("pURL"))
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("crel"),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(typeCode: code("bTab")), forKeyword: code("kocl"))
        event.setParam(props, forKeyword: code("prdt"))
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 5)
            if let err = reply.paramDescriptor(forKeyword: code("errn")), err.int32Value != 0 {
                NSLog("vieja: make tab in pid %d failed: %d", pid, err.int32Value)
                return false
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            return true
        } catch {
            NSLog("vieja: make tab in pid %d failed: %@", pid, error.localizedDescription)
            return false
        }
    }
}
