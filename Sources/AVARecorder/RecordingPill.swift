import AVFoundation
import AppKit
import Combine
import SwiftUI
import Vision

// While recording, the full-screen panel steps aside so the presenter has the whole monitor. A small box
// floats in the top corner instead: her face, zoomed in by face detection, with time, level and
// stop under it. It minimises to a pill and opens again. Like every app window it is cut out of
// the screen recording.

// MARK: - Face tracking

/// Finds the face in the camera picture and keeps a square crop around it, like a camera operator:
/// it holds still while she talks and moves a little, and glides over when she really moves.
/// It looks 10 times a second while she moves (or is not found) and 4 times while she is still.
final class FaceTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Normalised to the camera picture, origin bottom left (Vision's convention).
    @Published private(set) var crop = CGRect(x: 0.21875, y: 0, width: 0.5625, height: 1)
    @Published private(set) var found = false
    /// Width over height of the camera picture.
    @Published private(set) var aspect: CGFloat = 16 / 9

    /// The face framing widened or narrowed to another shape (width over height), so a wide or
    /// oval bubble is never stretched. Stays inside the picture.
    func framing(aspect target: CGFloat) -> CGRect {
        var w = crop.height * target / aspect
        var h = crop.height
        if w > 1 { h *= 1 / w; w = 1 }
        if h > 1 { w *= 1 / h; h = 1 }
        let x = min(max(crop.midX - w / 2, 0), 1 - w)
        let y = min(max(crop.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A square crop of `side` pixels centred near (cx, cy), kept inside the picture, normalised.
    private func square(side: CGFloat, cx: CGFloat, cy: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        let x = min(max(cx, side / 2), width - side / 2)
        let y = min(max(cy, side / 2), height - side / 2)
        return CGRect(x: (x - side / 2) / width, y: (y - side / 2) / height, width: side / width, height: side / height)
    }

    /// The whole picture fitted inside a square, with bars, never stretched.
    var wholePicture: CGRect {
        aspect >= 1 ? CGRect(x: 0, y: (1 - aspect) / 2, width: 1, height: aspect)
                    : CGRect(x: (1 - 1 / aspect) / 2, y: 0, width: 1 / aspect, height: 1)
    }

    let output = AVCaptureVideoDataOutput()
    /// The camera this tracker is attached to. Frames are switched on and off through it.
    weak var camera: CameraRecorder?
    private let queue = DispatchQueue(label: "ava.face")
    private let lock = NSLock()
    private var running = false
    private var last: CFTimeInterval = 0
    /// Made once and used for every look: a new handler and request each time cost about a
    /// third more (measured 5 Oct).
    private let handler = VNSequenceRequestHandler()
    private let faces = VNDetectFaceRectanglesRequest()
    private let bodies: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        return request
    }()
    /// Where the framing is. Only changes when she moves past the still zone.
    private var goal: CGRect?
    /// The last few framings asked for, averaged so the detector's own wobble never moves it.
    private var recent: [CGRect] = []
    /// The face followed last, so a second face in the picture does not steal the framing.
    private var lastFace: CGRect?
    private var lostSince: CFTimeInterval?
    /// Looks often until then: she has just moved, or is not found.
    private var busyUntil: CFTimeInterval = 0
    /// What was last sent to the main thread. Face queue only.
    private var sentFound = false
    private var sentAspect: CGFloat = 0

    /// Off unless the face box or bubble is showing. Off also stops the camera handing frames
    /// to this output at all, which saves CPU while the app sits idle (not during a take, see
    /// `CameraRecorder.setFrames`).
    var active: Bool {
        get { lock.withLock { running } }
        set {
            let changed = lock.withLock { () -> Bool in defer { running = newValue }; return running != newValue }
            if changed { camera?.setFrames(output, on: newValue) }
        }
    }

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Seconds between looks right now.
    func interval(at time: CFTimeInterval) -> CFTimeInterval {
        time < busyUntil ? 0.1 : 0.25
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active else { return }
        let now = CACurrentMediaTime()
        guard now - last >= interval(at: now) - 0.01, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        let next = frame(pixels, at: now)
        let hasFace = lostSince.map { now - $0 < 2 } ?? true
        let ratio = CGFloat(CVPixelBufferGetWidth(pixels)) / CGFloat(CVPixelBufferGetHeight(pixels))
        // Only a real change reaches the screen, so a still face costs the window nothing.
        guard next != nil || hasFace != sentFound || ratio != sentAspect else { return }
        sentFound = hasFace
        sentAspect = ratio
        DispatchQueue.main.async {
            if let next { self.crop = next }
            if self.found != hasFace { self.found = hasFace }
            if self.aspect != ratio { self.aspect = ratio }
        }
    }

    /// One look at the picture. Returns the new framing, or nil to hold it where it is. `time` is
    /// in seconds, from the camera clock or, for `--test-framing`, from a recorded file.
    func frame(_ pixels: CVPixelBuffer, at time: CFTimeInterval) -> CGRect? {
        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))
        try? handler.perform([faces], on: pixels, orientation: .up)
        let all = (faces.results ?? []).map(\.boundingBox)
        func size(_ r: CGRect) -> CGFloat { r.width * r.height }
        // The main person: the biggest face, unless the one followed so far is still there and
        // at least half as big, so someone walking past behind her never takes the frame.
        var face = all.max { size($0) < size($1) }
        if let biggest = face, let lastFace {
            face = all.filter { size($0) >= size(biggest) * 0.5 }
                .min { hypot($0.midX - lastFace.midX, $0.midY - lastFace.midY) < hypot($1.midX - lastFace.midX, $1.midY - lastFace.midY) } ?? biggest
        }

        var target: CGRect?
        if let box = face {
            lostSince = nil
            lastFace = box
            // Head and shoulders: about 2.8 face heights, centred a little below the face.
            let side = min(height, width, max(box.height * height * 2.8, height * 0.25))
            target = square(side: side, cx: box.midX * width, cy: box.midY * height - box.height * height * 0.15, width, height)
        } else {
            let since = lostSince ?? time
            lostSince = since
            // Quick looks for 2 seconds to catch her the moment she looks up again; after that
            // nobody may be there at all, so it goes back to 4 looks a second.
            if time - since < 2 { busyUntil = time + 0.1 }
            // Looking down at notes or turned away: hold the framing for 2 seconds, then follow
            // her body, and after 5 seconds with nobody there show the middle of the picture.
            if time - since > 2 {
                try? handler.perform([bodies], on: pixels, orientation: .up)
                if let body = (bodies.results ?? []).max(by: { $0.boundingBox.height < $1.boundingBox.height })?.boundingBox {
                    let side = min(height, width, max(body.width * width * 1.25, height * 0.35))
                    target = square(side: side, cx: body.midX * width, cy: body.maxY * height - side * 0.45, width, height)
                } else if time - since > 5 || goal == nil {
                    let side = min(width, height)
                    target = CGRect(x: (width - side) / 2 / width, y: 0, width: side / width, height: side / height)
                }
            }
        }
        guard let target else { return nil }

        recent.append(target)
        if recent.count > 3 { recent.removeFirst() }
        let n = CGFloat(recent.count)
        let steady = CGRect(x: recent.map(\.minX).reduce(0, +) / n, y: recent.map(\.minY).reduce(0, +) / n,
                            width: recent.map(\.width).reduce(0, +) / n, height: recent.map(\.height).reduce(0, +) / n)
        guard let current = goal else {
            goal = target
            busyUntil = time + 1
            return target
        }
        // Hold still while she talks and moves a little.
        let drift = hypot(steady.midX - current.midX, (steady.midY - current.midY) * height / width) / current.width
        let grow = abs(steady.width / current.width - 1)
        guard drift > 0.1 || grow > 0.15 else { return nil }
        // A big move (she sat down, or leaned right in) goes straight to where she is now.
        let next: CGRect
        if hypot(target.midX - current.midX, (target.midY - current.midY) * height / width) / current.width > 0.35 {
            recent = [target]
            next = target
        } else {
            next = steady
        }
        goal = next
        busyUntil = time + 1
        return next
    }
}

/// The live camera picture, cropped to `crop` by sizing and offsetting the preview layer.
/// The view is made once and handed in: a preview layer joining or leaving the camera session
/// mid-take changes the session, which can end the camera file.
struct FaceZoomView: NSViewRepresentable {
    var view: ZoomPreviewNSView
    var crop: CGRect

    func makeNSView(context: Context) -> ZoomPreviewNSView { view }

    func updateNSView(_ view: ZoomPreviewNSView, context: Context) {
        view.show(crop)
    }
}

final class ZoomPreviewNSView: FeedView {
    private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        preview.videoGravity = .resize
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ newCrop: CGRect) {
        guard newCrop != crop else { return }
        crop = newCrop
        place(animated: true)
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    /// Glides the picture to the crop, starting from where it is on screen right now, so a new
    /// framing that arrives mid-glide carries on smoothly instead of jumping.
    private func place(animated: Bool) {
        guard crop.width > 0, crop.height > 0, bounds.width > 0 else { return }
        let width = bounds.width / crop.width
        let height = bounds.height / crop.height
        let now = preview.presentation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = CGRect(x: -crop.minX * width, y: -crop.minY * height, width: width, height: height)
        CATransaction.commit()
        guard animated, let now else { return }
        for (key, from) in [("position", NSValue(point: now.position)), ("bounds", NSValue(rect: now.bounds))] {
            let glide = CABasicAnimation(keyPath: key)
            glide.fromValue = from
            glide.duration = 0.5
            // Starts gently and settles softly, like a hand on a tripod head.
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.05, 0.2, 1)
            preview.add(glide, forKey: key)
        }
    }
}

// MARK: - The box

final class PillState: ObservableObject {
    @Published var expanded = UserDefaults.standard.object(forKey: "faceBoxOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(expanded, forKey: "faceBoxOpen") }
    }
    @Published var faceZoom = true
    /// The "Share your screen?" card is open.
    @Published var askingToShare = false
}

/// The shape her face takes in the video.
enum BubbleShape: String, CaseIterable, Identifiable {
    case circle, square, oval, wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: "Circle"
        case .square: "Square"
        case .oval: "Oval"
        case .wide: "Wide"
        }
    }

    var size: CGSize {
        switch self {
        case .circle, .square: CGSize(width: 200, height: 200)
        case .oval: CGSize(width: 176, height: 228)
        case .wide: CGSize(width: 288, height: 162)
        }
    }

    var outline: AnyShape { outline(scale: 1) }

    /// The shape drawn at `scale` of its bubble size, corners scaled with it.
    func outline(scale: CGFloat) -> AnyShape {
        switch self {
        case .circle: AnyShape(Circle())
        case .square: AnyShape(RoundedRectangle(cornerRadius: 34 * scale, style: .continuous))
        case .oval: AnyShape(Ellipse())
        case .wide: AnyShape(RoundedRectangle(cornerRadius: 22 * scale, style: .continuous))
        }
    }
}

/// Her face as it goes into the video. Only her face: no time, no buttons.
struct FaceBubbleView: View {
    var preview: ZoomPreviewNSView
    @ObservedObject var studio: Studio
    @ObservedObject var tracker: FaceTracker

    var body: some View {
        let shape = studio.bubbleShape
        Group {
            if Snapshots.active {
                LinearGradient(colors: [Color(hex: 0x3A403C), Color(hex: 0x141716)], startPoint: .top, endPoint: .bottom)
            } else {
                FaceZoomView(view: preview, crop: tracker.framing(aspect: shape.size.width / shape.size.height))
            }
        }
        .frame(width: shape.size.width, height: shape.size.height)
        .clipShape(shape.outline)
        .overlay(shape.outline.stroke(Color.white.opacity(0.85), lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(14)
    }
}

struct RecordingPillView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var state: PillState
    @ObservedObject var tracker: FaceTracker
    var preview: ZoomPreviewNSView
    @State private var breathe = false
    /// The width of the box or pill, so the share card under it lines up with it.
    @State private var topWidth: CGFloat = 252

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // One face on screen at a time: when the face goes into the video, the bubble is the
            // face and this box keeps only the time, the level and the buttons.
            // While the video shows her (Me), her camera already fills the screen, so the box
            // keeps only the switch and the controls.
            Group { if state.expanded && !faceInVideo { box } else { pill } }
                .background(GeometryReader { g in Color.clear.preference(key: TopWidth.self, value: g.size.width) })
                .onPreferenceChange(TopWidth.self) { topWidth = $0 }
            if state.askingToShare || studio.shareProblem != nil { shareCard }
        }
        .padding(10)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    /// Open: her face on top, controls underneath.
    private var box: some View {
        // The controls stay on top and never move; her face picture comes and goes under them as
        // the video switches between Screen and Me.
        VStack(spacing: 8) {
            viewSwitch
            if showsSound { SoundButton(studio: studio) }
            // Lamp, time, meter and up to three buttons fit the box's 236pt exactly.
            controls
                .padding(.horizontal, 2)
            if showsFace { facePicture }
        }
        .frame(width: 236)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.glass.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
    }

    private var facePicture: some View {
        ZStack(alignment: .bottom) {
            Group {
                if Snapshots.active {
                    LinearGradient(colors: [Color(hex: 0x3A403C), Color(hex: 0x141716)], startPoint: .top, endPoint: .bottom)
                } else {
                    FaceZoomView(view: preview, crop: state.faceZoom ? tracker.crop : tracker.wholePicture)
                }
            }
                .frame(width: 236, height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                .onTapGesture { state.faceZoom.toggle() }
                .help("Click to switch between the face and the whole picture")
            Text(caption)
                .engraved(Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    /// Minimised: just the essentials.
    private var pill: some View {
        VStack(spacing: 6) {
            viewSwitch
            if showsSound { SoundButton(studio: studio) }
            controls
                .padding(.leading, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.glass.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
    }

    /// Me or Screen: what the finished video shows from now on. One click switches; the finished
    /// video fades between them, and both are recorded the whole time.
    private var viewSwitch: some View {
        HStack(spacing: 2) {
            ViewChoice(title: "Me", symbol: "person.fill", on: studio.showing == .camera) { studio.show(.camera) }
            ViewChoice(title: "Screen", symbol: "display", on: studio.showing == .screen) {
                if studio.takeHasScreen {
                    studio.show(.screen)
                } else if studio.askBeforeSharing {
                    studio.shareProblem = nil
                    SharePicker.show(.shareNow, studio: studio)
                } else {
                    studio.shareScreen()
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
        .disabled(!studio.isRolling)
        .opacity(studio.isRolling ? 1 : 0.5)
        .help("What the video shows. Click to switch; the finished video fades from one to the other.")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Lamp(state: studio.isRolling ? .fail : .off, size: 9)
                .opacity(breathe ? 1 : 0.45)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 52, alignment: .leading)
            LiveMeter(meter: studio.meter)
                .frame(width: state.expanded && !faceInVideo ? 40 : 44)
            // Her face in the screen part of the video, or not.
            if studio.showing == .screen && studio.takeHasScreen {
                RoundButton(symbol: studio.faceInVideo ? "person.crop.circle.fill" : "person.crop.circle", lit: studio.faceInVideo,
                            help: studio.faceInVideo ? "Take the face out of the video"
                                : "Put the face in the video (\(studio.bubbleShape.title.lowercased()))") {
                    studio.faceInVideo.toggle()
                }
            }
            if !faceInVideo && studio.showing == .screen {
                RoundButton(symbol: state.expanded ? "minus" : "person.crop.square", help: state.expanded ? "Hide the face box" : "Show the face") {
                    state.expanded.toggle()
                }
            }
            RoundButton(stop: true, help: "Stop recording") { studio.stop() }
                .disabled(!studio.isRolling)
        }
        .frame(height: 38)
    }

    /// The Mac's sound control: only while the screen is being recorded.
    private var showsSound: Bool { studio.takeHasScreen && studio.isRolling }

    /// The face bubble is showing for this take.
    private var faceInVideo: Bool { studio.faceInVideo && studio.takeHasScreen }

    /// Her face in this box: only while the video shows the screen, the box is open and the face
    /// is not already in the video as the bubble.
    private var showsFace: Bool { state.expanded && !faceInVideo && studio.showing == .screen }

    /// Why the screen cannot be shared, if it cannot.
    private var shareBlocked: String? {
        studio.shareProblem ?? (studio.screenAllowed ? nil
            : "Screen recording is not allowed yet. Allow AVA Recorder in System Settings, Privacy, then open the app again.")
    }

    /// Asks before the screen goes into the video, with the Mac's sound as a choice.
    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shareBlocked == nil ? "Share your screen?" : "The screen is not shared")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(shareBlocked ?? "From now on \(studio.display?.name ?? "the screen") is recorded too, and the video shows it. Click Me any time to go back to just you.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            if shareBlocked == nil {
                // The same tick box as the panel's After row.
                Button { studio.screenAudio.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: studio.screenAudio ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(studio.screenAudio ? Palette.signal : Palette.engraved)
                        Text("Include the Mac's sound").font(.system(size: 12)).foregroundStyle(Palette.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Also record what the Mac plays, such as a video on screen")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if shareBlocked == nil {
                    CardButton(title: "Cancel") { state.askingToShare = false }
                    CardButton(title: "Share screen", primary: true) {
                        state.askingToShare = false
                        studio.shareScreen()
                    }
                } else {
                    if !studio.screenAllowed {
                        CardButton(title: "Open Settings") { studio.askForScreenAccess() }
                    }
                    CardButton(title: "OK", primary: true) {
                        state.askingToShare = false
                        studio.shareProblem = nil
                    }
                }
            }
        }
        .padding(14)
        .frame(width: topWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.glass.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
    }

    private var caption: String {
        let base = !state.faceZoom ? "Whole picture" : tracker.found ? "Face" : "Looking for a face"
        return base
    }

    private var label: String {
        if let n = studio.countdown { return "\(n)" }
        switch studio.phase {
        case .starting: return "Starting"
        case .stopping: return "Saving"
        default: return timecode(studio.elapsed)
        }
    }
}

private struct RoundButton: View {
    var symbol = ""
    var stop = false
    var lit = false
    var help: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(hover ? Color(hex: 0x262C29) : Palette.raised)
                Circle().strokeBorder(Palette.hairline)
                if stop {
                    // The same red square as the panel's record button while recording.
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.red).frame(width: 12, height: 12)
                } else {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lit ? Palette.signal : Palette.dim)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The Mac's sound, in words: "Mac sound: Off", "Mac sound: Every app", "Mac sound: Only Chrome".
/// Click to switch it on or off; the arrow picks which app it comes from, so a video in Chrome can
/// go in without notifications or music from elsewhere.
private struct SoundButton: View {
    @ObservedObject var studio: Studio

    var body: some View {
        let face = HStack(spacing: 7) {
            Image(systemName: studio.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(studio.soundOn ? Palette.signal : Palette.engraved)
                .frame(width: 16)
            Text("Mac sound:").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.dim)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(studio.soundOn ? Palette.ink : Palette.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        Group {
            if Snapshots.active {
                HStack(spacing: 4) {
                    face
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.engraved)
                }
            } else {
                Menu {
                    Button { studio.setSound(on: false) } label: { tick(!studio.soundOn, "Off") }
                    Section("On, from") {
                        Button { studio.setSoundFrom(nil) } label: { tick(studio.soundOn && studio.soundFrom == nil, "Every app") }
                        ForEach(studio.soundApps) { app in
                            Button { studio.setSoundFrom(app.id) } label: { tick(studio.soundOn && studio.soundFrom == app.id, "Only \(app.name)") }
                        }
                    }
                } label: {
                    face
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline))
        .help("Pick whether the Mac's sound goes into the video, and from which app.")
    }

    private var value: String {
        guard studio.soundOn else { return "Off" }
        guard let id = studio.soundFrom else { return "Every app" }
        return "Only \(studio.soundApps.first { $0.id == id }?.name ?? id)"
    }

    @ViewBuilder private func tick(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct ViewChoice: View {
    var title: String
    var symbol: String
    var on: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(on ? Palette.glass : hover ? Palette.ink : Palette.dim)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(on ? Palette.signal : hover ? Palette.raised : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.18), value: on)
    }
}

private struct TopWidth: PreferenceKey {
    static let defaultValue: CGFloat = 252
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CardButton: View {
    var title: String
    var primary = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Palette.glass : Palette.ink)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(primary ? (hover ? Palette.signalHot : Palette.signal) : (hover ? Color(hex: 0x262C29) : Palette.raised)))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : Palette.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Window

@MainActor
final class RecordingPillController {
    private let panel: PrompterPanel
    private let studio: Studio
    private let state = PillState()
    private let tracker = FaceTracker()
    private var watches: [AnyCancellable] = []
    private weak var hiddenWindow: NSWindow?
    private let bubble: PrompterPanel
    private var bubblePlaced = false
    private let boxPreview = ZoomPreviewNSView()
    private let bubblePreview = ZoomPreviewNSView()
    /// Her camera across the whole screen for Me, and the motion to and from the bubble.
    private let stage = Stage()

    init(studio: Studio) {
        bubble = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 228, height: 228),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        self.studio = studio
        panel = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 340),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the stage, which is at status bar level so it covers the Dock and the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        boxPreview.feed = studio.feed
        bubblePreview.feed = studio.feed
        stage.feed = studio.feed
        panel.contentView = NSHostingView(rootView: RecordingPillView(studio: studio, state: state, tracker: tracker, preview: boxPreview))

        for window in [bubble] {
            window.isFloatingPanel = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        bubble.contentView = NSHostingView(rootView: FaceBubbleView(preview: bubblePreview, studio: studio, tracker: tracker))
        fitBubble()

        tracker.camera = studio.camera
        studio.camera.attach(tracker.output, framesOn: false)

        watches.append(studio.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.follow(phase) })
        watches.append(state.$expanded
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self else { return }
                updateTracker()
                DispatchQueue.main.async { self.resize() }
            })
        watches.append(studio.$faceInVideo
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncBubble() } })
        // Me or Screen, clicked: the camera grows to fill the screen or shrinks into the bubble.
        watches.append(studio.$showing
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.studio.phase == .recording else { return }
                    self.applyShowing(animated: true)
                    // The box drops or brings back her face picture.
                    self.updateTracker()
                    self.resize()
                }
            })
        // The remote's Screen button in a camera-first take: ask first, as a click does.
        watches.append(studio.$shareRequest
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.studio.isRolling, !self.studio.takeHasScreen else { return }
                self.studio.shareProblem = nil
                if self.studio.askBeforeSharing { SharePicker.show(.shareNow, studio: self.studio) } else { self.studio.shareScreen() }
            })
        // One shared window: the stage covers it and the bubble sits in its corner, following it.
        watches.append(studio.$sharedArea
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] area in DispatchQueue.main.async { self?.follow(area: area) } })
        // Sharing the screen mid-take brings the bubble in, if the face goes in the video.
        watches.append(studio.$takeHasScreen
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { if self?.panel.isVisible == true { self?.syncBubble() } }
            })
        watches.append(state.$askingToShare.map { _ in () }
            .merge(with: studio.$shareProblem.map { _ in () })
            .dropFirst(2)
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.resize() } })
        watches.append(studio.$bubbleShape
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitBubble() } })
    }

    /// Shows or hides the round face and tells the recorder to let it into the video.
    private func syncBubble() {
        let wanted = studio.faceInVideo && studio.takeHasScreen && panel.isVisible
        updateTracker()
        DispatchQueue.main.async { [weak self] in self?.resize() }
        if wanted {
            placeBubble()
            // While her camera fills the screen, the stage holds her face and the bubble waits unseen.
            bubble.alphaValue = stage.fillsScreen ? 0 : 1
            bubblePreview.dimmed = stage.fillsScreen
            bubble.orderFrontRegardless()
        } else if bubble.isVisible {
            bubble.orderOut(nil)
        }
        guard panel.isVisible else { studio.showInRecording([], bubble: false); return }
        // The windows have to be on screen before the recorder can find them.
        let ids = [CGWindowID(stage.window.windowNumber)] + (wanted ? [CGWindowID(bubble.windowNumber)] : [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.studio.showInRecording(ids, bubble: wanted && self.studio.faceInVideo)
        }
    }

    /// Where the face bubble is, in screen coordinates, and how it looks. For a take with no bubble,
    /// where it would be.
    private func bubbleLook() -> Stage.Look {
        placeBubble()
        let shape = studio.bubbleShape
        let size = shape.size
        let radius: CGFloat = switch shape {
        case .circle, .oval: min(size.width, size.height) / 2
        case .square: 34
        case .wide: 22
        }
        return Stage.Look(frame: CGRect(x: bubble.frame.minX + 14, y: bubble.frame.minY + 14, width: size.width, height: size.height),
                          cornerRadius: radius, border: 3, crop: tracker.framing(aspect: size.width / size.height),
                          visible: studio.faceInVideo && studio.takeHasScreen)
    }

    /// Me: her camera grows out of the bubble to fill the screen. Screen: it shrinks back in.
    private func applyShowing(animated: Bool) {
        let me = studio.showing == .camera && panel.isVisible
        guard me != stage.fillsScreen else { return }
        let look = bubbleLook()
        if me {
            bubble.alphaValue = 0
            bubblePreview.dimmed = true
            stage.grow(from: look, cameraAspect: studio.feed.aspect, animated: animated)
        } else {
            stage.shrink(to: look, cameraAspect: studio.feed.aspect, animated: animated) { [weak self] in
                self?.bubble.alphaValue = 1
                self?.bubblePreview.dimmed = false
            }
        }
    }

    /// Bottom right of the recorded screen, where a face cam usually sits, until it is dragged.
    /// Sharing one window, bottom right of that window.
    private func placeBubble() {
        if let area = studio.sharedArea {
            bubble.setFrameOrigin(NSPoint(x: area.maxX - bubble.frame.width - 12, y: area.minY + 12))
            return
        }
        guard !bubblePlaced, let visible = (studio.displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main)?.visibleFrame else { return }
        bubble.setFrameOrigin(NSPoint(x: visible.maxX - bubble.frame.width - 24, y: visible.minY + 24))
        bubblePlaced = true
    }

    /// The shared window moved, or sharing went back to the whole screen.
    private func follow(area: CGRect?) {
        guard panel.isVisible else { return }
        if let area {
            stage.cover(area)
            placeBubble()
        } else if let screen = studio.displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main {
            stage.cover(screen)
        }
        // Her camera across the window for Me follows the window too.
        if stage.fillsScreen { stage.grow(from: bubbleLook(), cameraAspect: studio.feed.aspect, animated: false) }
    }

    private func follow(_ phase: Studio.Phase) {
        switch phase {
        case .starting, .recording, .stopping:
            updateTracker(visible: true)
            guard !panel.isVisible else {
                if phase == .recording {
                    syncBubble()
                    applyShowing(animated: true)
                }
                return
            }
            if let main = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
                hiddenWindow = main
                main.orderOut(nil)
            }
            if let screen = studio.displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main { stage.cover(screen) }
            place()
            panel.orderFrontRegardless()
            syncBubble()
        default:
            tracker.active = false
            state.askingToShare = false
            stage.reset()
            bubble.alphaValue = 1
            bubblePreview.dimmed = false
            guard panel.isVisible else { return }
            panel.orderOut(nil)
            syncBubble()
            // Back to the full panel, which now shows the finishing progress.
            NSApp.activate(ignoringOtherApps: true)
            hiddenWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// The tracker runs only while a face picture shows: the box during Screen, or the bubble.
    private func updateTracker(visible: Bool? = nil) {
        let box = state.expanded && studio.showing == .screen
        let bubble = studio.faceInVideo && studio.takeHasScreen
        tracker.active = (box || bubble) && (visible ?? panel.isVisible)
    }

    private var fitting: NSSize {
        panel.contentView?.fittingSize ?? NSSize(width: 280, height: 340)
    }

    /// Sizes the bubble window to its shape, keeping its bottom right corner where it is.
    private func fitBubble() {
        let shape = studio.bubbleShape.size
        let size = NSSize(width: shape.width + 28, height: shape.height + 28)
        let old = bubble.frame
        guard old.size != size else { return }
        bubble.setFrame(NSRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height), display: true)
    }

    /// Top right of the recorded screen, unless it has been dragged somewhere else this session.
    private var placed = false

    private func place() {
        let size = fitting
        if placed, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            resize()
            return
        }
        guard let visible = (studio.displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
        placed = true
    }

    /// Opening or closing the box keeps its top right corner where it is.
    private func resize() {
        let size = fitting
        let old = panel.frame
        panel.setFrame(NSRect(x: old.maxX - size.width, y: old.maxY - size.height, width: size.width, height: size.height),
                       display: true, animate: false)
    }
}
