import Foundation

// vidlark-finish <recording folder> [--no-transcribe] [--no-chapters] [--no-video] [--model <path to ggml model>]
// stdout carries only progress for the app: "STEP n/total ...", then "DONE <report.md>" or "FAIL <reason>".

setvbuf(stdout, nil, _IOLBF, 0)

var workDir: URL?

func finish(_ code: Int32) -> Never {
    if let workDir { try? FileManager.default.removeItem(at: workDir) }
    exit(code)
}

func fail(_ reason: String) -> Never {
    print("FAIL \(noEmDash(reason))")
    finish(1)
}

let usage = "usage: vidlark-finish <recording folder> [--no-transcribe] [--no-chapters] [--no-video] [--model <path>]"
var folderArg: String?
var transcribeWanted = true
var chaptersWanted = true
var videoAllowed = true
var modelOverride: String?
var argIndex = 1
let argv = CommandLine.arguments
while argIndex < argv.count {
    let arg = argv[argIndex]
    switch arg {
    case "--no-transcribe": transcribeWanted = false
    case "--no-chapters": chaptersWanted = false
    case "--no-video": videoAllowed = false
    case "--model":
        argIndex += 1
        guard argIndex < argv.count else { fail(usage) }
        modelOverride = argv[argIndex]
    case "--tidy":
        // vidlark-finish --tidy <movie>: takes the padding out of one movie and says what it saved.
        argIndex += 1
        guard argIndex < argv.count else { fail(usage) }
        do {
            let result = try tidyMovie(URL(fileURLWithPath: argv[argIndex]))
            print(result.map { "TIDY \($0.before) \($0.after)" } ?? "TIDY nothing to take out")
            exit(0)
        } catch let error as FinishError {
            fail(error.message)
        } catch {
            fail(error.localizedDescription)
        }
    case "-h", "--help":
        FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
        exit(0)
    default:
        if arg.hasPrefix("-") || folderArg != nil { fail(usage) }
        folderArg = arg
    }
    argIndex += 1
}
guard let folderArg else { fail(usage) }

let folder = URL(fileURLWithPath: folderArg).standardizedFileURL
// video.mp4 is made whenever there is a screen to switch to, or another mic was picked for its sound.
let earlyEvents = readEvents(folder.appendingPathComponent("events.jsonl"))
let pickedMic = earlyEvents?.videoMic.flatMap { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) ? $0 : nil }
let hasScreen = FileManager.default.fileExists(atPath: folder.appendingPathComponent("screen.mov").path)
let videoWanted = videoAllowed && (hasScreen || pickedMic != nil)
let totalSteps = (transcribeWanted ? 6 : 4) - (chaptersWanted ? 0 : 1) + (videoWanted ? 1 : 0)
var stepNumber = 0
func step(_ words: String) {
    stepNumber += 1
    print("STEP \(stepNumber)/\(totalSteps) \(words)")
}

func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

do {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
        throw FinishError("folder not found: \(folder.path)")
    }
    let cameraPath = file("camera.mov").path
    let screenPath = file("screen.mov").path
    guard FileManager.default.fileExists(atPath: cameraPath) else {
        throw FinishError("camera.mov not found in \(folder.path)")
    }
    let ffmpeg = try Tools.require("ffmpeg")
    let ffprobe = try Tools.require("ffprobe")
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("vidlark-finish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    workDir = work

    let events = readEvents(file("events.jsonl"))

    // Before anything reads them: the camera movies without their padding (see Tidy.swift).
    let tidy = tidyCameraMovies(in: folder)
    for (name, why) in tidy.skipped.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write("\(name) left as it was: \(why)\n".data(using: .utf8)!)
    }

    // 1. Audio
    step("Taking the sound out of the videos")
    let camera: MediaInfo
    do { camera = try probeMedia(ffprobe, cameraPath) } catch let error as FinishError {
        throw FinishError("camera.mov could not be read: \(error.message)")
    }
    guard camera.hasAudio else { throw FinishError("camera.mov has no sound track, so there is nothing to sync or transcribe") }
    let camera16k = work.appendingPathComponent("camera16k.wav")
    do {
        try extractAudio(ffmpeg: ffmpeg, input: cameraPath,
                         outputs: [(file("mic.wav").path, 48000), (camera16k.path, 16000)])
    } catch let error as FinishError {
        throw FinishError("could not take the sound out of camera.mov: \(error.message)")
    }
    let cameraWavInfo = try readWavInfo(try Data(contentsOf: camera16k, options: .alwaysMapped))
    let cameraDuration = camera.duration ?? cameraWavInfo.duration

    var screenDuration: Double?
    var screenNote: String?
    var screenProblem = "screen.mov was not found"
    var screen16k: URL?
    if !FileManager.default.fileExists(atPath: screenPath) {
        screenNote = "not found"
        if events?.cameraFirst == true {
            screenNote = "none, the screen was not shared in this take"
            screenProblem = "the screen was not shared in this take"
        }
    } else {
        do {
            let screen = try probeMedia(ffprobe, screenPath)
            screenDuration = screen.duration
            if screen.hasAudio {
                let url = work.appendingPathComponent("screen16k.wav")
                try extractAudio(ffmpeg: ffmpeg, input: screenPath, outputs: [(url.path, 16000)], maxSeconds: 130)
                screen16k = url
            } else {
                screenNote = "\(clock(screen.duration ?? 0)), with no sound track"
                screenProblem = "screen.mov has no sound track"
            }
        } catch let error as FinishError {
            screenNote = "could not be read (\(error.message))"
            screenProblem = "screen.mov could not be read"
        }
    }

    // 2. Sync
    step("Lining up the camera and the screen")
    var sync = SyncResult(offset: 0, method: "none", confidence: 0, note: screenProblem)
    if let screen16k, let shared = events?.screenShared, shared > 3 {
        // Shared in the middle of the take: match the screen against the camera's sound from just
        // before the share, then count back to the start of camera.mov.
        let from = max(0, shared - 2.5)
        let part = work.appendingPathComponent("camera16k-shared.wav")
        do {
            try extractAudio(ffmpeg: ffmpeg, input: cameraPath, outputs: [(part.path, 16000)], startSeconds: from, maxSeconds: 130)
            let found = try measureSync(cameraWav: part, screenWav: screen16k, maxLagSeconds: 5)
            sync = SyncResult(offset: found.method == "audio" ? found.offset + from : shared, method: found.method,
                              confidence: found.confidence, note: found.note)
        } catch {
            sync = SyncResult(offset: shared, method: "none", confidence: 0, note: "the screen sound could not be read")
        }
    } else if let screen16k {
        sync = (try? measureSync(cameraWav: camera16k, screenWav: screen16k))
            ?? SyncResult(offset: 0, method: "none", confidence: 0, note: "the screen sound could not be read")
    }

    // Extra cameras carry the same mic, so each lines up with camera.mov by sound.
    var extraCameras: [ExtraCameraSync] = []
    for n in 2...9 {
        let name = "camera-\(n).mov"
        let path = file(name).path
        guard FileManager.default.fileExists(atPath: path) else { continue }
        var entry = ExtraCameraSync(file: name, duration: nil,
                                    sync: SyncResult(offset: 0, method: "none", confidence: 0, note: "\(name) could not be read"))
        if let info = try? probeMedia(ffprobe, path) {
            entry.duration = info.duration
            if !info.hasAudio {
                entry.sync = SyncResult(offset: 0, method: "none", confidence: 0, note: "\(name) has no sound track")
            } else {
                let wav = work.appendingPathComponent("camera\(n)-16k.wav")
                do {
                    try extractAudio(ffmpeg: ffmpeg, input: path, outputs: [(wav.path, 16000)], maxSeconds: 130)
                    entry.sync = (try? measureSync(cameraWav: camera16k, screenWav: wav))
                        ?? SyncResult(offset: 0, method: "none", confidence: 0, note: "the sound in \(name) could not be read")
                } catch {
                    entry.sync = SyncResult(offset: 0, method: "none", confidence: 0, note: "the sound in \(name) could not be read")
                }
            }
        }
        extraCameras.append(entry)
    }

    // Extra mics: each lines up with camera.mov by sound when its sound matches the main mic's well,
    // and otherwise (a phone far from the main mic, a mic muted most of the take) by the Mac's clock,
    // from when its file began.
    var extraMics: [ExtraMicSync] = []
    for n in 2...9 {
        let name = "mic-\(n).m4a"
        let path = file(name).path
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let byClock = events?.micStarts[name].map {
            SyncResult(offset: $0, method: "clock", confidence: 0, note: "its sound did not match the main mic's closely enough, so it is lined up by the Mac's clock")
        }
        var entry = ExtraMicSync(file: name, name: events?.micNames[name], duration: nil,
                                 sync: byClock ?? SyncResult(offset: 0, method: "none", confidence: 0, note: "\(name) could not be read"))
        if let info = try? probeMedia(ffprobe, path) {
            entry.duration = info.duration
            let wav = work.appendingPathComponent("mic\(n)-16k.wav")
            do {
                try extractAudio(ffmpeg: ffmpeg, input: path, outputs: [(wav.path, 16000)], maxSeconds: 130)
                if let found = try? measureSync(cameraWav: camera16k, screenWav: wav), found.method == "audio",
                   found.confidence >= 0.6 || byClock == nil {
                    entry.sync = found
                }
            } catch {}
        }
        extraMics.append(entry)
    }
    // A mic lined up by sound shows how far the clock's word is from the truth on this Mac (the
    // camera's first frame is noted a moment off). That correction goes to the ones lined up by clock.
    let gaps = extraMics.compactMap { mic -> Double? in
        guard mic.sync.method == "audio", mic.sync.confidence >= 0.8, let at = events?.micStarts[mic.file] else { return nil }
        return mic.sync.offset - at
    }.sorted()
    if !gaps.isEmpty, abs(gaps[gaps.count / 2]) < 0.5 {
        let correction = gaps[gaps.count / 2]
        for i in extraMics.indices where extraMics[i].sync.method == "clock" {
            let s = extraMics[i].sync
            extraMics[i].sync = SyncResult(offset: s.offset + correction, method: s.method, confidence: s.confidence, note: s.note)
        }
    }

    var syncJSON = "{\"screenOffsetSec\":\(jsonNumber(sync.offset, places: 4)),\"method\":\(jsonString(sync.method)),\"confidence\":\(jsonNumber(sync.confidence))"
    if !extraCameras.isEmpty {
        let items = extraCameras.map {
            "{\"file\":\(jsonString($0.file)),\"offsetSec\":\(jsonNumber($0.sync.offset, places: 4)),\"method\":\(jsonString($0.sync.method)),\"confidence\":\(jsonNumber($0.sync.confidence))}"
        }
        syncJSON += ",\"cameras\":[\(items.joined(separator: ","))]"
    }
    if !extraMics.isEmpty {
        let items = extraMics.map {
            "{\"file\":\(jsonString($0.file)),\"offsetSec\":\(jsonNumber($0.sync.offset, places: 4)),\"method\":\(jsonString($0.sync.method)),\"confidence\":\(jsonNumber($0.sync.confidence))}"
        }
        syncJSON += ",\"mics\":[\(items.joined(separator: ","))]"
    }
    try writeText(syncJSON + "}\n", to: file("sync.json"))

    // 3 and 4. Transcript and retakes
    var transcript = TranscriptOutcome.skipped
    var retakes: [Retake]?
    if transcribeWanted {
        step("Writing the transcript")
        try? FileManager.default.removeItem(at: file("words.json"))
        try? FileManager.default.removeItem(at: file("retakes.json"))
        var words: [Word]?
        let model = findModel(override: modelOverride)
        if let whisper = Tools.find("whisper-cli"), let modelPath = model.path {
            let started = Date()
            do {
                let result = try transcribe(whisper: whisper, model: modelPath, wav: camera16k, workDir: work)
                try writeText(wordsJSON(result), to: file("words.json"))
                transcript = .done(wordCount: result.count, seconds: Date().timeIntervalSince(started))
                words = result
            } catch let error as FinishError {
                transcript = .failed(error.message)
            }
        } else if Tools.find("whisper-cli") == nil {
            transcript = .failed("whisper-cli not found (looked in \(Tools.searchDirs.joined(separator: ", ")) and PATH)")
        } else {
            transcript = .failed("the whisper model was not found, looked for \(model.searched.joined(separator: ", "))")
        }

        step("Looking for retakes")
        if let words {
            let found = findRetakes(words)
            try writeText(retakesJSON(found), to: file("retakes.json"))
            retakes = found
        }
    }

    // 5. Chapters
    var chapters: [Chapter] = []
    var chapterSource = "prompter sections"
    var candidates = 0
    if chaptersWanted { step("Making chapters") }
    if chaptersWanted, let events {
        let raw = rawChapters(events)
        chapterSource = raw.source
        candidates = raw.chapters.count
        chapters = youTubeChapters(raw.chapters, end: cameraDuration)
    }
    if chaptersWanted { try writeText(chaptersText(chapters), to: file("chapters.txt")) }

    // 6. The finished video, following each click of Me or Screen
    var composed: ComposeResult?
    var composeProblem: String?
    // The sound of the video: the mic picked before the take, when it could be lined up.
    var videoSound: (url: URL, offset: Double)?
    var videoSoundNote: String?
    if let pickedMic {
        if let mic = extraMics.first(where: { $0.file == pickedMic }), mic.sync.method != "none" {
            videoSound = (file(pickedMic), mic.sync.offset)
        } else {
            videoSoundNote = "\(pickedMic) could not be lined up with the camera, so the video has the main mic's sound"
        }
    }
    if videoWanted {
        step("Making the video")
        let offset = sync.offset, late = events?.cameraFirst == true
        let cameraURL = file("camera.mov"), screenURL = file("screen.mov"), out = file("video.mp4")
        let sound = videoSound
        do {
            if hasScreen {
                composed = try waitFor { try await composeVideo(camera: cameraURL, screen: screenURL, screenOffset: offset, sharedLate: late, sound: sound, out: out) }
            } else if let sound {
                composed = try waitFor { try await cameraWithSound(camera: cameraURL, sound: sound, out: out) }
            }
        } catch let error as FinishError {
            composeProblem = error.message
        } catch {
            composeProblem = error.localizedDescription
        }
    }

    // 7. Report
    step("Writing the report")
    var title = events?.title ?? folder.lastPathComponent
    if events?.title == nil, folder.lastPathComponent.hasPrefix("recording-") {
        title = "\(folder.deletingLastPathComponent().lastPathComponent), \(folder.lastPathComponent)"
    }
    let report = buildReport(ReportInput(
        folder: folder, title: title, wall: events?.wall,
        cameraDuration: cameraDuration, screenDuration: screenDuration, screenNote: screenNote,
        sync: sync, extraCameras: extraCameras, extraMics: extraMics, videoMic: videoSound == nil ? nil : pickedMic,
        videoSoundNote: videoSoundNote, transcript: transcript, retakes: retakes,
        chapters: chapters, chapterSource: chapterSource, candidateChapters: candidates, chaptersWanted: chaptersWanted,
        events: events, video: composed, videoProblem: composeProblem, videoWanted: videoWanted))
    try writeText(report, to: file("report.md"))

    if case .failed(let reason) = transcript {
        fail("transcript failed: \(reason). The other files and report.md were written.")
    }
    print("DONE \(file("report.md").path)")
    finish(0)
} catch let error as FinishError {
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}
