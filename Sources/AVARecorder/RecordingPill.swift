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

/// Finds the face in the camera picture a few times a second and keeps a square crop around it.
final class FaceTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Normalised to the camera picture, origin bottom left (Vision's convention).
    @Published private(set) var crop = CGRect(x: 0.21875, y: 0, width: 0.5625, height: 1)
    @Published private(set) var found = false
    /// Width over height of the camera picture.
    @Published private(set) var aspect: CGFloat = 16 / 9

    /// The whole picture fitted inside a square, with bars, never stretched.
    var wholePicture: CGRect {
        aspect >= 1 ? CGRect(x: 0, y: (1 - aspect) / 2, width: 1, height: aspect)
                    : CGRect(x: (1 - 1 / aspect) / 2, y: 0, width: 1 / aspect, height: 1)
    }

    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "ava.face")
    private let lock = NSLock()
    private var running = false
    private var last: CFTimeInterval = 0
    private var smoothed: CGRect?
    private var misses = 0

    /// Off unless the face box or bubble is showing. Off also stops the camera handing frames
    /// to this output at all, which saves CPU while the app sits idle.
    var active: Bool {
        get { lock.withLock { running } }
        set {
            lock.withLock { running = newValue }
            output.connection(with: .video)?.isEnabled = newValue
        }
    }

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active else {
            // The connection only exists once the camera is set up, so switch it off on first contact.
            connection.isEnabled = false
            return
        }
        let now = CACurrentMediaTime()
        guard now - last > 0.2, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now

        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let face = (request.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }

        let target: CGRect
        if let box = face?.boundingBox {
            misses = 0
            // Head and shoulders: about 2.8 face heights, centred a little below the face.
            let side = min(height, width, max(box.height * height * 2.8, height * 0.25))
            var cx = box.midX * width
            var cy = box.midY * height - box.height * height * 0.15
            cx = min(max(cx, side / 2), width - side / 2)
            cy = min(max(cy, side / 2), height - side / 2)
            target = CGRect(x: (cx - side / 2) / width, y: (cy - side / 2) / height, width: side / width, height: side / height)
        } else {
            misses += 1
            // Keep the last framing through a brief miss, then fall back to the middle of the picture.
            guard misses > 10 || smoothed == nil else { return }
            let side = min(width, height)
            target = CGRect(x: (width - side) / 2 / width, y: 0, width: side / width, height: side / height)
        }

        let next: CGRect
        if let old = smoothed {
            let k: CGFloat = 0.35
            next = CGRect(x: old.minX + (target.minX - old.minX) * k, y: old.minY + (target.minY - old.minY) * k,
                          width: old.width + (target.width - old.width) * k, height: old.height + (target.height - old.height) * k)
        } else {
            next = target
        }
        smoothed = next
        let hasFace = face != nil
        let ratio = width / height
        DispatchQueue.main.async {
            self.crop = next
            if self.found != hasFace { self.found = hasFace }
            if self.aspect != ratio { self.aspect = ratio }
        }
    }
}

/// The live camera picture, cropped to `crop` by sizing and offsetting the preview layer.
struct FaceZoomView: NSViewRepresentable {
    var session: AVCaptureSession
    var crop: CGRect

    func makeNSView(context: Context) -> ZoomPreviewNSView {
        let view = ZoomPreviewNSView()
        view.preview.session = session
        return view
    }

    func updateNSView(_ view: ZoomPreviewNSView, context: Context) {
        view.show(crop)
    }
}

final class ZoomPreviewNSView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
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

    private func place(animated: Bool) {
        guard crop.width > 0, crop.height > 0, bounds.width > 0 else { return }
        let width = bounds.width / crop.width
        let height = bounds.height / crop.height
        let mirrored = preview.connection?.isVideoMirrored ?? false
        let x = mirrored ? 1 - crop.maxX : crop.minX
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.4 : 0)
        CATransaction.setDisableActions(!animated)
        preview.frame = CGRect(x: -x * width, y: -crop.minY * height, width: width, height: height)
        CATransaction.commit()
    }
}

// MARK: - The box

final class PillState: ObservableObject {
    @Published var expanded = UserDefaults.standard.object(forKey: "faceBoxOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(expanded, forKey: "faceBoxOpen") }
    }
    @Published var faceZoom = true
    /// Nate Herk style: her face in a circle that IS part of the screen recording.
    @Published var bubble = UserDefaults.standard.bool(forKey: "faceInVideo") {
        didSet { UserDefaults.standard.set(bubble, forKey: "faceInVideo") }
    }
}

/// The round face that goes into the video. Only her face: no time, no buttons.
struct FaceBubbleView: View {
    var session: AVCaptureSession
    @ObservedObject var tracker: FaceTracker

    var body: some View {
        Group {
            if Snapshots.active {
                LinearGradient(colors: [Color(hex: 0x3A403C), Color(hex: 0x141716)], startPoint: .top, endPoint: .bottom)
            } else {
                FaceZoomView(session: session, crop: tracker.crop)
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(14)
    }
}

struct RecordingPillView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var state: PillState
    @ObservedObject var tracker: FaceTracker
    @State private var breathe = false

    var body: some View {
        Group {
            if state.expanded { box } else { pill }
        }
        .padding(10)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    /// Open: her face on top, controls underneath.
    private var box: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                Group {
                    if Snapshots.active {
                        LinearGradient(colors: [Color(hex: 0x3A403C), Color(hex: 0x141716)], startPoint: .top, endPoint: .bottom)
                    } else {
                        FaceZoomView(session: studio.camera.session, crop: state.faceZoom ? tracker.crop : tracker.wholePicture)
                    }
                }
                    .frame(width: 236, height: 236)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                    .onTapGesture { state.faceZoom.toggle() }
                    .help("Click to switch between her face and the whole picture")
                Text(caption)
                    .engraved(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
            controls
                .padding(.horizontal, 6)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.glass.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
    }

    /// Minimised: just the essentials.
    private var pill: some View {
        controls
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .frame(height: 46)
            .background(Capsule().fill(Palette.glass.opacity(0.95)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.09)))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Lamp(state: studio.isRolling ? .fail : .off, size: 9)
                .opacity(breathe ? 1 : 0.45)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 52, alignment: .leading)
            LiveMeter(meter: studio.meter)
                .frame(width: state.expanded ? 52 : 44)
            if state.expanded {
                RoundButton(symbol: state.bubble ? "person.crop.circle.fill" : "person.crop.circle", lit: state.bubble,
                            help: state.bubble ? "Take her face out of the video" : "Put her face in the video, in a circle") {
                    state.bubble.toggle()
                }
            }
            RoundButton(symbol: state.expanded ? "minus" : "person.crop.square", help: state.expanded ? "Hide the face box" : "Show her face") {
                state.expanded.toggle()
            }
            RoundButton(stop: true, help: "Stop recording") { studio.stop() }
                .disabled(!studio.isRolling)
        }
        .frame(height: 38)
    }

    private var caption: String {
        let base = !state.faceZoom ? "Whole picture" : tracker.found ? "Face" : "Looking for a face"
        return state.bubble ? base + " · in video" : base
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
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.ink).frame(width: 11, height: 11)
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

    init(studio: Studio) {
        bubble = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 228, height: 228),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        self.studio = studio
        panel = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 340),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingPillView(studio: studio, state: state, tracker: tracker))

        for window in [bubble] {
            window.isFloatingPanel = true
            window.level = .statusBar
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        bubble.contentView = NSHostingView(rootView: FaceBubbleView(session: studio.camera.session, tracker: tracker))

        studio.camera.attach(tracker.output)

        watches.append(studio.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.follow(phase) })
        watches.append(state.$expanded
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self else { return }
                tracker.active = (open || state.bubble) && panel.isVisible
                DispatchQueue.main.async { self.resize() }
            })
        watches.append(state.$bubble
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncBubble() } })
    }

    /// Shows or hides the round face and tells the recorder to let it into the video.
    private func syncBubble() {
        let wanted = state.bubble && panel.isVisible
        tracker.active = (state.expanded || state.bubble) && panel.isVisible
        if wanted {
            if !bubblePlaced, let visible = (studio.displayID.flatMap(DisplayChoice.screen(for:)) ?? NSScreen.main)?.visibleFrame {
                // Bottom right of the recorded screen, where a face cam usually sits.
                bubble.setFrameOrigin(NSPoint(x: visible.maxX - bubble.frame.width - 24, y: visible.minY + 24))
                bubblePlaced = true
            }
            bubble.orderFrontRegardless()
            // The window has to be on screen before the recorder can find it.
            let id = CGWindowID(bubble.windowNumber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.state.bubble, self.panel.isVisible else { return }
                self.studio.showInRecording([id])
            }
        } else {
            if bubble.isVisible { bubble.orderOut(nil) }
            studio.showInRecording([])
        }
    }

    private func follow(_ phase: Studio.Phase) {
        switch phase {
        case .starting, .recording, .stopping:
            tracker.active = state.expanded || state.bubble
            guard !panel.isVisible else {
                if phase == .recording { syncBubble() }
                return
            }
            if let main = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
                hiddenWindow = main
                main.orderOut(nil)
            }
            place()
            panel.orderFrontRegardless()
            syncBubble()
        default:
            tracker.active = false
            guard panel.isVisible else { return }
            panel.orderOut(nil)
            syncBubble()
            // Back to the full panel, which now shows the finishing progress.
            NSApp.activate(ignoringOtherApps: true)
            hiddenWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private var fitting: NSSize {
        panel.contentView?.fittingSize ?? NSSize(width: 280, height: 340)
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
