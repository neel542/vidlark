import AVFoundation
import Foundation

// video.mp4: the finished video, made from camera.mov and screen.mov. During the take she clicks
// Me or Screen; here the video follows those clicks, fading between the two, so nothing has to be
// cut by hand. Both files stay as they are for anyone who wants to edit.

/// One click of Me or Screen, in camera time.
struct ShowChange {
    var t: Double
    var screen: Bool
}

struct ComposeResult {
    var seconds: Double
    var width: Int
    var height: Int
    /// When the video changes, in camera time: true is a change to the screen.
    var changes: [ShowChange]
}

/// How long a fade between Me and Screen lasts.
let fadeSeconds = 0.5

/// The changes the video makes. `wanted` is what was clicked (the first entry is the start); the
/// screen can only show while screen.mov has pictures, and two fades never overlap.
func plannedChanges(wanted: [ShowChange], screenFrom: Double, screenTo: Double, end: Double) -> (startsOnScreen: Bool, changes: [ShowChange]) {
    let clicks = wanted.sorted { $0.t < $1.t }
    func wants(_ t: Double) -> Bool { clicks.last { $0.t <= t + 0.0001 }?.screen ?? false }
    func shows(_ t: Double) -> Bool { wants(t) && t >= screenFrom - 0.0001 && t < screenTo - fadeSeconds }
    let moments = Set(clicks.map(\.t) + [screenFrom, screenTo - fadeSeconds]).filter { $0 > 0 && $0 < end }.sorted()
    let first = shows(0)
    var state = first
    var changes: [ShowChange] = []
    var free = 0.0
    for moment in moments {
        let next = shows(moment)
        guard next != state else { continue }
        // A fade starts only once the last one has finished.
        let at = max(moment, free)
        guard at + fadeSeconds <= end else { break }
        changes.append(ShowChange(t: at, screen: next))
        state = next
        free = at + fadeSeconds
    }
    return (first, changes)
}

func composeVideo(camera: URL, screen: URL, screenOffset: Double, clicks: [ShowChange], out: URL) async throws -> ComposeResult {
    let cameraAsset = AVURLAsset(url: camera)
    let screenAsset = AVURLAsset(url: screen)
    guard let cameraVideo = try await cameraAsset.loadTracks(withMediaType: .video).first else {
        throw FinishError("camera.mov has no picture")
    }
    guard let screenVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
        throw FinishError("screen.mov has no picture")
    }
    let cameraAudio = try await cameraAsset.loadTracks(withMediaType: .audio).first
    // The second sound track of screen.mov is the Mac's sound, when it was ticked. The first is the
    // mic again, which would echo, so it is left out.
    let screenAudio = try await screenAsset.loadTracks(withMediaType: .audio)
    let macSound = screenAudio.count > 1 ? screenAudio[1] : nil

    let end = try await cameraAsset.load(.duration)
    let composition = AVMutableComposition()

    func add(_ track: AVAssetTrack, _ type: AVMediaType, offset: Double) async throws -> AVMutableCompositionTrack? {
        let range = try await track.load(.timeRange)
        // camera time = file time + offset; nothing before the camera started, nothing after it stopped.
        let from = max(range.start.seconds, -offset)
        let to = min(range.end.seconds, end.seconds - offset)
        guard to > from + 0.05, let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let source = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        try target.insertTimeRange(source, of: track, at: CMTime(seconds: from + offset, preferredTimescale: 600))
        return target
    }

    guard let cameraTrack = try await add(cameraVideo, .video, offset: 0) else { throw FinishError("camera.mov has no picture") }
    let screenTrack = try await add(screenVideo, .video, offset: screenOffset)
    if let cameraAudio { _ = try await add(cameraAudio, .audio, offset: 0) }
    if let macSound { _ = try await add(macSound, .audio, offset: screenOffset) }

    // The canvas has the screen's shape, at most 1920 wide, so the screen fills it without bars.
    let screenSize = try await orientedSize(screenVideo)
    let scale = min(1, 1920 / max(screenSize.width, 1))
    let canvas = CGSize(width: CGFloat(Int(screenSize.width * scale) & ~1), height: CGFloat(Int(screenSize.height * scale) & ~1))

    // Where the screen has pictures, in camera time.
    let screenRange = try await screenVideo.load(.timeRange)
    let screenFrom = max(0, screenRange.start.seconds + screenOffset)
    let screenTo = min(end.seconds, screenRange.end.seconds + screenOffset)
    let plan = screenTrack == nil
        ? (startsOnScreen: false, changes: [])
        : plannedChanges(wanted: clicks, screenFrom: screenFrom, screenTo: screenTo, end: end.seconds)

    // The camera fills the canvas (cropped a little above centre, where faces are); the screen fits it.
    let cameraLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cameraTrack)
    cameraLayer.setTransform(try await fitting(cameraVideo, into: canvas, fill: true), at: .zero)
    cameraLayer.setOpacity(plan.startsOnScreen ? 0 : 1, at: .zero)
    var layers = [cameraLayer]
    if let screenTrack {
        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
        screenLayer.setTransform(try await fitting(screenVideo, into: canvas, fill: false), at: .zero)
        screenLayer.setOpacity(plan.startsOnScreen ? 1 : 0, at: .zero)
        // The screen sits on top. Fading in, the camera stays whole underneath until the fade ends;
        // fading out, the camera is back underneath first.
        for change in plan.changes {
            let start = CMTime(seconds: change.t, preferredTimescale: 600)
            let fade = CMTimeRange(start: start, duration: CMTime(seconds: fadeSeconds, preferredTimescale: 600))
            if change.screen {
                screenLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: fade)
                cameraLayer.setOpacity(0, at: fade.end)
            } else {
                cameraLayer.setOpacity(1, at: start)
                screenLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: fade)
            }
        }
        layers.insert(screenLayer, at: 0)
    }

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: end)
    instruction.layerInstructions = layers
    let video = AVMutableVideoComposition()
    video.renderSize = canvas
    video.frameDuration = CMTime(value: 1, timescale: 30)
    video.instructions = [instruction]

    try? FileManager.default.removeItem(at: out)
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
        throw FinishError("this Mac cannot export HEVC video")
    }
    export.videoComposition = video
    export.timeRange = CMTimeRange(start: .zero, duration: end)
    try await export.export(to: out, as: .mp4)
    return ComposeResult(seconds: end.seconds, width: Int(canvas.width), height: Int(canvas.height),
                         changes: (plan.startsOnScreen ? [ShowChange(t: 0, screen: true)] : [ShowChange(t: 0, screen: false)]) + plan.changes)
}

/// The picture's size the right way up.
private func orientedSize(_ track: AVAssetTrack) async throws -> CGSize {
    let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
    let box = CGRect(origin: .zero, size: natural).applying(transform)
    return CGSize(width: abs(box.width), height: abs(box.height))
}

/// Puts a track the right way up and scales it to cover (`fill`) or fit the canvas.
private func fitting(_ track: AVAssetTrack, into canvas: CGSize, fill: Bool) async throws -> CGAffineTransform {
    let (natural, preferred) = try await track.load(.naturalSize, .preferredTransform)
    let box = CGRect(origin: .zero, size: natural).applying(preferred)
    let upright = preferred.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
    let size = CGSize(width: abs(box.width), height: abs(box.height))
    let k = fill ? max(canvas.width / size.width, canvas.height / size.height)
                 : min(canvas.width / size.width, canvas.height / size.height)
    let width = size.width * k, height = size.height * k
    let x = (canvas.width - width) / 2
    // Filling, keep a little more of the top than the bottom: faces sit in the upper half.
    let y = fill ? (canvas.height - height) * 0.4 : (canvas.height - height) / 2
    return upright.concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(CGAffineTransform(translationX: x, y: y))
}

/// Runs async work from the finisher's plain top-level code.
private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

func waitFor<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}
