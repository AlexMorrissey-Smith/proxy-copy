import CryptoKit
import Foundation

enum RecoveryError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Reads bounded ranges from a local file or an ImageCaptureCore camera object.
struct CR3Reader {
    let size: UInt64
    let fetch: (UInt64, Int) throws -> Data

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, count <= 8 << 20, offset <= size, UInt64(count) <= size - offset else {
            throw RecoveryError.invalid("CR3 read outside file bounds")
        }
        let data = try fetch(offset, count)
        guard data.count == count else { throw RecoveryError.invalid("short CR3 read") }
        return data
    }

    static func local(_ url: URL) throws -> CR3Reader {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber, number.int64Value > 0 else {
            throw RecoveryError.invalid("not a regular CR3 file")
        }
        return CR3Reader(size: number.uint64Value) { offset, count in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }
}

private struct Box {
    let type: String
    let start: UInt64
    let body: UInt64
    let end: UInt64
}

private func number(_ data: Data, _ at: Int, _ count: Int, little: Bool = false) throws -> UInt64 {
    guard at >= 0, count > 0, count <= 8, at <= data.count, count <= data.count - at else {
        throw RecoveryError.invalid("truncated CR3 metadata")
    }
    return (0..<count).reduce(UInt64(0)) { result, i in
        let index = little ? at + count - 1 - i : at + i
        return (result << 8) | UInt64(data[data.startIndex + index])
    }
}

private func box(_ reader: CR3Reader, at: UInt64, end: UInt64) throws -> Box {
    guard at <= end, end - at >= 8 else { throw RecoveryError.invalid("truncated CR3 box") }
    let header = try reader.read(at, 8)
    let short = try number(header, 0, 4)
    let length: UInt64
    let headerSize: UInt64
    if short == 1 {
        guard end - at >= 16 else { throw RecoveryError.invalid("truncated extended CR3 box") }
        length = try number(reader.read(at + 8, 8), 0, 8)
        headerSize = 16
    } else {
        length = short == 0 ? end - at : short
        headerSize = 8
    }
    guard length >= headerSize, length <= end - at else {
        throw RecoveryError.invalid("invalid CR3 box length")
    }
    return Box(type: String(decoding: header.dropFirst(4), as: UTF8.self), start: at,
               body: at + headerSize, end: at + length)
}

private func boxes(_ reader: CR3Reader, from: UInt64, to: UInt64) throws -> [Box] {
    var result: [Box] = []
    var cursor = from
    while cursor < to {
        guard result.count < 256 else { throw RecoveryError.invalid("too many CR3 boxes") }
        let item = try box(reader, at: cursor, end: to)
        result.append(item)
        cursor = item.end
    }
    return result
}

/// CMT boxes are independent TIFFs. Read the Canon image ID as a tag, never at a fixed offset.
private func tiffTag(_ data: Data, tag: UInt64, type: UInt64) throws -> Data? {
    guard data.count >= 8 else { throw RecoveryError.invalid("truncated CMT TIFF") }
    let little: Bool
    if data.prefix(4) == Data([0x49, 0x49, 42, 0]) { little = true }
    else if data.prefix(4) == Data([0x4d, 0x4d, 0, 42]) { little = false }
    else { throw RecoveryError.invalid("invalid CMT TIFF header") }
    let ifd = Int(try number(data, 4, 4, little: little))
    let count = Int(try number(data, ifd, 2, little: little))
    guard count <= 4096, ifd <= data.count - 2, count <= (data.count - ifd - 2) / 12 else {
        throw RecoveryError.invalid("invalid CMT TIFF directory")
    }
    var found: Data?
    for i in 0..<count {
        let entry = ifd + 2 + 12 * i
        if try number(data, entry, 2, little: little) != tag { continue }
        guard found == nil, try number(data, entry + 2, 2, little: little) == type else {
            throw RecoveryError.invalid("invalid or duplicate identity tag")
        }
        let length = Int(try number(data, entry + 4, 4, little: little))
        let offset = length <= 4 ? entry + 8 : Int(try number(data, entry + 8, 4, little: little))
        guard length <= 4096, offset <= data.count, length <= data.count - offset else {
            throw RecoveryError.invalid("CMT identity tag outside metadata")
        }
        found = data.subdata(in: offset..<offset + length)
    }
    return found
}

struct Sample: Equatable {
    let offset: UInt64
    let length: UInt64
}

struct CR3File {
    let reader: CR3Reader
    let placeholder: Bool
    let imageID: Data?
    let captureTime: String?
    let reduced: Sample
    let metadata: Sample
    let fullRaw: [Sample]

    init(_ reader: CR3Reader) throws {
        self.reader = reader
        let first = try box(reader, at: 0, end: reader.size)
        guard first.type == "ftyp" || first.type == "crxp", first.end <= 4096 else {
            throw RecoveryError.invalid("not a Canon CR3 or wireless proxy")
        }
        let brand = try reader.read(first.body, Int(first.end - first.body))
        // Capture One changes both the box type and major brand to crxp; compatible brands stay crx.
        guard brand.count >= 4, brand.prefix(4) == Data("crx ".utf8)
            || (first.type == "crxp" && brand.prefix(4) == Data("crxp".utf8)) else {
            throw RecoveryError.invalid("not a Canon CR3 brand")
        }
        placeholder = first.type == "crxp"
        let moov = try box(reader, at: first.end, end: reader.size)
        guard moov.type == "moov", moov.end - moov.body <= 8 << 20 else {
            throw RecoveryError.invalid("missing or oversized CR3 moov")
        }
        let data = try reader.read(moov.body, Int(moov.end - moov.body))
        let memory = CR3Reader(size: UInt64(data.count)) { at, count in
            data.subdata(in: Int(at)..<Int(at) + count)
        }
        let children = try boxes(memory, from: 0, to: memory.size)
        var id: Data?
        var timestamp: String?
        var seenIdentityBoxes: Set<String> = []
        var raws: [(UInt64, Sample)] = []
        var metadataSamples: [Sample] = []
        let canonUUID = Data([0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0,
                              0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48])
        for item in children {
            if item.type == "uuid", item.end - item.body >= 16,
               try memory.read(item.body, 16) == canonUUID {
                for cmt in try boxes(memory, from: item.body + 16, to: item.end) {
                    if cmt.type == "CMT3" || cmt.type == "CMT2" {
                        guard seenIdentityBoxes.insert(cmt.type).inserted else {
                            throw RecoveryError.invalid("duplicate CR3 identity metadata box")
                        }
                    }
                    if cmt.type == "CMT3" {
                        let payload = try memory.read(cmt.body, Int(cmt.end - cmt.body))
                        if let value = try tiffTag(payload, tag: 0x28, type: 1) {
                            guard value.count == 16 else { throw RecoveryError.invalid("invalid Canon image ID length") }
                            if value.contains(where: { $0 != 0 }) && value.contains(where: { $0 != 255 }) { id = value }
                        }
                    } else if cmt.type == "CMT2" {
                        let payload = try memory.read(cmt.body, Int(cmt.end - cmt.body))
                        if let value = try tiffTag(payload, tag: 0x9003, type: 2) {
                            let text = String(decoding: value.prefix(while: { $0 != 0 }), as: UTF8.self)
                            let format = DateFormatter()
                            format.locale = Locale(identifier: "en_US_POSIX")
                            format.timeZone = TimeZone(secondsFromGMT: 0)
                            format.dateFormat = "yyyy:MM:dd HH:mm:ss"
                            format.isLenient = false
                            if text.count == 19, let date = format.date(from: text), format.string(from: date) == text {
                                timestamp = text
                            }
                        }
                    }
                }
            }
            guard item.type == "trak" else { continue }
            var table = item
            for type in ["mdia", "minf", "stbl"] {
                guard let next = try boxes(memory, from: table.body, to: table.end).first(where: { $0.type == type }) else {
                    throw RecoveryError.invalid("missing CR3 sample table")
                }
                table = next
            }
            let entries = try boxes(memory, from: table.body, to: table.end)
            guard let stsz = entries.first(where: { $0.type == "stsz" }),
                  let chunk = entries.first(where: { $0.type == "co64" || $0.type == "stco" }),
                  let stsd = entries.first(where: { $0.type == "stsd" }) else {
                throw RecoveryError.invalid("incomplete CR3 sample table")
            }
            let sizes = try memory.read(stsz.body, Int(stsz.end - stsz.body))
            guard try number(sizes, 8, 4) == 1 else { throw RecoveryError.invalid("unsupported CR3 sample count") }
            let fixed = try number(sizes, 4, 4)
            let length = try fixed == 0 ? number(sizes, 12, 4) : fixed
            let chunks = try memory.read(chunk.body, Int(chunk.end - chunk.body))
            guard try number(chunks, 4, 4) == 1 else { throw RecoveryError.invalid("unsupported CR3 chunk count") }
            let offset = try number(chunks, 8, chunk.type == "co64" ? 8 : 4)
            guard offset >= moov.end, offset <= reader.size, length > 0, length <= reader.size - offset else {
                throw RecoveryError.invalid("CR3 sample outside image data")
            }
            let sample = Sample(offset: offset, length: length)
            guard stsd.end - stsd.body >= 8 else { throw RecoveryError.invalid("truncated CR3 sample description") }
            for entry in try boxes(memory, from: stsd.body + 8, to: stsd.end) {
                if entry.type == "CTMD" { metadataSamples.append(sample) }
                if entry.type == "CRAW", entry.end - entry.body >= 82 {
                    for extra in try boxes(memory, from: entry.body + 82, to: entry.end) where extra.type == "CMP1" {
                        let cmp = try memory.read(extra.body, Int(extra.end - extra.body))
                        let width = try number(cmp, 8, 4)
                        let height = try number(cmp, 12, 4)
                        guard width > 0, height > 0, width <= 200_000, height <= 200_000 else {
                            throw RecoveryError.invalid("invalid CR3 raw dimensions")
                        }
                        raws.append((width * height, sample))
                    }
                }
            }
        }
        raws.sort { $0.0 < $1.0 }
        guard raws.count >= 2, let small = raws.first, let large = raws.last, small.0 < large.0,
              metadataSamples.count == 1, let meta = metadataSamples.first,
              small.1.length <= 64 << 20, meta.length <= 16 << 20 else {
            throw RecoveryError.invalid("CR3 has no usable reduced raw and metadata tracks")
        }
        let samples = raws.map(\.1) + metadataSamples
        let ordered = samples.sorted { $0.offset < $1.offset }
        for pair in zip(ordered, ordered.dropFirst()) {
            guard pair.0.offset + pair.0.length <= pair.1.offset else {
                throw RecoveryError.invalid("overlapping CR3 tracks")
            }
        }
        imageID = id
        captureTime = timestamp
        reduced = small.1
        metadata = meta
        fullRaw = Array(raws.dropFirst().map(\.1))
    }

    func fingerprint(_ sample: Sample) throws -> Data {
        var hash = SHA256()
        var offset = sample.offset
        var left = sample.length
        var nonzero = false
        while left > 0 {
            let count = Int(min(left, 256 << 10))
            let data = try reader.read(offset, count)
            nonzero = nonzero || data.contains(where: { $0 != 0 })
            hash.update(data: data)
            offset += UInt64(count)
            left -= UInt64(count)
        }
        guard nonzero else { throw RecoveryError.invalid("retained CR3 track is empty") }
        return Data(hash.finalize())
    }
}

/// Date can fill an absent ID, but can never override two conflicting IDs.
func verifyIdentity(_ proxy: CR3File, _ original: CR3File) throws -> String {
    guard proxy.placeholder, !original.placeholder else { throw RecoveryError.invalid("expected proxy and full original") }
    guard proxy.reader.size == original.reader.size else { throw RecoveryError.invalid("original byte size differs") }
    let reason: String
    if let a = proxy.imageID, let b = original.imageID {
        guard a == b else { throw RecoveryError.invalid("image IDs differ") }
        reason = "image ID + size + retained raw + metadata"
    } else {
        guard let a = proxy.captureTime, let b = original.captureTime, a == b else {
            throw RecoveryError.invalid("missing image ID; capture date cannot confirm match")
        }
        reason = "capture date fallback + size + retained raw + metadata"
    }
    if let a = proxy.captureTime, let b = original.captureTime, a != b {
        throw RecoveryError.invalid("capture dates conflict")
    }
    guard try proxy.fingerprint(proxy.reduced) == original.fingerprint(original.reduced) else {
        throw RecoveryError.invalid("retained reduced raw differs")
    }
    guard try proxy.fingerprint(proxy.metadata) == original.fingerprint(original.metadata) else {
        throw RecoveryError.invalid("retained capture metadata differs")
    }
    for sample in original.fullRaw {
        guard try original.reader.read(sample.offset, Int(min(sample.length, 64))).contains(where: { $0 != 0 }) else {
            throw RecoveryError.invalid("original still has an empty full-resolution raw track")
        }
    }
    return reason
}

func fileSHA256(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
    return Data(hash.finalize())
}

/// Stage and verify before backing up and atomically replacing the proxy.
func replaceVerified(_ proxy: URL, original: URL, backupRoot: URL) throws {
    let manager = FileManager.default
    let initialProxyHash = try fileSHA256(proxy)
    let originalHash = try fileSHA256(original)
    _ = try verifyIdentity(CR3File(.local(proxy)), CR3File(.local(original)))
    let stage = proxy.deletingLastPathComponent().appendingPathComponent(".proxy-copy-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: stage) }
    try manager.copyItem(at: original, to: stage)
    guard try fileSHA256(stage) == originalHash else { throw RecoveryError.invalid("staged copy checksum differs") }
    _ = try verifyIdentity(CR3File(.local(proxy)), CR3File(.local(stage)))
    try manager.createDirectory(at: backupRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Never silently reuse or overwrite a pre-existing backup.
    let backup = manager.fileExists(atPath: backupRoot.path)
        ? backupRoot.deletingLastPathComponent().appendingPathComponent(backupRoot.lastPathComponent + ".\(UUID().uuidString).CR3")
        : backupRoot
    try manager.copyItem(at: proxy, to: backup)
    guard try fileSHA256(backup) == initialProxyHash, try fileSHA256(proxy) == initialProxyHash else {
        throw RecoveryError.invalid("proxy changed during recovery; replacement cancelled")
    }
    let handle = try FileHandle(forWritingTo: stage)
    defer { try? handle.close() }
    try handle.synchronize()
    let backupHandle = try FileHandle(forWritingTo: backup)
    defer { try? backupHandle.close() }
    try backupHandle.synchronize()
    _ = try manager.replaceItemAt(proxy, withItemAt: stage)
}
