import AVFoundation
import Foundation

// video.mp4: the finished video. During the take, Me fills the screen with her camera and Screen
// shrinks it back into the face bubble, and all of that is in screen.mov, so from the moment
// screen.mov has pictures the video is simply screen.mov. Before that (a camera-first take, until
// the screen is shared) it is camera.mov, cropped the same way her camera filled the screen.
// The sound is the mic from camera.mov, or another mic picked for the video (lined up by the
// finisher), plus the Mac's sound when it was ticked.

/// One click of Me or Screen, in camera time.
struct ShowChange {
    var t: Double
    var screen: Bool
}

struct ComposeResult {
    var seconds: Double
    var width: Int
    var height: Int
    /// When the video changes from camera.mov to screen.mov, if it starts on camera.mov.
    var cameraUntil: Double?
}

/// How long the change from camera.mov to screen.mov takes.
let handoverSeconds = 0.25

/// `sharedLate`: a camera-first take, so screen.mov starts with her camera across the screen and
/// the change can wait a moment for it.
func composeVideo(camera: URL, screen: URL, screenOffset: Double, sharedLate: Bool, sound: (url: URL, offset: Double)? = nil,
                  out: URL) async throws -> ComposeResult {
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
        let source = within(range, from: from, to: to)
        try target.insertTimeRange(source, of: track, at: placed(source.start.seconds + offset))
        return target
    }

    guard let cameraTrack = try await add(cameraVideo, .video, offset: 0) else { throw FinishError("camera.mov has no picture") }
    guard let screenTrack = try await add(screenVideo, .video, offset: screenOffset) else { throw FinishError("screen.mov does not overlap the camera") }
    // The asset is kept for as long as the composition: a track whose asset has gone cannot be inserted.
    let soundAsset = sound.map { AVURLAsset(url: $0.url) }
    if let sound, let soundAsset, let mic = try await soundAsset.loadTracks(withMediaType: .audio).first,
       try await add(mic, .audio, offset: sound.offset) != nil {
        // The picked mic instead of the main one.
    } else if let cameraAudio {
        _ = try await add(cameraAudio, .audio, offset: 0)
    }
    if let macSound { _ = try await add(macSound, .audio, offset: screenOffset) }

    // The canvas has the screen's shape, at most 1920 wide, so the screen fills it without bars.
    let screenSize = try await orientedSize(screenVideo)
    let scale = min(1, 1920 / max(screenSize.width, 1))
    let canvas = CGSize(width: CGFloat(Int(screenSize.width * scale) & ~1), height: CGFloat(Int(screenSize.height * scale) & ~1))

    // Where the screen has pictures, in camera time.
    let screenRange = try await screenVideo.load(.timeRange)
    let screenFrom = max(0, screenRange.start.seconds + screenOffset)
    let screenTo = min(end.seconds, screenRange.end.seconds + screenOffset)
    // A screen that starts within a moment of the camera is the screen from the start.
    let cut = screenFrom < 1 ? 0 : screenFrom + (sharedLate ? 0.3 : 0)

    let cameraLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cameraTrack)
    cameraLayer.setTransform(try await fitting(cameraVideo, into: canvas, fill: true), at: .zero)
    let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
    screenLayer.setTransform(try await fitting(screenVideo, into: canvas, fill: false), at: .zero)
    if cut == 0 {
        cameraLayer.setOpacity(0, at: .zero)
        screenLayer.setOpacity(1, at: .zero)
    } else {
        // The screen fades in over camera.mov, which stays whole underneath until it has.
        let fade = CMTimeRange(start: CMTime(seconds: cut, preferredTimescale: 600), duration: CMTime(seconds: handoverSeconds, preferredTimescale: 600))
        cameraLayer.setOpacity(1, at: .zero)
        screenLayer.setOpacity(0, at: .zero)
        screenLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: fade)
        cameraLayer.setOpacity(0, at: fade.end)
    }
    // If the screen stops a moment before the camera, the camera covers the last moment.
    if screenTo < end.seconds - 0.05 {
        cameraLayer.setOpacity(1, at: CMTime(seconds: screenTo, preferredTimescale: 600))
    }

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: end)
    instruction.layerInstructions = [screenLayer, cameraLayer]
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
    withExtendedLifetime(soundAsset) {}
    return ComposeResult(seconds: end.seconds, width: Int(canvas.width), height: Int(canvas.height),
                         cameraUntil: cut > 0 ? cut : nil)
}

/// video.mp4 for a take with no screen: camera.mov's picture as it is, with another mic's sound
/// lined up under it. Nothing is compressed again.
func cameraWithSound(camera: URL, sound: (url: URL, offset: Double), out: URL) async throws -> ComposeResult {
    let cameraAsset = AVURLAsset(url: camera)
    guard let video = try await cameraAsset.loadTracks(withMediaType: .video).first else { throw FinishError("camera.mov has no picture") }
    // Kept for as long as the composition: a track whose asset has gone cannot be inserted.
    let soundAsset = AVURLAsset(url: sound.url)
    guard let mic = try await soundAsset.loadTracks(withMediaType: .audio).first else {
        throw FinishError("\(sound.url.lastPathComponent) has no sound")
    }
    let end = try await cameraAsset.load(.duration)
    let composition = AVMutableComposition()
    let range = try await video.load(.timeRange)
    guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let voice = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw FinishError("the video could not be put together")
    }
    try picture.insertTimeRange(range, of: video, at: range.start)
    picture.preferredTransform = try await video.load(.preferredTransform)
    // camera time = mic time + offset: nothing before the camera started, nothing after it stopped.
    let micRange = try await mic.load(.timeRange)
    let from = max(micRange.start.seconds, -sound.offset)
    let to = min(micRange.end.seconds, end.seconds - sound.offset)
    if to > from + 0.05 {
        let source = within(micRange, from: from, to: to)
        try voice.insertTimeRange(source, of: mic, at: placed(source.start.seconds + sound.offset))
    }
    try? FileManager.default.removeItem(at: out)
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw FinishError("this Mac cannot write the video")
    }
    export.timeRange = CMTimeRange(start: .zero, duration: end)
    try await export.export(to: out, as: .mp4)
    withExtendedLifetime(soundAsset) {}
    let size = try await orientedSize(video)
    return ComposeResult(seconds: end.seconds, width: Int(size.width), height: Int(size.height), cameraUntil: nil)
}

/// From `from` to `to` seconds, never past either end of `range`: a time rounded to a tick past
/// the end of a track makes inserting it fail.
private func within(_ range: CMTimeRange, from: Double, to: Double) -> CMTimeRange {
    let start = CMTimeMaximum(range.start, CMTime(seconds: from, preferredTimescale: 48_000))
    let end = CMTimeMinimum(range.end, CMTime(seconds: to, preferredTimescale: 48_000))
    return CMTimeRange(start: start, end: end)
}

/// Where an inserted piece goes, never before zero: a start worked out as 0.956 - 0.956 can come
/// to a hair below it, and inserting there fails.
private func placed(_ seconds: Double) -> CMTime {
    CMTime(seconds: max(0, (seconds * 48_000).rounded() / 48_000), preferredTimescale: 48_000)
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
