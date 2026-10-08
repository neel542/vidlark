import Foundation

// MARK: - Taking the padding out of camera.mov

// AVCaptureMovieFileOutput starts every chunk of picture or sound on a 16 KB boundary and fills
// the gap with zeros, and with the Mac's mic it often makes every sound packet its own chunk.
// On 5 Oct that padding was 13% of one camera.mov and 44% of another. Tidying copies the chunks
// next to each other and points the movie's chunk table at their new places. Nothing else in the
// file changes: not a byte of picture or sound, not a timestamp. Anything unexpected in the file
// leaves it exactly as it was.

struct TidyResult {
    let before: Int
    let after: Int
    var saved: Int { before - after }
}

/// Tidies every movie the cameras wrote in `folder`. Returns what each one saved; a file that
/// could not be tidied is listed with its reason in `skipped`.
func tidyCameraMovies(in folder: URL) -> (tidied: [String: TidyResult], skipped: [String: String]) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0 == "camera.mov" || ($0.hasPrefix("camera-") && $0.hasSuffix(".mov")) }
        .sorted()
    var tidied: [String: TidyResult] = [:]
    var skipped: [String: String] = [:]
    for name in names {
        do {
            if let result = try tidyMovie(folder.appendingPathComponent(name)) { tidied[name] = result }
        } catch let error as FinishError {
            skipped[name] = error.message
        } catch {
            skipped[name] = error.localizedDescription
        }
    }
    return (tidied, skipped)
}

/// Rewrites `url` without its padding. Returns nil when there was too little to be worth it.
func tidyMovie(_ url: URL) throws -> TidyResult? {
    let source = try Data(contentsOf: url, options: .alwaysMapped)
    let plan = try TidyPlan(source)
    let saved = source.count - plan.newSize
    // Rewriting a file for a few kilobytes is not worth the disk work.
    guard saved > 1_000_000 || saved * 100 > source.count else { return nil }

    // Room for the tidy copy, with a gigabyte to spare, before the original goes.
    let free = (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage ?? 0
    guard free > Int64(plan.newSize) + 1_000_000_000 else { throw FinishError("not enough free space to tidy") }

    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tidy")
    try? FileManager.default.removeItem(at: temp)
    do {
        try plan.write(from: source, to: temp)
        // Read the new file back as a stranger would, and check every chunk against the original.
        let written = try Data(contentsOf: temp, options: .alwaysMapped)
        guard written.count == plan.newSize else { throw FinishError("the tidy copy came out the wrong size") }
        let check = try TidyPlan(written)
        guard check.tableOrder.count == plan.tableOrder.count else { throw FinishError("the tidy copy lost chunks") }
        for (old, new) in zip(plan.tableOrder, check.tableOrder) {
            guard old.size == new.size,
                  source[old.offset..<old.offset + old.size] == written[new.offset..<new.offset + new.size]
            else { throw FinishError("the tidy copy did not match the original") }
        }
        // Same dates and permissions as the original, so nothing else notices the swap.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var keep: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.creationDate, .modificationDate, .posixPermissions] { keep[key] = attributes[key] }
        try FileManager.default.setAttributes(keep, ofItemAtPath: temp.path)
        guard rename(temp.path, url.path) == 0 else { throw FinishError("could not put the tidy copy in place") }
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
    return TidyResult(before: source.count, after: plan.newSize)
}

/// Where every chunk is now, and where it goes.
private struct TidyPlan {
    struct Chunk {
        let offset: Int
        let size: Int
    }

    /// Every chunk of every track, in file order.
    let chunks: [Chunk]
    /// The same chunks in the order the movie's tables list them, track by track.
    let tableOrder: [Chunk]
    /// The file's top-level boxes, kept as they are, with the new mdat in place of the first one.
    private let boxes: [Box]
    /// The chunk tables to repoint: where each entry sits in the file, its width, and its chunk.
    private let entries: [(at: Int, wide: Bool, chunk: Int)]
    private let payloadStart: Int
    private let payloadSize: Int
    private let mdatHeader: Int
    let newSize: Int

    private struct Box {
        let type: String
        let start: Int
        let size: Int
        let header: Int
    }

    init(_ data: Data) throws {
        let top = try Self.children(of: data, from: 0, to: data.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw FinishError("no moov box") }
        guard top.contains(where: { $0.type == "mdat" }) else { throw FinishError("no mdat box") }
        // A movie still in fragments (a take cut short) keeps samples outside the chunk tables.
        guard !top.contains(where: { $0.type == "moof" }) else { throw FinishError("the movie is still in fragments") }
        let moovKids = try Self.children(of: data, from: moov.start + moov.header, to: moov.start + moov.size)
        guard !moovKids.contains(where: { $0.type == "mvex" }) else { throw FinishError("the movie is still in fragments") }

        var found: [(chunk: Chunk, entryAt: Int, wide: Bool)] = []
        for trak in moovKids where trak.type == "trak" {
            guard let mdia = try Self.child("mdia", in: trak, of: data),
                  let minf = try Self.child("minf", in: mdia, of: data),
                  let stbl = try Self.child("stbl", in: minf, of: data)
            else { throw FinishError("a track has no sample table") }
            if let dinf = try Self.child("dinf", in: minf, of: data), let dref = try Self.child("dref", in: dinf, of: data) {
                // Every data reference must say "in this file".
                let count = Int(data.u32(dref.start + dref.header + 4))
                var at = dref.start + dref.header + 8
                for _ in 0..<count {
                    let size = Int(data.u32(at))
                    guard size >= 12, at + size <= dref.start + dref.size, data.u32(at + 8) & 1 == 1 else {
                        throw FinishError("a track keeps its samples in another file")
                    }
                    at += size
                }
            }
            let kids = try Self.children(of: data, from: stbl.start + stbl.header, to: stbl.start + stbl.size)
            guard !kids.contains(where: { $0.type == "stz2" }) else { throw FinishError("compact sample sizes are not handled") }
            guard let stsc = kids.first(where: { $0.type == "stsc" }), let stsz = kids.first(where: { $0.type == "stsz" }) else {
                throw FinishError("a track has no chunk map")
            }
            let co64 = kids.first(where: { $0.type == "co64" })
            guard let stco = co64 ?? kids.first(where: { $0.type == "stco" }) else { throw FinishError("a track has no chunk offsets") }
            let wide = co64 != nil

            // Sample sizes. A single size for every sample is how QuickTime describes some sound
            // formats, where a "sample" is not a packet; only a full table is trusted.
            let sizeBase = stsz.start + stsz.header + 4
            guard data.u32(sizeBase) == 0 else { throw FinishError("a track gives one size for every sample") }
            let sampleCount = Int(data.u32(sizeBase + 4))
            guard sizeBase + 8 + sampleCount * 4 <= stsz.start + stsz.size else { throw FinishError("the sample size table is cut short") }

            let chunkCount = Int(data.u32(stco.start + stco.header + 4))
            let width = wide ? 8 : 4
            let offsetBase = stco.start + stco.header + 8
            guard offsetBase + chunkCount * width <= stco.start + stco.size else { throw FinishError("the chunk offset table is cut short") }

            // Samples in each chunk, from the runs in stsc.
            let runCount = Int(data.u32(stsc.start + stsc.header + 4))
            let runBase = stsc.start + stsc.header + 8
            guard runBase + runCount * 12 <= stsc.start + stsc.size else { throw FinishError("the chunk map is cut short") }
            var perChunk = [Int](repeating: 0, count: chunkCount)
            for r in 0..<runCount {
                let first = Int(data.u32(runBase + r * 12)) - 1
                let samples = Int(data.u32(runBase + r * 12 + 4))
                let end = r + 1 < runCount ? Int(data.u32(runBase + (r + 1) * 12)) - 1 : chunkCount
                guard first >= 0, first <= end, end <= chunkCount else { throw FinishError("the chunk map is out of order") }
                for c in first..<end { perChunk[c] = samples }
            }
            guard perChunk.reduce(0, +) == sampleCount else { throw FinishError("the chunk map and the sample count disagree") }

            var sample = 0
            for c in 0..<chunkCount {
                let at = offsetBase + c * width
                let offset = wide ? Int(data.u64(at)) : Int(data.u32(at))
                var size = 0
                for _ in 0..<perChunk[c] {
                    size += Int(data.u32(sizeBase + 8 + sample * 4))
                    sample += 1
                }
                found.append((Chunk(offset: offset, size: size), at, wide))
            }
        }
        guard !found.isEmpty else { throw FinishError("the movie has no chunks") }

        // Every chunk must sit wholly inside an mdat, and no two may overlap.
        let mdats = top.filter { $0.type == "mdat" }
        found.sort { $0.chunk.offset < $1.chunk.offset }
        var previousEnd = 0
        for item in found {
            let c = item.chunk
            guard c.size >= 0, c.offset >= previousEnd,
                  mdats.contains(where: { c.offset >= $0.start + $0.header && c.offset + c.size <= $0.start + $0.size })
            else { throw FinishError("the chunks overlap or sit outside the media data") }
            previousEnd = c.offset + c.size
        }

        // Chunks go into the new mdat in their old order, so each keeps its place relative to the rest.
        let ordered = found.map(\.chunk)
        let payload = ordered.reduce(0) { $0 + $1.size }
        let header = payload + 8 > Int(UInt32.max) ? 16 : 8
        // Everything but padding stays: free and skip boxes go, and every mdat becomes one.
        let firstMdat = top.firstIndex { $0.type == "mdat" }!
        let kept = top.enumerated().filter { i, box in
            box.type != "free" && box.type != "skip" && (box.type != "mdat" || i == firstMdat)
        }.map(\.element)
        var position = 0
        var start = 0
        for box in kept {
            if box.type == "mdat" { start = position + header; position = start + payload } else { position += box.size }
        }
        // Chunk offsets are absolute, so the moov needs no change but these, wherever it sits.
        var newOffset = start
        var placed: [Int] = []
        for c in ordered { placed.append(newOffset); newOffset += c.size }
        for (i, item) in found.enumerated() where !item.wide {
            guard placed[i] <= Int(UInt32.max) else { throw FinishError("a chunk would move past what its table can point to") }
        }

        chunks = ordered
        tableOrder = found.sorted { $0.entryAt < $1.entryAt }.map(\.chunk)
        boxes = kept
        entries = found.enumerated().map { i, item in (at: item.entryAt, wide: item.wide, chunk: i) }
        payloadStart = start
        payloadSize = payload
        mdatHeader = header
        newSize = position
        self.placed = placed
    }

    private let placed: [Int]

    func write(from data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw FinishError("could not make the tidy copy") }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var buffer = Data()
        buffer.reserveCapacity(8 << 20)
        func flush() throws {
            try out.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        // Where each table entry falls, so the moov can be patched as it is copied.
        var patches: [Int: (wide: Bool, value: Int)] = [:]
        for e in entries { patches[e.at] = (e.wide, placed[e.chunk]) }

        for box in boxes {
            if box.type == "mdat" {
                if mdatHeader == 16 {
                    buffer.appendU32(1); buffer.append(contentsOf: Array("mdat".utf8)); buffer.appendU64(UInt64(16 + payloadSize))
                } else {
                    buffer.appendU32(UInt32(8 + payloadSize)); buffer.append(contentsOf: Array("mdat".utf8))
                }
                for c in chunks {
                    buffer.append(data[c.offset..<c.offset + c.size])
                    if buffer.count >= 8 << 20 { try flush() }
                }
            } else {
                var copy = Data(data[box.start..<box.start + box.size])
                for (at, patch) in patches where at >= box.start && at < box.start + box.size {
                    let i = at - box.start
                    if patch.wide { copy.setU64(i, UInt64(patch.value)) } else { copy.setU32(i, UInt32(patch.value)) }
                }
                buffer.append(copy)
            }
            if buffer.count >= 8 << 20 { try flush() }
        }
        try flush()
        // On the disk itself, not just in the Mac's write cache, before the original is replaced.
        if fcntl(out.fileDescriptor, F_FULLFSYNC) == -1 { try out.synchronize() }
    }

    private static func child(_ type: String, in box: Box, of data: Data) throws -> Box? {
        try children(of: data, from: box.start + box.header, to: box.start + box.size).first { $0.type == type }
    }

    private static func children(of data: Data, from: Int, to end: Int) throws -> [Box] {
        var boxes: [Box] = []
        var at = from
        while at + 8 <= end {
            var size = Int(data.u32(at))
            let type = String(decoding: data[at + 4..<at + 8], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard at + 16 <= end else { throw FinishError("a box header is cut short") }
                size = Int(data.u64(at + 8)); header = 16
            } else if size == 0 {
                size = end - at
            }
            guard size >= header, at + size <= end else { throw FinishError("a box runs past its parent") }
            boxes.append(Box(type: type, start: at, size: size, header: header))
            at += size
        }
        // QuickTime allows a 4-byte terminator of zeros at the end of a container.
        guard end - at == 0 || (end - at == 4 && data.u32(at) == 0) else { throw FinishError("stray bytes after the last box") }
        return boxes
    }
}

// MARK: - Big-endian helpers

private extension Data {
    func u32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) << 32 | UInt64(u32(at + 4)) }

    mutating func appendU32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    mutating func appendU64(_ v: UInt64) { appendU32(UInt32(v >> 32)); appendU32(UInt32(v & 0xffff_ffff)) }

    mutating func setU32(_ at: Int, _ v: UInt32) {
        let i = startIndex + at
        self[i] = UInt8(v >> 24); self[i + 1] = UInt8(v >> 16 & 0xff); self[i + 2] = UInt8(v >> 8 & 0xff); self[i + 3] = UInt8(v & 0xff)
    }

    mutating func setU64(_ at: Int, _ v: UInt64) { setU32(at, UInt32(v >> 32)); setU32(at + 4, UInt32(v & 0xffff_ffff)) }
}
