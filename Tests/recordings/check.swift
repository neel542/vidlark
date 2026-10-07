import Foundation

// Checks the Recordings page's file logic (TakeStore) against a fake library that run.sh builds.
// Never point it at /Users/Shared/Vidlark Recordings.

@main
struct RecordingsCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "ok    \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: check <fake library> <copy target>"); exit(2) }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let copies = URL(fileURLWithPath: args[2], isDirectory: true)
        guard root.path.hasPrefix("/Users/Shared/Vidlark Recordings") == false else { print("refusing the real library"); exit(2) }
        let fm = FileManager.default

        // Everything is old except the take that is "recording now".
        let old = Date().addingTimeInterval(-120)
        let live = root.appendingPathComponent("2026-10-04 Brand Registry/recording-1")
        for relative in fm.subpaths(atPath: root.path) ?? [] {
            let path = root.appendingPathComponent(relative).path
            try? fm.setAttributes([.modificationDate: path.hasPrefix(live.path) ? Date() : old], ofItemAtPath: path)
        }

        // Scan
        var (takes, cache) = await TakeStore.scan(root: root)
        print("found:", takes.map { "\($0.folder.deletingLastPathComponent().lastPathComponent)/\($0.folder.lastPathComponent)" })
        expect(takes.count == 5, "five takes (dot folders and folders without media are skipped)")
        expect(!takes.contains { $0.folder.path.contains(".models") }, ".models is ignored")
        expect(!takes.contains { $0.folder.lastPathComponent == "notes" }, "a folder with no video or events is not a take")
        expect(zip(takes, takes.dropFirst()).allSatisfy { $0.date >= $1.date }, "newest first")

        func take(_ video: String, _ name: String) -> TakeInfo? {
            takes.first { $0.folder.lastPathComponent == name && $0.folder.deletingLastPathComponent().lastPathComponent == video }
        }
        let fix1 = take("2026-10-01 Fix a listing", "recording-1")
        expect(fix1?.title == "Fix a suppressed listing", "title comes from the start line")
        expect(fix1?.number == 1, "take number from the folder")
        expect(fix1?.duration == 42.5, "length from the stop line")
        expect(fix1?.finished == true, "report.md means finished")
        expect(fix1?.warning == nil, "a whole take has no warning")
        expect(fix1?.writing == false, "an old take is not being written")
        let wall = ISO8601DateFormatter().date(from: "2026-10-01T09:30:00Z")
        expect(fix1?.date == wall, "date from the wall time")
        expect((fix1?.bytes ?? 0) > 0, "size on disk is counted")

        let fix2 = take("2026-10-01 Fix a listing", "recording-2")
        expect(fix2?.warning == "No camera file", "missing camera.mov is a warning")
        expect(fix2?.finished == false, "no report.md means not finished")
        expect(abs((fix2?.duration ?? 0) - 5) < 0.2, "a crashed take (no stop line) gets its length from the video: \(fix2?.duration ?? -1)")

        let brand = take("2026-10-04 Brand Registry", "recording-1")
        expect(brand?.writing == true, "a file changed just now means it is being recorded")
        let loose = takes.first { $0.folder.lastPathComponent == "2026-09-20 Loose take" }
        expect(loose?.title == "Loose take", "a take one level down is found, its title from the folder without the date")
        expect(loose?.number == nil, "a loose take has no number")

        // Thumbnail
        let thumbFile = fix1!.folder.appendingPathComponent("thumbnail.jpg")
        let image = await TakeStore.thumbnail(for: fix1!.folder)
        expect(image != nil && fm.fileExists(atPath: thumbFile.path), "thumbnail.jpg is made from the camera")
        expect(image.map { $0.width == 640 && $0.height == 360 } ?? false, "thumbnail is 640 px wide: \(image?.width ?? 0)x\(image?.height ?? 0)")
        let made = (try? fm.attributesOfItem(atPath: thumbFile.path)[.modificationDate]) as? Date
        let again = await TakeStore.thumbnail(for: fix1!.folder)
        let after = (try? fm.attributesOfItem(atPath: thumbFile.path)[.modificationDate]) as? Date
        expect(again != nil && made == after, "the saved thumbnail is reused, not made again")
        let screenOnly = await TakeStore.thumbnail(for: fix2!.folder)
        expect(screenOnly != nil, "with no camera file the screen gives the thumbnail")
        let none = await TakeStore.thumbnail(for: brand!.folder)
        expect(none == nil && !fm.fileExists(atPath: brand!.folder.appendingPathComponent("thumbnail.jpg").path),
               "no thumbnail is made while the take is being written")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: fix1!.folder.path)) ?? []).filter { $0.hasPrefix(".thumbnail-") }
        expect(leftovers.isEmpty, "no temporary thumbnail files are left")

        (takes, cache) = await TakeStore.scan(root: root, cache: cache)
        expect(take("2026-10-01 Fix a listing", "recording-1")?.writing == false, "writing the thumbnail does not make a take look busy")

        // Rename
        do {
            let moved = try TakeStore.rename(fix1!.folder, to: "Best take: v2")
            expect(moved.lastPathComponent == "Best take- v2", "folder gets the safe name: \(moved.lastPathComponent)")
            expect(moved.deletingLastPathComponent() == fix1!.folder.deletingLastPathComponent(), "it stays inside its video folder")
            expect(fm.fileExists(atPath: moved.appendingPathComponent("camera.mov").path), "files move with it")
        } catch { expect(false, "rename: \(error)") }
        do {
            let moved = try TakeStore.rename(fix2!.folder, to: "Best take: v2")
            expect(moved.lastPathComponent == "Best take- v2 (2)", "a second take with the same name is kept unique: \(moved.lastPathComponent)")
        } catch { expect(false, "second rename: \(error)") }
        do {
            try TakeStore.rename(brand!.folder, to: "Nope")
            expect(false, "renaming a take being written is refused")
        } catch { expect(true, "renaming a take being written is refused") }
        do {
            try TakeStore.rename(loose!.folder, to: "   ")
            expect(false, "an empty name is refused")
        } catch { expect(true, "an empty name is refused") }

        (takes, cache) = await TakeStore.scan(root: root, cache: cache)
        let renamed = take("2026-10-01 Fix a listing", "Best take- v2")
        expect(renamed?.title == "Best take: v2", "the card shows the exact name typed: \(renamed?.title ?? "nil")")
        expect(renamed?.renamed == true && renamed?.number == nil, "a renamed take has no number")
        expect(renamed?.videoTitle == "Fix a suppressed listing", "the video title is kept")
        expect(take("2026-10-01 Fix a listing", "Best take- v2 (2)")?.title == "Best take: v2", "the unique folder still shows the name")
        expect(fm.fileExists(atPath: renamed!.folder.appendingPathComponent("thumbnail.jpg").path), "the thumbnail moves with the take")

        do {
            let moved = try TakeStore.rename(renamed!.folder, to: "best take: v2")
            expect(moved.lastPathComponent == "best take- v2", "a capitals-only rename works: \(moved.lastPathComponent)")
        } catch { expect(false, "capitals-only rename: \(error)") }
        (takes, cache) = await TakeStore.scan(root: root, cache: cache)
        let lower = take("2026-10-01 Fix a listing", "best take- v2")
        expect(lower?.title == "best take: v2", "the capitals-only rename shows")

        // A take renamed in Finder: the folder name wins over a stale saved name.
        let finderName = lower!.folder.deletingLastPathComponent().appendingPathComponent("Renamed in Finder")
        try? fm.moveItem(at: lower!.folder, to: finderName)
        (takes, cache) = await TakeStore.scan(root: root, cache: cache)
        expect(take("2026-10-01 Fix a listing", "Renamed in Finder")?.title == "Renamed in Finder", "a Finder rename shows the folder name")

        // Library numbering still works after a rename: the next take does not reuse a name.
        var item: VideoItem? = VideoItem(title: "Fix a listing", script: "# Fix a listing\n- one", folder: finderName.deletingLastPathComponent().path)
        if let next = try? Library.newRecordingFolder(for: &item) {
            expect(next.lastPathComponent == "recording-1" || next.lastPathComponent == "recording-3", "a new take after renames gets a free name: \(next.lastPathComponent)")
            try? fm.removeItem(at: next)
        }

        // Save a copy
        let source = take("2026-10-01 Fix a listing", "Renamed in Finder")!
        do {
            let copy = try TakeStore.copy(source.folder, named: source.copyName, into: copies)
            let a = Set(try fm.contentsOfDirectory(atPath: source.folder.path))
            let b = Set(try fm.contentsOfDirectory(atPath: copy.path))
            expect(a == b, "the copy has every file")
            expect(copy.lastPathComponent == "2026-10-01 Renamed in Finder", "the copy is named with date and title: \(copy.lastPathComponent)")
            let second = try TakeStore.copy(source.folder, named: source.copyName, into: copies)
            expect(second.lastPathComponent == "2026-10-01 Renamed in Finder (2)", "a second copy does not overwrite the first")
        } catch { expect(false, "copy: \(error)") }
        do {
            _ = try TakeStore.copy(source.folder, named: "x", into: source.folder)
            expect(false, "copying a take into itself is refused")
        } catch { expect(true, "copying a take into itself is refused") }
        do {
            _ = try TakeStore.copy(brand!.folder, named: "x", into: copies)
            expect(false, "copying a take being written is refused")
        } catch { expect(true, "copying a take being written is refused") }

        // Move to the Trash, then put it back so the Trash is left as it was.
        do {
            try TakeStore.moveToTrash(brand!.folder)
            expect(false, "trashing a take being written is refused")
        } catch { expect(true, "trashing a take being written is refused") }
        let doomed = take("2026-10-01 Fix a listing", "Best take- v2 (2)")!
        do {
            let landed = try TakeStore.moveToTrash(doomed.folder)
            expect(!fm.fileExists(atPath: doomed.folder.path), "the take leaves the library")
            expect(landed?.path.contains("/.Trash/") == true, "it lands in the Trash: \(landed?.path ?? "nil")")
            if let landed {
                let back = copies.appendingPathComponent("restored-from-trash")
                try fm.moveItem(at: landed, to: back)
                expect(fm.fileExists(atPath: back.appendingPathComponent("screen.mov").path), "it comes back from the Trash whole")
            }
        } catch { expect(false, "trash: \(error)") }

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
