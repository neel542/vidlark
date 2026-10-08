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
    var extraMics: [ExtraMicSync] = []
    /// The extra mic file the video's sound comes from, if one was picked and could be used.
    var videoMic: String?
    var videoSoundNote: String?
    var transcript: TranscriptOutcome
    var retakes: [Retake]?
    var chapters: [Chapter]
    var chapterSource: String
    var candidateChapters: Int
    var chaptersWanted = true
    var events: RecordingEvents?
    var video: ComposeResult?
    var videoProblem: String?
    var videoWanted = false
    var framingWanted = true
    var framingProblem: String?
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
    } else if let shared = r.events?.screenShared {
        out.append("- Screen (screen.mov): \(length(r.screenDuration)), shared \(clock(shared)) into the take")
    } else {
        out.append("- Screen (screen.mov): \(length(r.screenDuration))")
    }
    for extra in r.extraCameras {
        out.append("- Extra camera (\(extra.file)): \(length(extra.duration))")
    }
    for mic in r.extraMics {
        out.append("- Extra mic (\(mic.file)\(mic.name.map { ", \($0)" } ?? "")): \(length(mic.duration))")
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
        let offset = r.sync.offset == 0 ? "0" : "\(jsonNumber(r.sync.offset)), the moment the screen was shared"
        out.append("Not measured, because \(r.sync.note ?? "there is no screen sound to match"). sync.json says offset \(offset).")
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

    if !r.extraMics.isEmpty {
        out.append("")
        out.append("## Microphones")
        out.append("")
        if let mic = r.videoMic {
            out.append("The video's sound is \(r.extraMics.first { $0.file == mic }?.name ?? mic) (\(mic)). Every mic's file is in the folder, so another can be used in editing.")
        } else {
            out.append("The video's sound is the main mic, from camera.mov. Every mic's file is in the folder, so another can be used in editing.")
        }
        if let note = r.videoSoundNote { out.append(""); out.append("Note: \(note).") }
        for mic in r.extraMics {
            out.append("")
            let who = mic.name.map { "\(mic.file) (\($0))" } ?? mic.file
            switch mic.sync.method {
            case "audio":
                let c = mic.sync.confidence
                let verdict = c >= 0.8 ? "high" : "medium, worth a quick listen"
                out.append("- \(who): lined up by sound, offset \(jsonNumber(mic.sync.offset)) seconds (camera time = mic time + offset), confidence \(String(format: "%.2f", c)) (\(verdict))")
            case "clock":
                out.append("- \(who): lined up by the Mac's clock, offset \(jsonNumber(mic.sync.offset)) seconds, because \(mic.sync.note ?? "its sound did not match"). Check the lip sync by eye.")
            default:
                out.append("- \(who): not lined up, because \(mic.sync.note ?? "it could not be read").")
            }
            let mutes = (r.events?.mutes ?? []).filter { $0.file == mic.file }
            for m in mutes {
                out.append("  - \(m.on ? "Muted" : "Unmuted") at \(clock(m.t)), \(m.byPhone ? "on the phone" : "from the Mac")\(m.on ? ": the file is silent until it was unmuted" : "")")
            }
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

    if let sounds = r.events?.sounds, !sounds.isEmpty {
        out.append("")
        out.append("## Mac sound")
        out.append("")
        out.append("The second sound track of screen.mov. Off means silence there.")
        out.append("")
        for change in sounds {
            out.append("- \(clock(change.t)) \(change.on ? "on, from \(change.from)" : "off")")
        }
    }

    out.append("")
    out.append("## Video")
    out.append("")
    let micWords = r.videoMic.map { file in r.extraMics.first { $0.file == file }?.name.map { "\($0) (\(file))" } ?? file }
    if let video = r.video, r.screenDuration == nil {
        out.append("video.mp4 is the finished video: \(clock(video.seconds)), \(video.width) by \(video.height). It is camera.mov's picture as it was, with the sound from \(micWords ?? "the main mic").")
    } else if let video = r.video {
        out.append("video.mp4 is the finished video: \(clock(video.seconds)), \(video.width) by \(video.height). It is what was on the screen, with her camera across the whole screen for Me\(micWords.map { ", and the sound from \($0)" } ?? "").")
        if let until = video.cameraUntil {
            out.append("")
            out.append("Until \(clock(until)), before the screen was shared, it is camera.mov.")
        }
        if let shows = r.events?.shows, !shows.isEmpty {
            out.append("")
            for change in shows {
                out.append("- \(clock(change.t)) \(change.screen ? "Screen" : "Me")")
            }
        }
        if let line = framingLine(r, video) {
            out.append("")
            out.append(line)
        }
    } else if let problem = r.videoProblem {
        out.append("Not made, because \(problem). camera.mov and screen.mov are whole, so the video can still be edited from them.")
    } else if r.videoWanted || r.screenDuration == nil {
        // Wanted but not made with no problem means a camera-only take whose picked mic could not be used.
        out.append("No screen in this take, so camera.mov is the video.")
    } else {
        out.append("Not made (finished with --no-video).")
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

/// One line on face framing: what it did where the video shows her camera across the frame.
private func framingLine(_ r: ReportInput, _ video: ComposeResult) -> String? {
    if let problem = r.framingProblem {
        return "Face framing was skipped (\(problem)), so where the video shows her camera across the frame it is cropped a little above the middle."
    }
    guard let framing = video.framing else {
        return r.framingWanted ? nil : "Face framing was off, so where the video shows her camera across the frame it is cropped a little above the middle."
    }
    guard framing.looksWithFace > 0 else {
        return "No face was found in the camera picture, so where the video shows her camera across the frame it is cropped a little above the middle."
    }
    let share = Int((Double(framing.looksWithFace) / Double(max(framing.looks, 1)) * 100).rounded())
    let moves = framing.glides == 0 ? "it held still throughout" : framing.glides == 1 ? "it glided once" : "it glided \(framing.glides) times"
    return "Face framing: where the video shows her camera across the frame (\(clock(framing.cameraSeconds)) in all), the picture follows her face like a camera operator; \(moves). Her face was found in \(share)% of the looks (faces.json)."
}
