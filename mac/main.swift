import Cocoa
import WebKit
import UniformTypeIdentifiers
import CoreAudio

let kAppName = "Fresh Music Player"

/// Weak proxy so WKUserContentController doesn't retain the delegate (avoids a retain cycle).
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Transparent strip across the top of the window that drags the window
/// (WKWebView would otherwise swallow the mouse events under the transparent titlebar).
/// The traffic-light buttons live in the titlebar container, which sits above the content
/// view, so they stay clickable.
final class DragStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        if event.clickCount == 2 {
            // Honour System Settings › Desktop & Dock › "Double-click a window's title bar to…"
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize": w.performMiniaturize(nil)
            case "None": break
            default: w.performZoom(nil)
            }
        } else {
            w.performDrag(with: event)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Main-thread hang watchdog. A background thread pings the main queue every second; if main hasn't
/// answered for 3s it appends a line (with the last thing main was doing) to
/// ~/Library/Logs/FreshMusicPlayer/hang.log, and logs again when main recovers.
final class HangWatchdog {
    static let shared = HangWatchdog()
    private let lock = NSLock()
    // Ring of the last few main-thread actions (lastAction alone goes stale for hours).
    private var actions: [(String, UInt64)] = []
    private var lastPong = DispatchTime.now().uptimeNanoseconds   // uptime clock: does NOT advance while asleep
    private var hangStart: UInt64?
    private var asleep = false
    private var wokeAt: UInt64 = 0
    private let logQ = DispatchQueue(label: "fmp.watchdog.log")
    let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FreshMusicPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hang.log")
    }()
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Called from the main thread at the start of anything interesting.
    func note(_ s: String) {
        lock.lock(); actions.append((s, Self.now())); if actions.count > 12 { actions.removeFirst(actions.count - 12) }; lock.unlock()
    }
    /// "a (0.2s ago) <- b (1.5s ago) ..." newest first. Caller holds no lock.
    func recentActions() -> String {
        lock.lock(); let a = actions; lock.unlock()
        let n = Self.now()
        return a.reversed().prefix(8).map { String(format: "%@ (%.1fs ago)", $0.0, Double(n &- $0.1) / 1e9) }.joined(separator: " <- ")
    }

    func start() {
        // System sleep must not look like a hang: pause measurement around sleep/wake.
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [unowned self] _ in
            self.lock.lock(); self.asleep = true; self.lock.unlock(); self.log("system will sleep")
        }
        wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [unowned self] _ in
            self.lock.lock(); self.asleep = false; self.wokeAt = Self.now(); self.lastPong = Self.now(); self.hangStart = nil; self.lock.unlock()
            self.log("system did wake")
        }
        let t = Thread { [unowned self] in self.loop() }
        t.name = "fmp.watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    private func loop() {
        var lastWall = Date(), lastUp = Self.now()
        while true {
            DispatchQueue.main.async { [unowned self] in self.lock.lock(); self.lastPong = Self.now(); self.lock.unlock() }
            Thread.sleep(forTimeInterval: 1.0)
            let wall = Date(), up = Self.now()
            // Belt and braces: if wall clock advanced much more than uptime, we were asleep (or in DarkWake).
            let slept = wall.timeIntervalSince(lastWall) - Double(up &- lastUp) / 1e9 > 2
            lastWall = wall; lastUp = up
            lock.lock()
            if slept { lastPong = up; hangStart = nil; wokeAt = up }
            let stall = Double(up &- lastPong) / 1e9
            let graceful = asleep || Double(up &- wokeAt) / 1e9 < 10      // ignore the first 10s after wake
            let started = hangStart
            var fire = false, recovered: Double? = nil
            if !graceful, stall >= 3, started == nil { hangStart = lastPong; fire = true }
            if stall < 1.5, let st = started { hangStart = nil; recovered = Double(up &- st) / 1e9 }
            lock.unlock()
            if fire {
                log(String(format: "HANG main thread unresponsive for %.1fs (uptime clock); recent: %@", stall, recentActions()))
                sampleMainThread()        // taken NOW, from this thread, while main is still stuck
            } else if let r = recovered {
                log(String(format: "RECOVERED after %.1fs; recent: %@", r, recentActions()))
            }
        }
    }

    private var lastSample = Date.distantPast   // only touched on the watchdog thread
    /// Runs /usr/bin/sample on our own pid for 2s (off the main thread) so a hang has a stack.
    /// Keeps the 5 newest samples; at most one per minute.
    func sampleMainThread() {
        guard Date().timeIntervalSince(lastSample) > 60,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sample") else { return }
        lastSample = Date()
        let dir = logURL.deletingLastPathComponent()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("hang-sample-\(f.string(from: Date())).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-mayDie", "-file", out.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            self?.log("stack sample written to \(out.lastPathComponent)")
            let fm = FileManager.default
            let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("hang-sample-") }.sorted()
            for n in old.dropLast(5) { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        }
        do { try p.run() } catch { log("sample failed: \(error)") }
    }

    /// Small rolling log of web-view attach/detach/heal events (view.log, trimmed at ~256 KB).
    lazy var viewLogURL = logURL.deletingLastPathComponent().appendingPathComponent("view.log")
    func viewLog(_ msg: String) {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone.current
        let line = "\(f.string(from: Date())) \(msg)\n"
        logQ.async { [viewLogURL] in
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let sz = (try? fm.attributesOfItem(atPath: viewLogURL.path))?[.size] as? Int, sz > 256_000 {
                let old = viewLogURL.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old); try? fm.moveItem(at: viewLogURL, to: old)
            }
            if let fh = try? FileHandle(forWritingTo: viewLogURL) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
            else { try? data.write(to: viewLogURL) }
        }
    }

    func log(_ msg: String) {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone.current
        let line = "\(f.string(from: Date())) \(msg)\n"
        logQ.async { [logURL] in
            guard let data = line.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

/// Serves the app's own page and user-opened audio files over a custom scheme:
///   fmp://app/player.html            -> bundle Resources
///   fmp://app/file/<absolute path>   -> a file the user opened (Finder / Open With / Dock)
/// Page and files share one origin, so fetch()/<audio>/Web Audio have no CORS or tainting issues.
/// Supports HTTP Range requests (206 Partial Content) so <audio> can seek when streaming.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "fmp"
    static let host = "app"
    // Stopped tasks. Written on main (WebKit calls stop on main); read on main before every
    // didReceive/didFinish (authoritative) and on the io threads (only to bail out early).
    // Per-task state keyed by the task object identity. A task's entry is created in start and
    // removed exactly once (finish/fail/stop), so the table can't grow and a recycled address
    // can't revive a stopped task (each start gets a fresh Flag object captured by its io work).
    final class Flag { var stopped = false }
    private let stoppedLock = NSLock()
    private var live: [ObjectIdentifier: Flag] = [:]
    private(set) var started = 0, openHandles = 0
    private func flag(_ id: ObjectIdentifier) -> Flag? { stoppedLock.lock(); defer { stoppedLock.unlock() }; return live[id] }
    private func isStopped(_ id: ObjectIdentifier) -> Bool { flag(id)?.stopped ?? true }
    private func setStopped(_ id: ObjectIdentifier, _ on: Bool) {
        stoppedLock.lock()
        if on { live[id]?.stopped = true; live[id] = nil } else { live[id] = Flag(); started += 1 }
        stoppedLock.unlock()
    }
    private func finished(_ id: ObjectIdentifier) { stoppedLock.lock(); live[id] = nil; stoppedLock.unlock() }
    private func handleDelta(_ d: Int) { stoppedLock.lock(); openHandles += d; stoppedLock.unlock() }
    var stats: String { stoppedLock.lock(); defer { stoppedLock.unlock() }; return "schemeTasks live=\(live.count) started=\(started) openFiles=\(openHandles)" }
    private var allowedPaths = Set<String>()            // main-thread only
    private let io = DispatchQueue(label: "fmp.file-io", qos: .userInitiated, attributes: .concurrent)

    static func pageURL() -> URL {
        let t = UserDefaults.standard.string(forKey: "FMPTheme") == "black" ? "black" : "light"
        return URL(string: "\(scheme)://\(host)/player.html?theme=\(t)")!
    }

    /// Allow-list a local file and return the URL the page should use for it.
    func register(_ fileURL: URL) -> URL? {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        allowedPaths.insert(path)
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = Self.host
        c.path = "/file" + path
        return c.url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        setStopped(id, false)
        let myFlag = flag(id)!
        HangWatchdog.shared.note("scheme start \(task.request.url?.lastPathComponent ?? "?") \(task.request.value(forHTTPHeaderField: "Range") ?? "")")
        guard let url = task.request.url else { return fail(task, 400) }
        let reqPath = url.path   // percent-decoded
        let fileURL: URL
        if reqPath.hasPrefix("/file/") {
            let path = String(reqPath.dropFirst("/file".count))
            guard allowedPaths.contains(path) else { return fail(task, 403) }
            fileURL = URL(fileURLWithPath: path)
        } else {
            guard let res = Bundle.main.resourceURL else { return fail(task, 404) }
            let rel = reqPath.isEmpty || reqPath == "/" ? "player.html" : String(reqPath.drop(while: { $0 == "/" }))
            let candidate = res.appendingPathComponent(rel).standardizedFileURL
            guard candidate.path.hasPrefix(res.standardizedFileURL.path) else { return fail(task, 403) }
            fileURL = candidate
        }
        let rangeHeader = task.request.value(forHTTPHeaderField: "Range")
        let isHead = task.request.httpMethod == "HEAD"

        io.async { [weak self] in
            guard let self = self else { return }
            guard let fh = try? FileHandle(forReadingFrom: fileURL),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let sizeNum = attrs[.size] as? NSNumber else {
                DispatchQueue.main.async { self.fail(task, 404) }
                return
            }
            self.handleDelta(1)
            defer { try? fh.close(); self.handleDelta(-1) }
            let size = sizeNum.int64Value
            var start: Int64 = 0, end: Int64 = max(0, size - 1), status = 200
            if let r = rangeHeader, let parsed = Self.parseRange(r, size: size) {
                (start, end) = parsed; status = 206
            } else if rangeHeader != nil && size > 0 {
                DispatchQueue.main.async {
                    guard !myFlag.stopped else { return }
                    let resp = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Range": "bytes */\(size)", "Access-Control-Allow-Origin": "*"])!
                    task.didReceive(resp); task.didFinish(); self.finished(id)
                }
                return
            }
            let length = size == 0 ? 0 : end - start + 1
            var headers: [String: String] = [
                "Content-Type": Self.mimeType(for: fileURL),
                "Content-Length": String(length),
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-cache",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
            ]
            if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            // Never block an io thread on the main thread (the old main.sync per chunk could stall
            // or deadlock against WebKit). Everything is posted with main.async; the main queue is
            // FIFO so response -> chunks -> finish keep their order. A semaphore bounds how many
            // chunks are queued on main so a big file can't pile up hundreds of MB in memory.
            DispatchQueue.main.async {
                if !myFlag.stopped { task.didReceive(resp) }
            }
            if !isHead && length > 0 {
                do { try fh.seek(toOffset: UInt64(start)) } catch {
                    DispatchQueue.main.async { if !myFlag.stopped { task.didFailWithError(error); self.finished(id) } }
                    return
                }
                let inflight = DispatchSemaphore(value: 4)
                var remaining = length
                let chunk: Int64 = 256 * 1024
                while remaining > 0 {
                    if myFlag.stopped { return }
                    // Wait (on this io thread only) for main to drain; re-check cancellation meanwhile.
                    while inflight.wait(timeout: .now() + 0.5) == .timedOut {
                        if myFlag.stopped { return }
                    }
                    let n = Int(min(chunk, remaining))
                    let data = autoreleasepool { fh.readData(ofLength: n) }
                    if data.isEmpty { inflight.signal(); break }
                    remaining -= Int64(data.count)
                    DispatchQueue.main.async {
                        if !myFlag.stopped { task.didReceive(data) }
                        inflight.signal()
                    }
                }
            }
            DispatchQueue.main.async {
                if !myFlag.stopped { task.didFinish() }
                self.finished(id)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        setStopped(ObjectIdentifier(task), true)
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        let id = ObjectIdentifier(task)
        guard !isStopped(id) else { return }
        if let url = task.request.url,
           let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Length": "0", "Access-Control-Allow-Origin": "*"]) {
            task.didReceive(resp)
            task.didFinish()
        } else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
        }
        finished(id)
    }

    /// Parses a single "bytes=a-b", "bytes=a-" or "bytes=-n" range. Returns nil if unsatisfiable.
    static func parseRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard size > 0 else { return nil }
        let h = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard h.hasPrefix("bytes=") else { return nil }
        let spec = h.dropFirst(6).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {                        // suffix: last n bytes
            guard let n = Int64(parts[1]), n > 0 else { return nil }
            return (max(0, size - n), size - 1)
        }
        guard let s = Int64(parts[0]), s < size else { return nil }
        var e = parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? size - 1)
        e = min(e, size - 1)
        guard e >= s else { return nil }
        return (s, e)
    }

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let known: [String: String] = [
            "html": "text/html; charset=utf-8", "js": "text/javascript", "css": "text/css",
            "mp3": "audio/mpeg", "wav": "audio/wav", "wave": "audio/wav", "m4a": "audio/mp4", "mp4": "audio/mp4",
            "aac": "audio/aac", "aif": "audio/aiff", "aiff": "audio/aiff", "aifc": "audio/aiff",
            "flac": "audio/flac", "ogg": "audio/ogg", "oga": "audio/ogg", "opus": "audio/ogg", "caf": "audio/x-caf"]
        if let m = known[ext] { return m }
        if let t = UTType(filenameExtension: ext), let m = t.preferredMIMEType { return m }
        return "application/octet-stream"
    }
}

// MARK: Audio output devices (CoreAudio)
// WKWebView has no reliable setSinkId, so the picker changes the Mac's default
// output device (system-wide) and remembers the choice in UserDefaults.
enum AudioOutputs {
    static let prefKey = "FMPOutputDeviceUID"
    private static let element = AudioObjectPropertyElement(0)

    static var preferredUID: String {
        get { UserDefaults.standard.string(forKey: prefKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: prefKey) }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultDeviceID() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr ? id : 0
    }

    @discardableResult
    static func setDefaultDeviceID(_ id: AudioDeviceID) -> Bool {
        guard id != 0 else { return false }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        let err = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        return err == noErr
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let cf = cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func boolProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var addr = address(selector)
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return nil }
        return val != 0
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let bufs = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufs.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isDefault: Bool
    }

    static func list() -> [Device] {
        let def = defaultDeviceID()
        var out: [Device] = []
        for id in allDeviceIDs() {
            guard hasOutput(id) else { continue }
            if boolProperty(id, kAudioDevicePropertyIsHidden) == true { continue }
            if boolProperty(id, kAudioDevicePropertyDeviceIsAlive) == false { continue }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { continue }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            out.append(Device(id: id, uid: uid, name: name, isDefault: id == def))
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }

    /// Re-apply a remembered device if it is still present. If it disappeared, leave the
    /// current macOS default alone (the preference is kept so the device can return).
    static func applyPreferred() {
        let pref = preferredUID
        guard !pref.isEmpty else { return }
        if let dev = list().first(where: { $0.uid == pref }) {
            if !dev.isDefault { _ = setDefaultDeviceID(dev.id) }
        }
    }

    @discardableResult
    static func select(uid: String) -> Bool {
        preferredUID = uid
        applyPreferred()
        return uid.isEmpty || list().contains(where: { $0.uid == uid })
    }

    static func payload() -> [String: Any] {
        applyPreferred()
        let devices = list()
        let pref = preferredUID
        let selected = (!pref.isEmpty && devices.contains(where: { $0.uid == pref })) ? pref : ""
        return [
            "selected": selected,
            "devices": devices.map { ["uid": $0.uid, "name": $0.name, "isDefault": $0.isDefault] as [String: Any] }
        ]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, NSMenuDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var webView: WKWebView!          // ONE web view, moved between the menu-bar panel and the main window
    var windowContainer: NSView!
    var dragStrip: DragStripView!
    // Menu-bar panel (popover anchored under the status item)
    let popover = NSPopover()
    let panelSize = NSSize(width: 420, height: 560)
    var panelContainer: NSView!
    var currentLayout = "full"
    var clickMonitors: [Any] = []                   // outside-click monitors while the panel is open
    var filePickerOpen = false
    var statusMenuOpen = false
    var lastVisibleSent: Bool?
    // Files handed to the page over fmp:// (kept natively so a WebContent crash can restore the playlist)
    var openedFiles: [URL] = []
    var currentSrc = ""
    var currentTime = 0.0
    var currentPalette = 1
    var currentTheme = UserDefaults.standard.string(forKey: "FMPTheme") == "black" ? "black" : "light"
    var restoreAfterCrash = false
    var lastButtonSymbol = ""
    var statusItem: NSStatusItem!
    let statusMenu = NSMenu()
    var viewFullScreenItem: NSMenuItem?
    let schemeHandler = LocalFileSchemeHandler()
    var pageReady = false
    var pendingOpen: [URL] = []

    // Player state mirrored from JS
    var trackName = ""
    var isPlaying = false
    var currentMode = 1
    var repeatMode = "off"
    var isFullScreen = false
    var modeNames = ["Spectrum", "Waveform", "Radial", "Particles", "Ribbons", "Matrix"]
    let repeatModes: [(id: String, title: String)] = [
        ("off", "Off"), ("once", "Repeat Once"), ("one", "Repeat Track"), ("all", "Repeat All")]
    var audioDevicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var audioDefaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var audioDevicesListener: AudioObjectPropertyListenerBlock?
    var audioDevicePushWork: DispatchWorkItem?

    func applicationWillFinishLaunching(_ note: Notification) {
        // We provide our own full-screen menu item; don't let AppKit add a duplicate.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        HangWatchdog.shared.start()
        HangWatchdog.shared.note("launch")
        applyAppIcon()
        buildMainMenu()
        buildWindow()
        buildPanel()
        applyTheme()
        buildStatusItem()
        startAudioOutputMonitor()
        startHealTimer()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let w = n.object as? NSWindow else { return }
            if w === self.window || w === self.popover.contentViewController?.view.window { self.refreshSurface("didBecomeKey") }
        }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.filePickerOpen else { return }
            self.closePanel()     // Cmd-Tab / clicking another app's window hides the mini player
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in self?.updateVisibility() }
        NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in self?.updateVisibility() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            AudioOutputs.applyPreferred()
            self?.callJS("resumeAudio()")
            self?.pushOutputDevices()
        }
        // Default surface: the compact panel under the menu-bar icon. Wait a beat so the status
        // item has been laid out in the menu bar before anchoring to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !self.window.isVisible else { return }
            self.showPanel()
        }
    }

    /// Dock icon fallback (the bundle's AppIcon.icns is the primary source).
    func applyAppIcon() {
        let res = Bundle.main.resourceURL
        if let u = res?.appendingPathComponent("AppIcon.icns"), let img = NSImage(contentsOf: u) {
            NSApp.applicationIconImage = img
        } else if let u = res?.appendingPathComponent("icon-1024.png"), let img = NSImage(contentsOf: u) {
            NSApp.applicationIconImage = img
        }
    }

    // MARK: Window + WebView
    func buildWindow() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakScriptHandler(self), name: "native")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: LocalFileSchemeHandler.scheme)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        // WebKit stops painting a page whose window it thinks is occluded. Occlusion of popover /
        // re-parented windows is unreliable (esp. after sleep/wake); we tell the page when to draw.
        // (Private occlusion toggle removed in 1.8.1: its KVC key doesn't exist and threw at launch.)
        webView.translatesAutoresizingMaskIntoConstraints = false

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = kAppName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 720, height: 540)
        window.backgroundColor = NSColor(red: 0.984, green: 0.973, blue: 0.957, alpha: 1)
        window.delegate = self
        window.isReleasedWhenClosed = false

        let container = NSView()
        windowContainer = container
        dragStrip = DragStripView()
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dragStrip)
        container.frame = NSRect(x: 0, y: 0, width: 1180, height: 780)
        attachWebView(to: container, reason: "build")
        NSLayoutConstraint.activate([
            dragStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: container.topAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: 30),
        ])
        window.contentView = container
        window.center()
        window.setFrameAutosaveName("FreshMusicPlayerMain")
        // Not shown at launch: the menu-bar panel is the default surface.

        pageReady = false
        webView.load(URLRequest(url: LocalFileSchemeHandler.pageURL()))
    }

    // MARK: Moving the single web view between surfaces
    /// Always (re)seats the web view so it exactly fills `container`, even if it is already there:
    /// frame = bounds + autoresizing (no constraints that can be lost or fight across re-parenting).
    func attachWebView(to container: NSView, reason: String = "") {
        let name = container === windowContainer ? "window" : "panel"
        let before = webView.superview == nil ? "detached" :
            (webView.superview === windowContainer ? "window" : webView.superview === panelContainer ? "panel" : "other")
        if webView.superview !== container {
            webView.removeFromSuperview()
            if container === windowContainer, let strip = dragStrip, strip.superview === container {
                container.addSubview(webView, positioned: .below, relativeTo: strip)
            } else {
                container.addSubview(webView)
            }
        }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        webView.isHidden = false
        webView.alphaValue = 1
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        webView.needsDisplay = true
        HangWatchdog.shared.viewLog("attach \(before) -> \(name) \(reason) container=\(NSStringFromRect(container.bounds)) web=\(NSStringFromRect(webView.frame)) inWindow=\(webView.window != nil) winVisible=\(window?.isVisible ?? false) popover=\(popover.isShown)")
    }

    /// The surface the web view should live on right now (nil = nothing on screen).
    var activeSurface: NSView? {
        if popover.isShown { return panelContainer }
        if window.isVisible && !window.isMiniaturized { return windowContainer }
        return nil
    }

    /// Re-seat + re-layout + force visible + redraw. Called whenever a surface appears or gets key.
    func refreshSurface(_ reason: String) {
        guard let c = activeSurface else { return }
        attachWebView(to: c, reason: reason)
        let want = c === panelContainer ? "compact" : "full"
        currentLayout = want
        callJS("setLayout('\(want)')")
        lastVisibleSent = nil
        updateVisibility()
        callJS("setVisible(true)")
        webView.evaluateJavaScript("window.playerAPI && window.playerAPI.refresh && window.playerAPI.refresh()") { r, _ in
            if let r = r as? String { HangWatchdog.shared.viewLog("page refresh(\(reason)): \(r)") }
        }
    }

    // MARK: Self-heal (page heartbeat)
    // "On screen" is decided natively (popover shown, or window visible + unminimized + occlusion
    // visible). The page's document.visibilityState is only evidence, never the gate.
    var lastHeartbeat = Date()
    var lastHB: [String: Any] = [:]
    var healStage = 0
    var healTimer: Timer?
    var lastHealDecision = ""
    var lastStatsLog = Date.distantPast
    var docHiddenSince: Date?
    var playActivity: NSObjectProtocol?
    var onScreen: Bool {
        if NSApp.isHidden { return false }
        if popover.isShown { return true }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    func startHealTimer() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkHeartbeat() }
        RunLoop.main.add(t, forMode: .common)     // also fires during menu tracking / resizing
        healTimer = t
    }
    /// Logs a heal decision when it changes, so view.log always shows what the healer thinks.
    func healLog(_ d: String) {
        if d != lastHealDecision { lastHealDecision = d; HangWatchdog.shared.viewLog("heal: \(d)") }
    }
    func checkHeartbeat() {
        let age = Date().timeIntervalSince(lastHeartbeat)
        let doc = lastHB["doc"] as? String ?? "?"
        if Date().timeIntervalSince(lastStatsLog) >= 30 {
            lastStatsLog = Date()
            HangWatchdog.shared.viewLog(String(format: "status onScreen=%@ popover=%@ win=%@/%@/occl=%@ pageReady=%@ hbAge=%.1fs page=[%@] %@",
                "\(onScreen)", "\(popover.isShown)", "\(window.isVisible)", window.isMiniaturized ? "mini" : "-",
                "\(window.occlusionState.contains(.visible))", "\(pageReady)", age, describeHB(), schemeHandler.stats))
        }
        guard pageReady else { healLog("idle: page not ready"); lastHeartbeat = Date(); healStage = 0; return }
        guard let c = activeSurface, onScreen else { healLog("idle: not on screen"); lastHeartbeat = Date(); healStage = 0; docHiddenSince = nil; return }
        if filePickerOpen || statusMenuOpen { healLog("idle: modal (picker=\(filePickerOpen) menu=\(statusMenuOpen))"); lastHeartbeat = Date(); return }
        if webView.superview !== c || !NSEqualRects(webView.frame, c.bounds) {
            HangWatchdog.shared.viewLog("heal: view misplaced super=\(webView.superview === c) web=\(NSStringFromRect(webView.frame)) container=\(NSStringFromRect(c.bounds))")
            refreshSurface("misplaced")
        }
        // WebKit believes the page is hidden although it is on screen: it won't paint at all.
        if doc == "hidden", age < 3 {
            if docHiddenSince == nil { docHiddenSince = Date() }
            let h = Date().timeIntervalSince(docHiddenSince!)
            healLog("page reports document hidden while on screen")
            if h >= 3 && healStage == 0 { healStage = 1; forceViewVisibilityUpdate("docHidden"); return }
            if h >= 8 && healStage == 1 { healStage = 2; healReload("document stayed hidden while on screen"); return }
            return
        }
        docHiddenSince = nil
        if age < 3 { healStage = 0; healLog("ok (drawing)"); return }
        if healStage == 0 {
            healStage = 1
            healLog(String(format: "stage1: no healthy heartbeat for %.1fs -> reattach+resize", age))
            forceViewVisibilityUpdate("noHeartbeat")
        } else if healStage == 1 && age >= 7 {
            healStage = 2
            healReload(String(format: "no heartbeat for %.1fs", age))
        } else if healStage == 2 && age >= 25 {
            healLog("stage2 reload gave no heartbeat; allowing another cycle")
            healStage = 1; lastHeartbeat = Date()
        }
    }
    func healReload(_ why: String) {
        healLog("stage2: reload with restore (\(why))")
        HangWatchdog.shared.log("self-heal reload: \(why)")
        restoreAfterCrash = true; pageReady = false; lastVisibleSent = nil
        webView.load(URLRequest(url: LocalFileSchemeHandler.pageURL()))
    }
    /// Pull the view out of its window and put it back (WebKit recomputes its activity/visibility
    /// state on viewDidMoveToWindow), bounce isHidden, then refresh.
    func forceViewVisibilityUpdate(_ why: String) {
        guard let c = activeSurface else { return }
        HangWatchdog.shared.viewLog("heal: force visibility update (\(why))")
        webView.removeFromSuperview()
        attachWebView(to: c, reason: "heal-\(why)")
        webView.isHidden = true; webView.isHidden = false
        refreshSurface("heal-\(why)")
    }
    func describeHB() -> String {
        let keys = ["age", "vis", "doc", "w", "h", "layout", "t", "playing"]
        return keys.compactMap { k in lastHB[k].map { "\(k)=\($0)" } }.joined(separator: " ")
    }
    /// Keep the app from being App-Napped while audio plays.
    func updatePlayActivity() {
        if isPlaying, playActivity == nil {
            playActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Playing audio")
        } else if !isPlaying, let a = playActivity { ProcessInfo.processInfo.endActivity(a); playActivity = nil }
    }

    func setLayout(_ l: String) {
        currentLayout = l
        callJS("setLayout('\(l)')")
    }

    // MARK: Menu-bar panel
    func buildPanel() {
        let vc = NSViewController()
        panelContainer = NSView(frame: NSRect(origin: .zero, size: panelSize))
        panelContainer.wantsLayer = true
        panelContainer.layer?.backgroundColor = NSColor(red: 0.984, green: 0.973, blue: 0.957, alpha: 1).cgColor
        vc.view = panelContainer
        popover.contentViewController = vc
        popover.contentSize = panelSize
        // We decide when it closes (outside-click monitors below). With .transient AppKit closed it on
        // mouse-down — including on the status item itself — which raced our click handler.
        popover.behavior = .applicationDefined
        // No open/close animation: isShown is always the truth and the web view is never re-parented
        // mid-animation.
        popover.animates = false
        popover.appearance = NSAppearance(named: .aqua)   // follows the page theme (applyTheme)
        popover.delegate = self
    }

    func showPanel() {
        HangWatchdog.shared.note("showPanel")
        guard let button = statusItem?.button else { return }
        // Never pop the full window from here; if the user has it open, leave it alone.
        if isFullScreen || (window.isVisible && !window.isMiniaturized) {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return
        }
        if window.isVisible { window.orderOut(nil) }   // minimized window: panel takes over the web view
        if !popover.isShown {
            attachWebView(to: panelContainer)
            setLayout("compact")
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installClickMonitors()
        }
        refreshSurface("showPanel")
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(webView)
        updateVisibility()
    }

    func closePanel() {
        guard popover.isShown else { removeClickMonitors(); return }
        HangWatchdog.shared.note("closePanel")
        popover.performClose(nil)          // -> popoverDidClose (synchronous: animates == false)
        if popover.isShown { popover.close() }
    }

    @objc func togglePanel() { if popover.isShown { closePanel() } else { showPanel() } }

    func popoverDidClose(_ notification: Notification) {
        HangWatchdog.shared.note("popoverDidClose")
        removeClickMonitors()
        // Park the web view in the (hidden) main window so it always has a home; playback continues.
        if !window.isVisible || window.isMiniaturized { attachWebView(to: windowContainer, reason: "park") }
        else { refreshSurface("popoverClosed") }
        updateVisibility()
    }

    /// Close the panel on any mouse-down outside it — in other apps (global monitor) or in our own
    /// other windows (local monitor) — but never on the status item: that click is handled by
    /// statusItemClicked, so "click = open, click = hide" can't race.
    func installClickMonitors() {
        removeClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            guard let self = self, !self.filePickerOpen else { return }
            self.closePanel()
        }) { clickMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            guard let self = self, !self.filePickerOpen, self.popover.isShown else { return e }
            let panelWin = self.popover.contentViewController?.view.window
            let statusWin = self.statusItem?.button?.window
            if e.window == nil || e.window === panelWin || e.window === statusWin { return e }
            if let w = e.window, w.className.contains("Menu") { return e }   // our own menus
            self.closePanel()
            return e
        }) { clickMonitors.append(l) }
    }
    func removeClickMonitors() {
        for m in clickMonitors { NSEvent.removeMonitor(m) }
        clickMonitors.removeAll()
    }

    /// Tells the page whether anything is on screen so it can stop drawing (requestAnimationFrame)
    /// while the player is hidden. Sent only on change.
    func updateVisibility() {
        // Key/main window counts as visible even if occlusion hasn't caught up yet (it lags orderFront).
        let winVisible = window.isVisible && !window.isMiniaturized
            && (window.occlusionState.contains(.visible) || window.isKeyWindow)
        let v = !NSApp.isHidden && (popover.isShown || winVisible)
        guard v != lastVisibleSent else { return }
        lastVisibleSent = v
        callJS("setVisible(\(v))")
    }

    // MARK: Status item clicks
    // Left click: toggle the mini player, immediately. Double clicks don't open the full window.
    // Right click / Ctrl-click: the menu.
    @objc func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.type == .rightMouseDown
            || (event?.modifierFlags.contains(.control) ?? false)
        HangWatchdog.shared.note("statusItemClicked \(isRight ? "right" : "left") count=\(event?.clickCount ?? 0) shown=\(popover.isShown)")
        if isRight { showStatusMenu(); return }
        // The status item only ever toggles the mini player. Extra clicks of a double click are
        // ignored (no flicker, never opens the full window).
        if (event?.clickCount ?? 1) >= 2 { return }
        // If the user already has the full window open, leave it as is: just bring it forward.
        if window.isVisible && !window.isMiniaturized {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return
        }
        togglePanel()
    }

    func showStatusMenu() {
        guard let button = statusItem.button else { return }
        HangWatchdog.shared.note("showStatusMenu")
        closePanel()
        rebuildStatusMenu()
        statusItem.menu = statusMenu
        button.performClick(nil)       // pops the menu (blocks while tracking)
        statusItem.menu = nil          // restore custom click handling
    }
    func menuWillOpen(_ menu: NSMenu) { if menu === statusMenu { statusMenuOpen = true } }
    func menuDidClose(_ menu: NSMenu) { if menu === statusMenu { statusMenuOpen = false } }

    // MARK: Opening files from Finder / Open With / Dock icon drops
    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpen(urls)
    }
    // Legacy fallbacks (only used if the URL-based method above isn't called).
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueueOpen([URL(fileURLWithPath: filename)]); return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueueOpen(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func enqueueOpen(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        pendingOpen.append(contentsOf: files)
        // Show in whichever surface is visible; if neither, use the menu-bar panel.
        if window != nil {
            if window.isVisible { showWindow() }
            else if popover.isShown { NSApp.activate(ignoringOtherApps: true) }
            else if statusItem != nil { showPanel() }
            // else: still launching — applicationDidFinishLaunching shows the panel.
        }
        flushPendingOpen()
    }

    /// Hands queued files to the page once it has posted {type:'ready'} (cold launch via double-click
    /// delivers files before the WebView has loaded).
    func flushPendingOpen() {
        guard pageReady, webView != nil, !pendingOpen.isEmpty else { return }
        let files = pendingOpen
        pendingOpen.removeAll()
        let items: [[String: String]] = files.compactMap { f in
            guard let u = schemeHandler.register(f) else { return nil }
            return ["name": f.lastPathComponent, "url": u.absoluteString]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("addFiles(\(json), {play: true})")
        for f in files where !openedFiles.contains(f) { openedFiles.append(f) }
        for f in files { NSDocumentController.shared.noteNewRecentDocumentURL(f) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageReady = false
    }

    /// The WebContent process crashed or was killed (e.g. memory pressure). Reload the page and put
    /// the playlist back once it posts 'ready'.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        HangWatchdog.shared.log("WebContent process terminated (tracks=\(openedFiles.count), playing=\(isPlaying), lastAction=\"\(currentActionDescription())\"); reloading")
        HangWatchdog.shared.note("webContentTerminated -> reload")
        restoreAfterCrash = true
        pageReady = false
        lastVisibleSent = nil
        webView.load(URLRequest(url: LocalFileSchemeHandler.pageURL()))
    }
    func currentActionDescription() -> String { "\(popover.isShown ? "panel" : window.isVisible ? "window" : "hidden") mode=\(currentMode)" }

    func restorePlaylist() {
        let wasPlaying = isPlaying, src = currentSrc, pos = currentTime
        callJS("setMode(\(currentMode))")
        callJS("setPalette(\(currentPalette))")
        callJS("setTheme('\(currentTheme)', true)")
        callJS("setRepeat('\(repeatMode)')")
        let items: [[String: String]] = openedFiles.compactMap { f in
            guard let u = schemeHandler.register(f) else { return nil }
            return ["name": f.lastPathComponent, "url": u.absoluteString]
        }
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("addFiles(\(json), {play: false})")
        if let i = items.firstIndex(where: { $0["url"] == src }) {
            callJS("loadTrack(\(i), \(wasPlaying), \(pos))")
        }
    }
    // Fallback in case the page's 'ready' message is ever missed.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.pageReady else { return }
            self.pageReady = true
            self.flushPendingOpen()
        }
    }

    /// <input type=file> support
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "flac", "ogg", "public.audio"]
        HangWatchdog.shared.note("openPanel")
        // Picked files go through the same fmp:// path as Finder opens (streamed, not copied into
        // the web process, and restorable after a WebContent crash) instead of <input> File blobs.
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            completionHandler(nil)
            guard let self = self else { return }
            self.filePickerOpen = false
            if resp == .OK { self.enqueueOpen(panel.urls) }
            if self.popover.isShown { self.popover.contentViewController?.view.window?.makeKey() }
        }
        filePickerOpen = true
        if window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: finish)
        }
    }

    // Close button hides the window; playback continues, app lives in the menu bar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        HangWatchdog.shared.note("windowShouldClose")
        if isFullScreen { window.toggleFullScreen(nil) }
        window.orderOut(nil)
        updateVisibility()
        return false
    }
    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { refreshSurface("deminiaturize") }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible), activeSurface === windowContainer { refreshSurface("occlusionVisible") }
        else { updateVisibility() }
    }
    func windowDidResize(_ notification: Notification) {
        if activeSurface === windowContainer, !NSEqualRects(webView.frame, windowContainer.bounds) { refreshSurface("resize") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard window != nil else { return false }
        showWindow()
        return true
    }

    func showWindow() {
        HangWatchdog.shared.note("showWindow")
        guard window != nil, webView != nil, windowContainer != nil else {
            HangWatchdog.shared.log("showWindow called before window was built; ignoring")
            return
        }
        closePanel()
        attachWebView(to: windowContainer, reason: "showWindow")
        setLayout("full")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
        refreshSurface("showWindow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshSurface("showWindow+0.3") }
    }

    // MARK: Full screen
    @objc func toggleFullScreenViz() {
        HangWatchdog.shared.note("toggleFullScreen")
        if !window.isVisible { showWindow() }
        window.toggleFullScreen(nil)
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        dragStrip.isHidden = true
        callJS("setFullscreen(true)")
        refreshMenus()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        dragStrip.isHidden = false
        callJS("setFullscreen(false)")
        refreshMenus()
    }

    // MARK: JS -> native
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "native", let body = message.body as? [String: Any] else { return }
        let type = body["type"] as? String ?? "state"
        if type == "hb" {
            lastHB = body
            let age = (body["age"] as? NSNumber)?.doubleValue ?? 0
            let pageVis = body["vis"] as? Bool ?? true
            if age < 2000 { lastHeartbeat = Date() }      // drawing; otherwise let the healer act
            if !pageVis, onScreen { HangWatchdog.shared.viewLog("heal: page vis=false while on screen -> setVisible(true)"); lastVisibleSent = nil; updateVisibility(); callJS("setVisible(true)") }
            if let st = body["stats"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: st, options: [.sortedKeys]),
               let j = String(data: d, encoding: .utf8) {
                HangWatchdog.shared.viewLog("debugStats \(j) \(schemeHandler.stats) onScreen=\(onScreen)")
            }
            if let t = body["t"] as? NSNumber { currentTime = t.doubleValue }
            // Page layout disagreeing with the surface (e.g. compact CSS in the full window): fix it.
            if let l = body["layout"] as? String, let c = activeSurface {
                let want = c === panelContainer ? "compact" : "full"
                if l != want { HangWatchdog.shared.viewLog("heal: page layout \(l) != \(want)"); refreshSurface("layoutMismatch") }
            }
            return
        }
        HangWatchdog.shared.note("js message \(type)")
        if type == "fullscreen" { toggleFullScreenViz(); return }
        if type == "expand" { showWindow(); return }
        if type == "audio" {
            let ev = body["event"] as? String ?? ""
            let st = body["state"] as? String ?? ""
            let extra = body["extra"] as? String ?? ""
            HangWatchdog.shared.viewLog("audio \(ev) ctx=\(st) playing=\(body["playing"] ?? "") t=\(body["t"] ?? "") \(extra)")
            return
        }
        if type == "setOutput" {
            let uid = body["uid"] as? String ?? ""
            _ = AudioOutputs.select(uid: uid)
            HangWatchdog.shared.viewLog("output device -> \(uid.isEmpty ? "system default" : uid)")
            pushOutputDevices()
            refreshMenus()
            return
        }
        if type == "ready" {
            pageReady = true
            lastVisibleSent = nil
            callJS("setLayout('\(currentLayout)')")
            updateVisibility()
            lastHeartbeat = Date()
            if restoreAfterCrash { restoreAfterCrash = false; restorePlaylist() }
            DispatchQueue.main.async { [weak self] in self?.refreshSurface("ready"); self?.pushOutputDevices() }
            flushPendingOpen(); return
        }
        if let t = body["track"] as? String { trackName = t }
        if let p = body["playing"] as? Bool { isPlaying = p; updatePlayActivity() }
        if let m = body["mode"] as? NSNumber { currentMode = m.intValue }
        if let r = body["repeat"] as? String { repeatMode = r }
        if let names = body["modes"] as? [String], !names.isEmpty { modeNames = names }
        if let pl = body["palette"] as? NSNumber { currentPalette = pl.intValue }
        if let th = body["theme"] as? String, th != currentTheme { currentTheme = th; UserDefaults.standard.set(th, forKey: "FMPTheme"); applyTheme() }
        if let src = body["src"] as? String { currentSrc = src }
        refreshMenus()
    }

    // MARK: native -> JS
    func callJS(_ js: String) {
        guard webView != nil else { return }
        HangWatchdog.shared.note("callJS \(js.prefix(40))")
        webView.evaluateJavaScript("window.playerAPI && window.playerAPI.\(js)", completionHandler: nil)
    }
    @objc func togglePlay() { callJS("togglePlay()") }
    @objc func nextTrack()  { callJS("next()") }
    @objc func prevTrack()  { callJS("prev()") }
    @objc func skipBack15() { callJS("skipBack()") }
    @objc func skipForward15() { callJS("skipForward()") }
    @objc func openFiles()  {
        if !window.isVisible && !popover.isShown { showPanel() }
        callJS("openFiles()")
    }
    @objc func selectMode(_ sender: NSMenuItem) { callJS("setMode(\(sender.tag))") }
    @objc func selectRepeat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        callJS("setRepeat('\(id)')")
    }
    @objc func cycleRepeat() { callJS("cycleRepeat()") }
    @objc func toggleWindow() {
        if window.isVisible { _ = windowShouldClose(window) } else { showWindow() }
        if !window.isVisible { updateVisibility() }
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: kAppName])
    }

    /// Light (cream) or Black: window / panel backing + popover chrome follow the page theme.
    func applyTheme() {
        let dark = currentTheme == "black"
        let bg = dark ? NSColor.black : NSColor(red: 0.984, green: 0.973, blue: 0.957, alpha: 1)
        window?.backgroundColor = bg
        panelContainer?.layer?.backgroundColor = bg.cgColor
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
    @objc func toggleTheme() { callJS("toggleTheme()") }

    func startAudioOutputMonitor() {
        AudioOutputs.applyPreferred()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.outputDevicesChanged() }
        }
        audioDevicesListener = block
        let sys = AudioObjectID(kAudioObjectSystemObject)
        _ = AudioObjectAddPropertyListenerBlock(sys, &audioDevicesAddress, nil, block)
        _ = AudioObjectAddPropertyListenerBlock(sys, &audioDefaultAddress, nil, block)
    }

    func outputDevicesChanged() {
        audioDevicePushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            AudioOutputs.applyPreferred()
            self?.pushOutputDevices()
            self?.refreshMenus()
            self?.callJS("resumeAudio()")
        }
        audioDevicePushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func pushOutputDevices() {
        guard webView != nil else { return }
        let payload = AudioOutputs.payload()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.playerAPI && window.playerAPI.setOutputDevices(\(json))", completionHandler: nil)
    }

    @objc func selectOutput(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        _ = AudioOutputs.select(uid: uid)
        HangWatchdog.shared.viewLog("output device -> \(uid.isEmpty ? "system default" : uid)")
        pushOutputDevices()
        refreshMenus()
        callJS("resumeAudio()")
    }


    /// Cheap: the status menu itself is rebuilt lazily right before it opens (menuNeedsUpdate /
    /// showStatusMenu), never while it's being tracked.
    func refreshMenus() {
        updateStatusButton()
        viewFullScreenItem?.title = isFullScreen ? "Exit Full Screen Visualization" : "Enter Full Screen Visualization"
    }

    // MARK: Status item
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        // No permanent menu: clicks go to statusItemClicked (left = panel, double = window, right = menu).
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshMenus()
    }

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        button.toolTip = trackName.isEmpty ? "\(kAppName) — nothing playing" : "\(isPlaying ? "▶︎" : "❚❚") \(trackName)"
        let symbol = isPlaying ? "waveform" : "waveform.path"
        guard symbol != lastButtonSymbol else { return }
        lastButtonSymbol = symbol
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: kAppName)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: kAppName) {
            img.isTemplate = true
            button.image = img
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === statusMenu && !statusMenuOpen { rebuildStatusMenu() } }

    func item(_ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        if action != nil { it.target = self }
        return it
    }

    func rebuildStatusMenu() {
        statusMenu.removeAllItems()

        let now = NSMenuItem(title: trackName.isEmpty ? "Nothing playing" : trackName, action: nil, keyEquivalent: "")
        now.isEnabled = false
        if let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) { img.isTemplate = true; now.image = img }
        statusMenu.addItem(now)
        statusMenu.addItem(.separator())

        statusMenu.addItem(item(isPlaying ? "Pause" : "Play", #selector(togglePlay)))
        statusMenu.addItem(item("Next", #selector(nextTrack)))
        statusMenu.addItem(item("Previous", #selector(prevTrack)))
        statusMenu.addItem(item("Skip Back 15s", #selector(skipBack15), "j", mods: []))
        statusMenu.addItem(item("Skip Forward 15s", #selector(skipForward15), "l", mods: []))
        statusMenu.addItem(.separator())

        let vizItem = NSMenuItem(title: "Visualization", action: nil, keyEquivalent: "")
        let viz = NSMenu(title: "Visualization")
        for (i, name) in modeNames.enumerated() {
            let it = item(name, #selector(selectMode(_:)), "\(i + 1)", mods: [])
            it.tag = i + 1
            it.state = (i + 1 == currentMode) ? .on : .off
            viz.addItem(it)
        }
        vizItem.submenu = viz
        statusMenu.addItem(vizItem)

        let rptItem = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
        let rpt = NSMenu(title: "Repeat")
        for r in repeatModes {
            let it = item(r.title, #selector(selectRepeat(_:)))
            it.representedObject = r.id
            it.state = (r.id == repeatMode) ? .on : .off
            rpt.addItem(it)
        }
        rptItem.submenu = rpt
        statusMenu.addItem(rptItem)

        let themeItem = item("Black Theme", #selector(toggleTheme), "t", mods: [])
        themeItem.state = currentTheme == "black" ? .on : .off
        statusMenu.addItem(themeItem)

        let outItem = NSMenuItem(title: "Sound Output", action: nil, keyEquivalent: "")
        let outMenu = NSMenu(title: "Sound Output")
        let pref = AudioOutputs.preferredUID
        let sysItem = item("System Default", #selector(selectOutput(_:)), mods: [])
        sysItem.representedObject = ""
        sysItem.state = pref.isEmpty ? .on : .off
        outMenu.addItem(sysItem)
        outMenu.addItem(.separator())
        for dev in AudioOutputs.list() {
            let it = item(dev.name, #selector(selectOutput(_:)), mods: [])
            it.representedObject = dev.uid
            it.state = (dev.uid == pref) ? .on : .off
            outMenu.addItem(it)
        }
        outItem.submenu = outMenu
        statusMenu.addItem(outItem)

        let fsItem = item("Full Screen Visualization", #selector(toggleFullScreenViz), "f", mods: [.command, .control])
        fsItem.state = isFullScreen ? .on : .off
        statusMenu.addItem(fsItem)
        statusMenu.addItem(item("Open Files…", #selector(openFiles)))
        statusMenu.addItem(.separator())

        let panelShown = popover.isShown
        statusMenu.addItem(item(panelShown ? "Hide Mini Player" : "Show Mini Player", #selector(togglePanel), mods: []))
        let visible = window?.isVisible ?? false
        statusMenu.addItem(item(visible ? "Hide Player Window" : "Show Player Window", #selector(toggleWindow), mods: []))
        statusMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(kAppName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu.addItem(quit)
    }

    // MARK: App main menu
    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: kAppName)
        appMenu.addItem(item("About \(kAppName)", #selector(showAbout), mods: []))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(kAppName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(kAppName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Open…", #selector(openFiles), "o"))
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = item("Enter Full Screen Visualization", #selector(toggleFullScreenViz), "f", mods: [.command, .control])
        viewFullScreenItem = fs
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu

        let ctlItem = NSMenuItem(); main.addItem(ctlItem)
        let ctl = NSMenu(title: "Controls")
        ctl.addItem(item("Next", #selector(nextTrack), String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        ctl.addItem(item("Previous", #selector(prevTrack), String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        ctl.addItem(item("Skip Back 15s", #selector(skipBack15), "j", mods: []))
        ctl.addItem(item("Skip Forward 15s", #selector(skipForward15), "l", mods: []))
        ctl.addItem(item("Cycle Repeat", #selector(cycleRepeat), "r"))
        ctlItem.submenu = ctl

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        winMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
