import Foundation

// ava-finish <recording folder> [--no-transcribe] [--no-chapters] [--model <path to ggml model>]
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

let usage = "usage: ava-finish <recording folder> [--no-transcribe] [--no-chapters] [--model <path>]"
var folderArg: String?
var transcribeWanted = true
var chaptersWanted = true
var modelOverride: String?
var argIndex = 1
let argv = CommandLine.arguments
while argIndex < argv.count {
    let arg = argv[argIndex]
    switch arg {
    case "--no-transcribe": transcribeWanted = false
    case "--no-chapters": chaptersWanted = false
    case "--model":
        argIndex += 1
        guard argIndex < argv.count else { fail(usage) }
        modelOverride = argv[argIndex]
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
let totalSteps = (transcribeWanted ? 6 : 4) - (chaptersWanted ? 0 : 1)
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
        .appendingPathComponent("ava-finish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    workDir = work

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
    if let screen16k {
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

    var syncJSON = "{\"screenOffsetSec\":\(jsonNumber(sync.offset, places: 4)),\"method\":\(jsonString(sync.method)),\"confidence\":\(jsonNumber(sync.confidence))"
    if !extraCameras.isEmpty {
        let items = extraCameras.map {
            "{\"file\":\(jsonString($0.file)),\"offsetSec\":\(jsonNumber($0.sync.offset, places: 4)),\"method\":\(jsonString($0.sync.method)),\"confidence\":\(jsonNumber($0.sync.confidence))}"
        }
        syncJSON += ",\"cameras\":[\(items.joined(separator: ","))]"
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
    let events = readEvents(file("events.jsonl"))
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

    // 6. Report
    step("Writing the report")
    var title = events?.title ?? folder.lastPathComponent
    if events?.title == nil, folder.lastPathComponent.hasPrefix("recording-") {
        title = "\(folder.deletingLastPathComponent().lastPathComponent), \(folder.lastPathComponent)"
    }
    let report = buildReport(ReportInput(
        folder: folder, title: title, wall: events?.wall,
        cameraDuration: cameraDuration, screenDuration: screenDuration, screenNote: screenNote,
        sync: sync, extraCameras: extraCameras, transcript: transcript, retakes: retakes,
        chapters: chapters, chapterSource: chapterSource, candidateChapters: candidates, chaptersWanted: chaptersWanted,
        events: events))
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
