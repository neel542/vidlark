import Foundation

enum TranscriptOutcome {
    case done(wordCount: Int, seconds: Double)
    case skipped
    case failed(String)
}

struct ReportInput {
    var folder: URL
    var title: String
    var wall: String?
    var cameraDuration: Double?
    var screenDuration: Double?
    var screenNote: String?
    var sync: SyncResult
    var extraCameras: [ExtraCameraSync]
    var transcript: TranscriptOutcome
    var retakes: [Retake]?
    var chapters: [Chapter]
    var chapterSource: String
    var candidateChapters: Int
    var chaptersWanted = true
    var events: RecordingEvents?
}

private func length(_ seconds: Double?) -> String {
    guard let seconds else { return "unknown" }
    return "\(clock(seconds)) (\(String(format: "%.1f", seconds)) seconds)"
}

private func friendlyDate(_ wall: String) -> String {
    let parser = ISO8601DateFormatter()
    var date = parser.date(from: wall)
    if date == nil {
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = parser.date(from: wall)
    }
    guard let date else { return wall }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
    return formatter.string(from: date)
}

private func fileSize(_ bytes: Int) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
    return "\(bytes) bytes"
}

func buildReport(_ r: ReportInput) -> String {
    var out: [String] = []
    out.append("# \(r.title)")
    out.append("")
    if let wall = r.wall { out.append("Recorded \(friendlyDate(wall)).") }
    out.append("Folder: `\(r.folder.path)`")
    if let events = r.events {
        if events.stopTime == nil {
            out.append("")
            out.append("The events log has no stop line, so the app probably closed or crashed during this take. Everything saved up to that moment is used.")
        }
        if events.skippedLines > 0 {
            out.append("")
            out.append("\(events.skippedLines) damaged line\(events.skippedLines == 1 ? " was" : "s were") skipped in events.jsonl.")
        }
    } else {
        out.append("")
        out.append("There is no readable events.jsonl, so there are no chapters.")
    }

    out.append("")
    out.append("## Length")
    out.append("")
    out.append("- Camera (camera.mov): \(length(r.cameraDuration))")
    if let note = r.screenNote {
        out.append("- Screen (screen.mov): \(note)")
    } else {
        out.append("- Screen (screen.mov): \(length(r.screenDuration))")
    }
    for extra in r.extraCameras {
        out.append("- Extra camera (\(extra.file)): \(length(extra.duration))")
    }

    out.append("")
    out.append("## Sync")
    out.append("")
    if r.sync.method == "audio" {
        let offset = r.sync.offset
        let amount = String(format: "%.3f", abs(offset))
        if abs(offset) < 0.0005 {
            out.append("The camera and the screen started at the same moment.")
        } else if offset < 0 {
            out.append("The screen recording started \(amount) seconds before the camera.")
        } else {
            out.append("The screen recording started \(amount) seconds after the camera.")
        }
        out.append("")
        out.append("- Offset: \(jsonNumber(offset)) seconds (camera time = screen time + offset), saved in sync.json")
        let c = r.sync.confidence
        let verdict = c >= 0.8 ? "high" : c >= 0.5 ? "medium, worth a quick check by eye" : "low, check the sync by eye before editing"
        out.append("- Confidence: \(String(format: "%.2f", c)) (\(verdict))")
    } else {
        out.append("Not measured, because \(r.sync.note ?? "there is no screen sound to match"). sync.json says offset 0.")
    }
    for extra in r.extraCameras {
        out.append("")
        if extra.sync.method == "audio" {
            let c = extra.sync.confidence
            let verdict = c >= 0.8 ? "high" : c >= 0.5 ? "medium, worth a quick check by eye" : "low, check the sync by eye before editing"
            out.append("- \(extra.file): offset \(jsonNumber(extra.sync.offset)) seconds (camera time = \(extra.file) time + offset), "
                       + "confidence \(String(format: "%.2f", c)) (\(verdict)), saved in sync.json")
        } else {
            out.append("- \(extra.file): not measured, because \(extra.sync.note ?? "it has no sound to match"). sync.json says offset 0.")
        }
    }

    out.append("")
    out.append("## Transcript")
    out.append("")
    switch r.transcript {
    case .done(let count, let seconds):
        out.append("\(count) words, saved in words.json (transcribed in \(String(format: "%.0f", seconds)) seconds).")
    case .skipped:
        out.append("Skipped (run without `--no-transcribe` to make words.json and retakes.json).")
    case .failed(let reason):
        out.append("Failed: \(reason)")
    }

    out.append("")
    out.append("## Chapters")
    out.append("")
    if !r.chaptersWanted {
        out.append("Skipped (the take was recorded with the transcript and chapters box unticked).")
    } else if r.chapters.isEmpty {
        if r.candidateChapters == 0 {
            out.append("None: there were no \(r.chapterSource) to build chapters from. chapters.txt is empty.")
        } else {
            out.append("None: YouTube needs at least 3 chapters of 10 seconds or more, and the \(r.chapterSource) did not give that. chapters.txt is empty.")
        }
    } else {
        out.append("Made from the \(r.chapterSource). Paste this into the YouTube description:")
        out.append("")
        out.append("```")
        out.append(chaptersText(r.chapters).trimmingCharacters(in: .newlines))
        out.append("```")
    }

    out.append("")
    out.append("## Retakes")
    out.append("")
    if let retakes = r.retakes {
        if retakes.isEmpty {
            out.append("The word \"retake\" was not said.")
        } else {
            out.append("\"Retake\" was said \(retakes.count) time\(retakes.count == 1 ? "" : "s"). Cut back to before each one:")
            out.append("")
            for retake in retakes {
                out.append("- \(clock(retake.t)) (\(String(format: "%.1f", retake.t)) s): \(retake.context)")
            }
        }
    } else {
        out.append("Not checked, because there is no transcript.")
    }

    out.append("")
    out.append("## Files")
    out.append("")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: r.folder.path)) ?? [])
        .filter { !$0.hasPrefix(".") && $0 != "report.md" }
        .sorted()
    for name in names {
        let path = r.folder.appendingPathComponent(name).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        out.append("- \(name) (\(fileSize(size)))")
    }
    out.append("- report.md (this file)")
    out.append("")
    return out.joined(separator: "\n")
}
