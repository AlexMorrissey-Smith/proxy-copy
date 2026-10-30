// proxy-copy: replace Capture One wireless-tether proxy CR3s with the full-resolution
// originals, pulled straight off any camera attached by USB.
//
// Capture One's gen 2 wireless tethering first writes a low-res proxy CR3 (its first box
// is 'crxp' instead of 'ftyp', and the raw data is zero-filled, though the file is
// already the original's exact byte size), then swaps in the full file when it arrives.
// If the capture folder changes or the images are moved before the full file lands, the
// swap fails, the camera marks the image as transferred, and ReTether never fetches it
// again.
//
// What this does:
//   1. Asks Capture One which session is open and remembers it.
//   2. Quits Capture One, so it lets go of the camera and the session files.
//   3. Scans the whole session folder for proxy CR3s.
//   4. Lists the files on every camera attached by USB (and any --card folder) and
//      matches image ID and exact size, then verifies retained raw and metadata bytes.
//   5. Downloads the matches one at a time, checks each is a full CR3 of exactly the
//      proxy's size, backs the proxy up and puts the original in its place.
//   6. Reopens the session in Capture One.
//
// Uses only what ships with macOS (ImageCaptureCore, CryptoKit, AppleScript), so the built
// binary runs on any Apple silicon Mac with nothing else installed.
//
// Build:
//   swiftc -O -swift-version 5 -target arm64-apple-macos13 \
//     -framework ImageCaptureCore Sources/CR3.swift Sources/main.swift -o proxy-copy

import AppKit
import Foundation
import ImageCaptureCore

let usage = """
usage: proxy-copy [SESSION_DIR_OR_CR3 ...] [--card FOLDER] [--dry]

Replaces Capture One wireless-tether proxy CR3s with the originals from the camera.

  (no paths)     use the session open in Capture One, then reopen it when done
  --card FOLDER  also take originals from this folder of CR3s (a card or volume)
  --dry          only list what would be replaced
  --version      print version
"""

let captureOne = "Capture One"
let backupDirName = "_proxy_backup"
let fm = FileManager.default

// Lines go out in the order things happen, even when piped.
setvbuf(stdout, nil, _IOLBF, 0)

func warn(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { warn(s); exit(1) }

/// Spins the main run loop, which ImageCaptureCore delivers its callbacks on, until
/// `done` is true or the timeout passes. Returns whether it finished in time.
final class CallbackResult<Value> {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }
}

@discardableResult
func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() > deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return true
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: Capture One

func captureOneRunning(includingHelpers: Bool = false) -> Bool {
    // Its helper processes hold the camera too, so quitting waits for every one of them.
    let pattern = includingHelpers ? "\(captureOne).app/" : "\(captureOne).app/Contents/MacOS/"
    return run("/usr/bin/pgrep", ["-f", pattern]).status == 0
}

func appleScript(_ source: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil ? (result?.stringValue ?? "") : nil
}

/// The session folder and .cosessiondb Capture One has open, if it is a session.
func openSession() -> (folder: URL, file: URL)? {
    let script = """
    tell application "\(captureOne)"
        if kind of current document is not session then return ""
        set f to path of current document
        set n to name of current document
    end tell
    return (POSIX path of f) & linefeed & n
    """
    guard let out = appleScript(script), !out.isEmpty else { return nil }
    let parts = out.components(separatedBy: "\n")
    guard parts.count == 2 else { return nil }
    let folder = URL(fileURLWithPath: parts[0]).appendingPathComponent((parts[1] as NSString).deletingPathExtension)
    return (folder, folder.appendingPathComponent(parts[1]))
}

func quitCaptureOne(timeout: TimeInterval = 90) {
    _ = appleScript("tell application \"\(captureOne)\" to quit")
    let deadline = Date().addingTimeInterval(timeout)
    while captureOneRunning(includingHelpers: true) {
        if Date() > deadline { fail("\(captureOne) did not quit within \(Int(timeout))s. Quit it by hand and re-run.") }
        Thread.sleep(forTimeInterval: 1)
    }
    // The camera closes its side of the session a moment after Capture One exits.
    Thread.sleep(forTimeInterval: 3)
}

func reopen(_ session: URL) {
    print("Reopening \(session.lastPathComponent)…")
    run("/usr/bin/open", ["-a", captureOne, session.path])
}

// MARK: Proxies and the session

func label(_ url: URL) -> String {
    "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
}

func isCR3(_ url: URL) -> Bool { url.pathExtension.uppercased() == "CR3" && !url.lastPathComponent.hasPrefix(".") }

func isProxy(_ url: URL) -> Bool {
    guard let h = FileHandle(forReadingAtPath: url.path) else { return false }
    defer { try? h.close() }
    let head = h.readData(ofLength: 8)
    return head.count == 8 && head.subdata(in: 4..<8) == Data("crxp".utf8)
}

func fileSize(_ url: URL) -> Int64 {
    ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
}

func cr3s(under root: URL) -> [URL] {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue { return isCR3(root) ? [root] : [] }
    var found: [URL] = []
    let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    while let url = e?.nextObject() as? URL {
        if url.lastPathComponent == backupDirName || url.lastPathComponent == "Trash" {
            e?.skipDescendants()
        } else if isCR3(url) {
            found.append(url)
        }
    }
    return found
}

/// The session folder holding this file, found by its .cosessiondb.
func sessionRoot(_ url: URL) -> URL? {
    var dir = url.deletingLastPathComponent()
    while dir.path != "/" {
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if names.contains(where: { $0.hasSuffix(".cosessiondb") }) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

// MARK: Sources: cameras and card folders

/// One original that could replace a proxy.
final class Source {
    let name: String
    let size: Int64
    let cameraFile: ICCameraFile?
    var local: URL?

    init(name: String, size: Int64, cameraFile: ICCameraFile? = nil, local: URL? = nil) {
        self.name = name; self.size = size; self.cameraFile = cameraFile; self.local = local
    }
}

/// Cameras attached over USB, through ImageCaptureCore: the same route Image Capture uses,
/// so it works alongside macOS's own camera daemon instead of fighting it for the device.
final class Cameras: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private(set) var devices: [ICCameraDevice] = []
    private var settled = false
    private var ready: Set<ObjectIdentifier> = []
    private var failed: [ObjectIdentifier: String] = [:]

    func find(timeout: TimeInterval = 5) -> [ICCameraDevice] {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        wait(timeout) { settled }
        return devices
    }

    func stop() {
        for d in devices where d.hasOpenSession { d.requestCloseSession() }
        wait(3) { !devices.contains { $0.hasOpenSession } }
        browser.stop()
        browser.delegate = nil
    }

    /// Opens a session and waits for the camera to list everything on its cards.
    func files(on device: ICCameraDevice, timeout: TimeInterval = 120) -> [Source]? {
        device.delegate = self
        let key = ObjectIdentifier(device)
        device.requestOpenSession()
        guard wait(timeout, until: { ready.contains(key) || failed[key] != nil }), failed[key] == nil else {
            warn("Could not read \(device.name ?? "camera"): \(failed[key] ?? "it did not answer within \(Int(timeout))s")")
            return nil
        }
        return (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
            .filter { ($0.name ?? "").uppercased().hasSuffix(".CR3") }
            .map { Source(name: $0.name!, size: Int64($0.fileSize), cameraFile: $0) }
    }

    func download(_ file: ICCameraFile, to dir: URL, timeout: TimeInterval = 300) -> Result<URL, Error> {
        let answer = CallbackResult<Result<URL, Error>>()
        let filename = UUID().uuidString + ".CR3"
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: dir as NSURL,
            .saveAsFilename: filename,
            .overwrite: false,
        ]
        let progress = file.requestDownload(options: options) { name, error in
            if let error { answer.set(.failure(error)) }
            else if let name, name != filename {
                answer.set(.failure(RecoveryError.invalid("camera download returned an unexpected filename")))
            } else { answer.set(.success(dir.appendingPathComponent(filename))) }
        }
        guard wait(timeout, until: { answer.value != nil }), let result = answer.value else {
            progress?.cancel()
            return .failure(NSError(domain: "proxy-copy", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "timed out after \(Int(timeout))s"]))
        }
        return result
    }

    // ICDeviceBrowserDelegate
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        // A card reader shows up as a mass-storage "camera" too; that is a volume, so
        // only real PTP cameras count here.
        if let camera = device as? ICCameraDevice,
           camera.transportType != ICDeviceTransport.transportTypeMassStorage.rawValue {
            devices.append(camera)
        }
        if !moreComing { settled = true }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        devices.removeAll { $0 === device }
        failed[ObjectIdentifier(device)] = "disconnected"
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) { settled = true }

    // ICDeviceDelegate
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error { failed[ObjectIdentifier(device)] = error.localizedDescription }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        ready.insert(ObjectIdentifier(device))
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    func didRemove(_ device: ICDevice) { failed[ObjectIdentifier(device)] = "disconnected" }

    // ICCameraDeviceDelegate (required, unused)
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

func cardFiles(_ folder: URL) -> [Source] {
    cr3s(under: folder).filter { !isProxy($0) }.map { url in
        Source(name: url.lastPathComponent, size: fileSize(url), local: url)
    }
}

// MARK: Matching

struct Plan {
    let proxy: URL
    let source: Source
    let how: String
}

func sourceFile(_ source: Source) throws -> CR3File {
    if let local = source.local { return try CR3File(.local(local)) }
    guard let camera = source.cameraFile, source.size > 0 else {
        throw RecoveryError.invalid("original is unavailable")
    }
    let reader = CR3Reader(size: UInt64(source.size)) { offset, count in
        guard offset <= UInt64(Int64.max) else { throw RecoveryError.invalid("camera offset is too large") }
        let answer = CallbackResult<Result<Data, Error>>()
        camera.requestReadData(atOffset: off_t(offset), length: off_t(count)) { data, error in
            if let error { answer.set(.failure(error)) }
            else if let data { answer.set(.success(data)) }
            else { answer.set(.failure(RecoveryError.invalid("camera returned no data"))) }
        }
        guard wait(30, until: { answer.value != nil }), let result = answer.value else {
            throw RecoveryError.invalid("camera range read timed out")
        }
        return try result.get()
    }
    return try CR3File(reader)
}

/// Inspect actual CR3 identity and retained content, including for USB camera objects.
/// Duplicate verified candidates are refused rather than chosen by enumeration order.
func match(_ proxies: [URL], _ sources: [Source]) -> (plan: [Plan], problems: [(URL, String)]) {
    let bySize = Dictionary(grouping: sources, by: \.size)
    var inspected: [ObjectIdentifier: Result<CR3File, Error>] = [:]
    var plan: [Plan] = []
    var problems: [(URL, String)] = []
    for path in proxies {
        do {
            let proxy = try CR3File(.local(path))
            var verified: [(source: Source, how: String, byID: Bool)] = []
            var lastProblem = "no original of matching size"
            for source in bySize[fileSize(path)] ?? [] {
                do {
                    let key = ObjectIdentifier(source)
                    let result = inspected[key] ?? Result { try sourceFile(source) }
                    inspected[key] = result
                    let original = try result.get()
                    let how = try verifyIdentity(proxy, original)
                    verified.append((source, how, proxy.imageID != nil && original.imageID != nil))
                } catch { lastProblem = error.localizedDescription }
            }
            let primary = verified.filter { $0.byID }
            let fits = primary.isEmpty ? verified : primary
            if fits.count == 1, let candidate = fits.first {
                plan.append(Plan(proxy: path, source: candidate.source, how: candidate.how))
            } else {
                problems.append((path, fits.isEmpty ? lastProblem : "multiple originals pass verification; match is ambiguous"))
            }
        } catch { problems.append((path, error.localizedDescription)) }
    }
    return (plan, problems)
}

func replace(_ proxy: URL, with original: URL, session: URL?) -> String? {
    let backup: URL
    if let session, proxy.path.hasPrefix(session.path + "/") {
        let rel = String(proxy.path.dropFirst(session.path.count + 1))
        backup = session.appendingPathComponent(backupDirName).appendingPathComponent(rel)
    } else {
        backup = proxy.deletingLastPathComponent().appendingPathComponent(backupDirName)
            .appendingPathComponent(proxy.lastPathComponent)
    }
    do {
        try replaceVerified(proxy, original: original, backupRoot: backup)
        return nil
    } catch { return error.localizedDescription }
}

// MARK: Main

var targets: [URL] = []
var card: URL?
var dry = false
var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    switch a {
    case "--version": print("proxy-copy 1.1.0"); exit(0)
    case "--dry": dry = true
    case "--card":
        guard let path = argv.popFirst() else { fail("--card needs a folder.\n\n" + usage) }
        card = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fail("Unknown option \(a).\n\n" + usage) }
        targets.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
    }
}

var sessionFile: URL?
if targets.isEmpty {
    guard captureOneRunning() else { fail("\(captureOne) is not open and no session folder was given.") }
    guard let session = openSession() else { fail("\(captureOne) does not have a session open.") }
    targets = [session.folder]
    sessionFile = session.file
    print("Session: \(session.folder.path)")
}

if !dry, captureOneRunning(includingHelpers: true) {
    print("Quitting \(captureOne)…")
    quitCaptureOne()
}

func fix() -> Int32 {
    let proxies = Array(Set(targets.flatMap(cr3s(under:)).filter(isProxy)))
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    guard !proxies.isEmpty else { print("No proxy CR3s found."); return 0 }
    print("\(proxies.count) proxy CR3(s) found:")
    for p in proxies { print("  \(label(p))") }

    let cameras = Cameras()
    defer { cameras.stop() }
    var sources: [Source] = []
    let attached = dry && captureOneRunning(includingHelpers: true) ? [] : cameras.find()
    for device in attached {
        if let files = cameras.files(on: device) {
            print("Camera: \(device.name ?? "camera"), \(files.count) CR3(s)")
            sources += files
        }
    }
    if let card {
        let files = cardFiles(card)
        print("Folder: \(card.path), \(files.count) CR3(s)")
        sources += files
    }
    if sources.isEmpty {
        if !attached.isEmpty {
            warn("A camera is attached but none of its files could be read. Turn it off and on,\n"
                 + "or specify the path to an attached volume or card with --card.")
        } else {
            warn("No camera connected. Specify the path to an attached volume or card, e.g.\n"
                 + "  proxy-copy --card /Volumes/EOS_DIGITAL")
        }
        return 1
    }

    let (plan, problems) = match(proxies, sources)
    for item in plan {
        print("  " + label(item.proxy).padding(toLength: 34, withPad: " ", startingAt: 0)
              + " <- \(item.source.name)  (\(item.how))")
    }
    for (p, why) in problems { warn("  SKIP \(label(p)): \(why)") }

    if dry {
        print("\nDry run: \(plan.count) to replace, \(problems.count) not found. Run without --dry to replace.")
        return problems.isEmpty ? 0 : 1
    }

    let work = fm.temporaryDirectory.appendingPathComponent("proxy-copy-\(UUID().uuidString)")
    do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
    catch { warn("Could not create download folder: \(error.localizedDescription)"); return 1 }
    defer { try? fm.removeItem(at: work) }

    var failed = 0
    for (i, item) in plan.enumerated() {
        let src = item.source
        if let file = src.cameraFile {
            print("Downloading \(i + 1)/\(plan.count) \(src.name)…")
            switch cameras.download(file, to: work) {
            case .success(let url): src.local = url
            case .failure(let error): warn("  \(error.localizedDescription)")
            }
        }
        let err = src.local.map { replace(item.proxy, with: $0, session: sessionRoot(item.proxy)) } ?? "not downloaded"
        if let err {
            failed += 1
            warn("FAILED \(label(item.proxy)): \(err)")
        } else {
            print("Replaced \(label(item.proxy))")
        }
        if src.cameraFile != nil, let local = src.local { try? fm.removeItem(at: local) }
    }

    let replaced = plan.count - failed
    print("\n\(replaced) replaced, \(failed) failed, \(problems.count) not found."
          + (replaced > 0 ? " Proxies backed up to \(backupDirName)/." : ""))
    return failed > 0 || !problems.isEmpty ? 1 : 0
}

// Whatever happens in between, put the session back the way it was found.
let status = fix()
if !dry, let sessionFile { reopen(sessionFile) }
exit(status)
