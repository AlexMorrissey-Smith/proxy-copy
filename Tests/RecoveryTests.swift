import Foundation
import Testing
@testable import proxy_copy

private func be(_ value: UInt64, _ count: Int = 4) -> Data {
    Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
private func le(_ value: UInt32, _ count: Int = 4) -> Data { Data(be(UInt64(value), count).reversed()) }
private func box(_ type: String, _ body: Data) -> Data { be(UInt64(body.count + 8)) + Data(type.utf8) + body }
private func tiff(_ tag: UInt32, type: UInt32, value: Data) -> Data {
    Data([0x49, 0x49, 42, 0]) + le(8) + le(1, 2) + le(tag, 2) + le(type, 2)
        + le(UInt32(value.count)) + le(26) + le(0) + value
}

/// Minimal synthetic CR3 with real box/TIFF tables; no camera images in repository.
private func fixture(proxy: Bool = false, id: UInt8 = 7, date: String = "2026:10:28 12:00:00",
                     raw: UInt8 = 31, metadata: UInt8 = 43, emptyFull: Bool = false) -> Data {
    let reduced = Data(repeating: raw, count: 128)
    let full = Data(repeating: proxy || emptyFull ? 0 : 61, count: 256)
    let timed = Data(repeating: metadata, count: 96)
    let ftyp = box(proxy ? "crxp" : "ftyp", Data((proxy ? "crxp" : "crx ").utf8) + be(0))
    let cmt = box("uuid", Data([0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0,
        0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48])
        + box("CMT3", tiff(0x28, type: 1, value: Data(repeating: id, count: 16)))
        + box("CMT2", tiff(0x9003, type: 2, value: Data(date.utf8) + Data([0]))))
    func track(offset: UInt64, length: Int, width: UInt64?) -> Data {
        let entry: Data
        if let width {
            let cmp = Data(repeating: 0, count: 8) + be(width) + be(width)
            entry = box("CRAW", Data(repeating: 0, count: 82) + box("CMP1", cmp))
        } else { entry = box("CTMD", Data()) }
        let description = box("stsd", be(0) + be(1) + entry)
        let sizes = box("stsz", be(0) + be(UInt64(length)) + be(1))
        let offsets = box("co64", be(0) + be(1) + be(offset, 8))
        return box("trak", box("mdia", box("minf", box("stbl", description + sizes + offsets))))
    }
    func moov(_ start: UInt64) -> Data {
        box("moov", cmt + track(offset: start, length: reduced.count, width: 20)
            + track(offset: start + 128, length: full.count, width: 100)
            + track(offset: start + 384, length: timed.count, width: nil))
    }
    let start = UInt64(ftyp.count + moov(0).count + 8)
    return ftyp + moov(start) + box("mdat", reduced + full + timed)
}

private func file(_ bytes: Data) throws -> CR3File {
    try CR3File(CR3Reader(size: UInt64(bytes.count)) { offset, count in
        bytes.subdata(in: Int(offset)..<Int(offset) + count)
    })
}

private struct Workspace {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-copy-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func actualIDReadFromProxyWithoutChangingSignature() throws {
    let proxy = try file(fixture(proxy: true))
    #expect(proxy.placeholder)
    #expect(proxy.imageID == Data(repeating: 7, count: 16))
    #expect(try verifyIdentity(proxy, file(fixture())).hasPrefix("image ID"))
}

@Test(arguments: [1, 2, 99, 254]) func sameSizeAndDateNeverOverrideWrongID(_ id: UInt8) throws {
    #expect(throws: RecoveryError.self) {
        try verifyIdentity(file(fixture(proxy: true)), file(fixture(id: id)))
    }
}

@Test(arguments: [true, false]) func dateFallbackNeedsRetainedBytes(_ missingProxyID: Bool) throws {
    let proxy = try file(fixture(proxy: true, id: missingProxyID ? 0 : 7))
    let original = try file(fixture(id: missingProxyID ? 7 : 0))
    #expect(try verifyIdentity(proxy, original).hasPrefix("capture date fallback"))
    #expect(throws: RecoveryError.self) {
        try verifyIdentity(proxy, file(fixture(id: missingProxyID ? 7 : 0, raw: 32)))
    }
}

@Test func retainedDataAndFullTrackMustBePresent() throws {
    let proxy = try file(fixture(proxy: true))
    for bad in [fixture(raw: 32), fixture(metadata: 44), fixture(emptyFull: true),
                fixture(date: "2026:10:28 12:00:01"), fixture(proxy: true)] {
        #expect(throws: RecoveryError.self) { try verifyIdentity(proxy, file(bad)) }
    }
    #expect(throws: RecoveryError.self) { try verifyIdentity(file(fixture(proxy: true, raw: 0)), file(fixture(raw: 0))) }
}

@Test func missingIDAndWrongDateAreRefused() throws {
    #expect(throws: RecoveryError.self) {
        try verifyIdentity(file(fixture(proxy: true, id: 0)), file(fixture(date: "2026:10:28 12:00:01")))
    }
}

@Test func sizeMismatchAndInvalidFallbackDateAreRefused() throws {
    #expect(throws: RecoveryError.self) {
        try verifyIdentity(file(fixture(proxy: true)), file(fixture() + Data([0])))
    }
    #expect(throws: RecoveryError.self) {
        try verifyIdentity(file(fixture(proxy: true, id: 0, date: "0000:00:00 00:00:00")),
                           file(fixture(id: 0, date: "0000:00:00 00:00:00")))
    }
    #expect(try file(fixture(proxy: true, id: 255)).imageID == nil)
}

@Test func mutatedBoxAndTiffInputsDoNotCrash() throws {
    let original = fixture(proxy: true)
    var random: UInt64 = 12345
    for _ in 0..<2000 {
        random = random &* 6364136223846793005 &+ 1
        let offset = Int(random % UInt64(original.count))
        var bytes = original
        bytes[offset] ^= UInt8(truncatingIfNeeded: random >> 32) | 1
        // Some changes affect uninspected image bytes and are valid; every parser failure must throw.
        _ = try? file(bytes)
    }
}

@Test func malformedInputsAndShortReadsThrow() throws {
    let valid = fixture()
    for count in [0, 1, 7, 8, 15, 32, valid.count - 1] {
        #expect(throws: (any Error).self) { try file(Data(valid.prefix(count))) }
    }
    var bad = valid
    bad.replaceSubrange(0..<4, with: be(UInt64(UInt32.max)))
    #expect(throws: RecoveryError.self) { try file(bad) }
    #expect(throws: RecoveryError.self) { try CR3File(CR3Reader(size: 1024) { _, _ in Data() }) }
}

@Test func ambiguousOriginalsAreSkipped() throws {
    let ws = try Workspace(); defer { ws.clean() }
    let proxy = try ws.write("proxy.CR3", fixture(proxy: true))
    let a = try ws.write("a.CR3", fixture())
    let b = try ws.write("b.CR3", fixture())
    let sources = [a, b].map { Source(name: $0.lastPathComponent, size: fileSize($0), local: $0) }
    let result = match([proxy], sources)
    #expect(result.plan.isEmpty)
    #expect(result.problems.count == 1)
}

@Test func replacementPreservesProxyAndExistingBackup() throws {
    let ws = try Workspace(); defer { ws.clean() }
    let proxyBytes = fixture(proxy: true)
    let fullBytes = fixture()
    let proxy = try ws.write("proxy.CR3", proxyBytes)
    let original = try ws.write("original.CR3", fullBytes)
    let backup = try ws.write("backup.CR3", Data("older backup".utf8))
    try replaceVerified(proxy, original: original, backupRoot: backup)
    #expect(try Data(contentsOf: proxy) == fullBytes)
    #expect(try Data(contentsOf: original) == fullBytes)
    #expect(try Data(contentsOf: backup) == Data("older backup".utf8))
    let copies = try FileManager.default.contentsOfDirectory(at: ws.root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("backup.CR3.") }
    #expect(copies.count == 1)
    #expect(try copies.map { try Data(contentsOf: $0) } == [proxyBytes])
}

@Test func failedVerificationNeverReplacesProxy() throws {
    let ws = try Workspace(); defer { ws.clean() }
    let bytes = fixture(proxy: true)
    let proxy = try ws.write("proxy.CR3", bytes)
    let wrong = try ws.write("wrong.CR3", fixture(id: 42))
    #expect(throws: RecoveryError.self) {
        try replaceVerified(proxy, original: wrong, backupRoot: ws.root.appendingPathComponent("backup.CR3"))
    }
    #expect(try Data(contentsOf: proxy) == bytes)
    #expect(!FileManager.default.fileExists(atPath: ws.root.appendingPathComponent("backup.CR3").path))
}

@Test func backupFailureLeavesProxyUntouched() throws {
    let ws = try Workspace(); defer { ws.clean() }
    let bytes = fixture(proxy: true)
    let proxy = try ws.write("proxy.CR3", bytes)
    let original = try ws.write("original.CR3", fixture())
    let blocker = try ws.write("not-a-directory", Data([1]))
    #expect(throws: (any Error).self) {
        try replaceVerified(proxy, original: original, backupRoot: blocker.appendingPathComponent("backup.CR3"))
    }
    #expect(try Data(contentsOf: proxy) == bytes)
}

@Test func optionalRealPairs() throws {
    guard let path = ProcessInfo.processInfo.environment["PROXY_COPY_CORPUS"] else { return }
    let root = URL(fileURLWithPath: path)
    for name in ["Look 4-0684.CR3", "Look 5-0656.CR3", "Look 9-1083.CR3"] {
        let folder = String(name.prefix(6))
        let proxy = root.appendingPathComponent("Capture/\(folder)/\(name)")
        let original = root.appendingPathComponent("full res/\(name)")
        let originalHash = try fileSHA256(original)
        let proxyHash = try fileSHA256(proxy)
        let a = try CR3File(.local(proxy))
        let b = try CR3File(.local(original))
        #expect(a.imageID != nil && a.imageID == b.imageID)
        #expect(try verifyIdentity(a, b).hasPrefix("image ID"))
        let ws = try Workspace(); defer { ws.clean() }
        let copy = try ws.write("proxy.CR3", Data(contentsOf: proxy))
        let source = Source(name: original.lastPathComponent, size: fileSize(original), local: original)
        let planned = match([copy], [source])
        #expect(planned.plan.count == 1 && planned.problems.isEmpty)
        let backup = ws.root.appendingPathComponent("backup.CR3")
        try replaceVerified(copy, original: original, backupRoot: backup)
        #expect(try fileSHA256(copy) == originalHash)
        #expect(try fileSHA256(backup) == proxyHash)
        #expect(try fileSHA256(proxy) == proxyHash)
        #expect(try fileSHA256(original) == originalHash)
    }
}
