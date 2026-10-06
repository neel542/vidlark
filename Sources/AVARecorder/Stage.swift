import AVFoundation
import AppKit

// Me and Screen on the screen itself. Click Me and her camera grows out of the face bubble to fill
// the whole recorded screen; click Screen and it shrinks back down into the bubble. The motion
// shows the click worked, and because this window is part of the screen recording, screen.mov
// (and so the finished video) has exactly what she saw.

/// A camera picture in a window, fed by `CameraFeed`, that tells the feed whether it can be seen.
class FeedView: NSView {
    let preview = AVSampleBufferDisplayLayer()
    var feed: CameraFeed? {
        didSet { feed?.show(on: preview); update() }
    }
    /// Set while the window is see-through (the bubble while her camera fills the screen).
    var dimmed = false {
        didSet { if dimmed != oldValue { update() } }
    }
    private var watcher: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let watcher { NotificationCenter.default.removeObserver(watcher) }
        watcher = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    override func viewDidHide() { super.viewDidHide(); update() }
    override func viewDidUnhide() { super.viewDidUnhide(); update() }

    private func update() {
        let visible = Studio.quietDraw || (!dimmed && !isHiddenOrHasHiddenAncestor && (window?.occlusionState.contains(.visible) ?? false))
        feed?.set(preview, seen: visible)
    }
}

/// A clear window over the whole recorded screen. Clicks pass through it.
@MainActor
final class Stage {
    let window: PrompterPanel
    /// The camera picture, fed by `CameraFeed` while it shows.
    let picture = AVSampleBufferDisplayLayer()
    var feed: CameraFeed? {
        didSet { feed?.show(on: picture); feed?.set(picture, seen: false) }
    }
    /// The shape the picture shows through: the bubble's shape, or the whole screen.
    private let card = CALayer()
    private let duration: CFTimeInterval = 0.5
    /// Bumped on every move, so a move that was overtaken does not finish the newer one.
    private var generation = 0
    private(set) var fillsScreen = false

    init() {
        window = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        card.masksToBounds = true
        card.backgroundColor = NSColor.black.cgColor
        card.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        card.isHidden = true
        picture.videoGravity = .resize
        card.addSublayer(picture)
        view.layer?.addSublayer(card)
        window.contentView = view
    }

    /// Covers the recorded screen, empty, ready for a take. It has to be on screen before the take
    /// starts so the screen recording can include it.
    func cover(_ screen: NSScreen) {
        cover(screen.frame)
    }

    /// Covers just this part of the screen, the shared window, in AppKit coordinates.
    func cover(_ frame: CGRect) {
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
    }

    func reset() {
        generation += 1
        fillsScreen = false
        card.isHidden = true
        feed?.set(picture, seen: false)
        card.removeAllAnimations()
        picture.removeAllAnimations()
        window.orderOut(nil)
    }

    /// Her camera grows from the bubble (`from`, in screen coordinates) to the whole screen.
    func grow(from bubble: Look, cameraAspect: CGFloat, animated: Bool) {
        generation += 1
        fillsScreen = true
        set(bubble, opacity: bubble.visible ? 1 : 0)
        card.isHidden = false
        feed?.set(picture, seen: true)
        move(to: full(cameraAspect), opacity: 1, animated: animated, then: nil)
    }

    /// Her camera shrinks from the whole screen into the bubble, then `done` hands over to the
    /// bubble window. With no bubble in the video it fades away as it shrinks.
    func shrink(to bubble: Look, cameraAspect: CGFloat, animated: Bool, done: @escaping () -> Void) {
        generation += 1
        fillsScreen = false
        let mine = generation
        if card.isHidden {
            set(full(cameraAspect), opacity: 1)
            card.isHidden = false
            feed?.set(picture, seen: true)
        }
        move(to: bubble, opacity: bubble.visible ? 1 : 0, animated: animated) { [weak self] in
            guard let self, self.generation == mine else { return }
            done()
            self.card.isHidden = true
            self.feed?.set(self.picture, seen: false)
        }
    }

    /// Where the picture sits and what part of the camera it shows.
    struct Look {
        /// In screen coordinates.
        var frame: CGRect
        var cornerRadius: CGFloat
        var border: CGFloat
        /// The part of the camera picture shown, normalised, origin bottom left.
        var crop: CGRect
        var visible = true
    }

    /// The whole screen, the camera filling it: cropped a little above centre, as in video.mp4.
    private func full(_ cameraAspect: CGFloat) -> Look {
        let size = window.frame.size
        let screenAspect = size.width / max(size.height, 1)
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if cameraAspect > screenAspect {
            crop.size.width = screenAspect / cameraAspect
            crop.origin.x = (1 - crop.width) / 2
        } else {
            crop.size.height = cameraAspect / screenAspect
            crop.origin.y = (1 - crop.height) * 0.6
        }
        return Look(frame: window.frame, cornerRadius: 0, border: 0, crop: crop)
    }

    private func set(_ look: Look, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(look, opacity: opacity)
        CATransaction.commit()
    }

    private func move(to look: Look, opacity: Float, animated: Bool, then: (() -> Void)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? duration : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(then)
        apply(look, opacity: opacity)
        CATransaction.commit()
    }

    private func apply(_ look: Look, opacity: Float) {
        // Screen coordinates to this window's.
        let frame = look.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        card.frame = frame
        card.cornerRadius = look.cornerRadius
        card.borderWidth = look.border
        card.opacity = opacity
        let crop = look.crop
        picture.frame = CGRect(x: -crop.minX * frame.width / crop.width, y: -crop.minY * frame.height / crop.height,
                               width: frame.width / crop.width, height: frame.height / crop.height)
    }
}
