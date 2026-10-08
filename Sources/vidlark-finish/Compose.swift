import AVFoundation
import Foundation

// video.mp4: the finished video. During the take, Me fills the screen with her camera and Screen
// shrinks it back into the face bubble, and all of that is in screen.mov, so from the moment
// screen.mov has pictures the video is simply screen.mov. Before that (a camera-first take, until
// the screen is shared) it is camera.mov, cropped the same way her camera filled the screen.
// The sound is the mic from camera.mov, or another mic picked for the video (lined up by the
// finisher), plus the Mac's sound when it was ticked.
//
// With face framing (Framing.swift), wherever the video shows camera.mov across the frame its crop
// follows her face. That includes each Me inside screen.mov when the screen was lined up by sound:
// there the camera is laid over screen.mov's copy of it, meeting it at the same crop at both ends.

struct ComposeResult {
    var seconds: Double
    var width: Int
    var height: Int
    /// When the video changes from camera.mov to screen.mov, if it starts on camera.mov.
    var cameraUntil: Double?
    var framing: FramingOutcome?
}

/// What the finisher knows for framing: her face in camera.mov, and the clicks of Me and Screen.
struct FramingInput {
    var faces: FaceTrack
    var shows: [ShowChange]
    /// screen.mov is lined up by sound, so each Me inside it can be shown from camera.mov too.
    var meToo: Bool
}

struct FramingOutcome {
    /// Looks that found a face, and all looks.
    var looksWithFace: Int
    var looks: Int
    /// Glides of the crop while the video shows the camera.
    var glides: Int
    /// Seconds of video showing camera.mov across the frame, and how many Me stretches of screen.mov that includes.
    var cameraSeconds: Double
    var meStretches: Int
}

/// How long the change from camera.mov to screen.mov takes.
let handoverSeconds = 0.25

/// `sharedLate`: a camera-first take, so screen.mov starts with her camera across the screen and
/// the change can wait a moment for it.
func composeVideo(camera: URL, screen: URL, screenOffset: Double, sharedLate: Bool, sound: (url: URL, offset: Double)? = nil,
                  framing: FramingInput? = nil, out: URL) async throws -> ComposeResult {
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

    // Where the video shows camera.mov across the frame, and where in the picture its crop sits.
    let (upright, cameraSize) = try await uprightTransform(cameraVideo)
    let fill = fillCrop(pictureAspect: cameraSize.width / max(cameraSize.height, 1), canvasAspect: canvas.width / max(canvas.height, 1))
    var path = CropPath(width: fill.w, height: fill.h, home: fill.home, start: fill.home, moves: [])
    if let framing {
        path = framePath(framing.faces.looks, width: framing.faces.width, height: framing.faces.height, crop: (fill.w, fill.h), home: fill.home)
    }
    let meToo = framing?.meToo == true && !path.still
    let stretches = cameraStretches(end: end.seconds, screenFrom: screenFrom, screenTo: screenTo, cut: cut,
                                    shows: framing?.shows ?? [], meToo: meToo)

    // The camera lies over the screen and shows only in its stretches, fading where it meets screen.mov.
    let cameraLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cameraTrack)
    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    cameraLayer.setOpacity(stretches.first?.from == 0 ? 1 : 0, at: .zero)
    for stretch in stretches {
        if stretch.fadeIn > 0 {
            cameraLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: time(stretch.from), duration: time(stretch.fadeIn)))
        } else if stretch.from > 0 {
            cameraLayer.setOpacity(1, at: time(stretch.from))
        }
        if stretch.fadeOut > 0 {
            cameraLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                                       timeRange: CMTimeRange(start: time(stretch.to - stretch.fadeOut), duration: time(stretch.fadeOut)))
        } else if stretch.to < end.seconds - 0.001 {
            cameraLayer.setOpacity(0, at: time(stretch.to))
        }
    }

    // The crop, frame by frame at 30 a second: held where it holds, and a straight step from each
    // frame to the next while it glides, so every frame of a glide sits exactly on its curve.
    let k = max(canvas.width / cameraSize.width, canvas.height / cameraSize.height)
    func place(_ p: CropPoint) -> CGAffineTransform {
        upright.concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: -p.x * cameraSize.width * k, y: -p.y * cameraSize.height * k))
    }
    var index = 0
    func crop(at t: Double) -> CropPoint {
        while index < stretches.count, t > stretches[index].to { index += 1 }
        guard index < stretches.count, t >= stretches[index].from else { return path.home }
        return framedCrop(path, at: t, in: stretches[index])
    }
    let frames = Int((end.seconds * 30).rounded(.up))
    var previous = crop(at: 0)
    var moving = false
    cameraLayer.setTransform(place(previous), at: .zero)
    if frames > 0 {
        for f in 1...frames {
            let p = crop(at: Double(f) / 30)
            let step = CMTimeRange(start: CMTime(value: CMTimeValue(f - 1) * 20, timescale: 600), duration: CMTime(value: 20, timescale: 600))
            if hypot((p.x - previous.x) * cameraSize.width * k, (p.y - previous.y) * cameraSize.height * k) > 0.01 {
                cameraLayer.setTransformRamp(fromStart: place(previous), toEnd: place(p), timeRange: step)
                moving = true
            } else if moving {
                cameraLayer.setTransform(place(p), at: step.start)
                moving = false
            }
            previous = p
        }
    }

    let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
    screenLayer.setTransform(try await fitting(screenVideo, into: canvas), at: .zero)
    screenLayer.setOpacity(1, at: .zero)

    var outcome: FramingOutcome?
    if let framing {
        let shown = stretches.reduce(0) { $0 + $1.to - $1.from }
        let glides = path.moves.filter { move in move.d > 0 && stretches.contains { move.t + move.d > $0.from && move.t < $0.to } }.count
        outcome = FramingOutcome(looksWithFace: framing.faces.looks.filter { !$0.faces.isEmpty }.count, looks: framing.faces.looks.count,
                                 glides: glides, cameraSeconds: shown, meStretches: stretches.filter(\.homeAtStart).count)
    }

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: end)
    instruction.layerInstructions = [cameraLayer, screenLayer]
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
                         cameraUntil: cut > 0 ? cut : nil, framing: outcome)
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

/// The transform that puts a track's picture the right way up with its corner at the origin, and its upright size.
private func uprightTransform(_ track: AVAssetTrack) async throws -> (CGAffineTransform, CGSize) {
    let (natural, preferred) = try await track.load(.naturalSize, .preferredTransform)
    let box = CGRect(origin: .zero, size: natural).applying(preferred)
    return (preferred.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY)),
            CGSize(width: abs(box.width), height: abs(box.height)))
}

/// Puts a track the right way up and scales it to fit the canvas, centred.
private func fitting(_ track: AVAssetTrack, into canvas: CGSize) async throws -> CGAffineTransform {
    let (upright, size) = try await uprightTransform(track)
    let k = min(canvas.width / size.width, canvas.height / size.height)
    let x = (canvas.width - size.width * k) / 2, y = (canvas.height - size.height * k) / 2
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
