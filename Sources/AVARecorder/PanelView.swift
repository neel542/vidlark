import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    @ObservedObject var studio: Studio
    /// The camera picture to show. The recorder brought back during a take has its own, since
    /// one view can only be in one window.
    var preview: PreviewNSView?
    @State private var showQueue = false
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { g in
            if g.size.width >= 900 { wide } else { compact }
        }
        .frame(minWidth: 400, minHeight: 741)
        .background(DeviceBody())
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.signal.opacity(0.7), lineWidth: 1.5)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    private var viewfinder: some View {
        Viewfinder(preview: preview ?? studio.mainPreview, hasCamera: studio.cameraName != nil && studio.cameraAllowed,
                   rolling: studio.isRolling, resting: studio.cameraResting, countdown: studio.countdown)
    }

    /// The small window: everything stacked, like the face of a pocket recorder.
    private var compact: some View {
        VStack(spacing: 0) {
            header(big: false)
                // The windowed title bar band holds the traffic lights; snapshots have none.
                .padding(.top, Snapshots.active ? 36 : 8)
            viewfinder
                .frame(height: 200)
                .padding(.top, 14)
            setup(dense: true)
                .padding(.top, 16)
            Spacer(minLength: 12)
            transport(big: false)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
    }

    /// Full screen on a big monitor: the camera picture takes the room, with a live copy of
    /// the presenter's prompter under it, and the controls in one column on the right.
    private var wide: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(big: true)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 18) {
                    // The picture keeps its shape; the prompter strip under it takes what is left,
                    // so its bottom lines up with the record button whatever the screen's shape.
                    viewfinder
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                    if studio.currentItem != nil {
                        PrompterView(studio: studio)
                            .frame(minHeight: 170, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                VStack(spacing: 0) {
                    setup(dense: false)
                    Spacer(minLength: 24)
                    transport(big: true)
                }
                .frame(width: 380)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 40)
    }

    // MARK: Header

    private func header(big: Bool) -> some View {
        HStack(alignment: .center, spacing: big ? 10 : 8) {
            queueButton(big: big)
                .padding(.trailing, big ? 8 : 2)
            if studio.liveMode != .off {
                HeaderButton(symbol: "dot.radiowaves.left.and.right", title: "Live", big: big,
                             help: "Live view is on. Click for the link.", lamp: studio.liveFailure == nil ? .ok : .fail) {
                    SettingsWindow.show(.live)
                }
            }
            if big {
                RecordingsButton(big: big)
            } else {
                HeaderButton(symbol: "film.stack", title: "Recordings", big: false,
                             help: "Every recording (Command-Shift-R)", lamp: nil) { RecordingsWindow.show() }
            }
            HeaderButton(symbol: "gearshape", title: "Settings", big: big,
                         help: "Settings, with what every option does (Command-Comma)", lamp: nil) {
                SettingsWindow.show()
            }
        }
    }

    private func queueButton(big: Bool) -> some View {
        Button { showQueue.toggle() } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(studio.currentItem == nil ? "No script" : studio.script.title)
                        .font(.system(size: big ? 24 : 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: big ? 13 : 11.5))
                        .foregroundStyle(Palette.engraved)
                        .lineLimit(1)
                }
                if !big { Spacer(minLength: 8) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: big ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Palette.engraved)
                if big { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!studio.isBusy)
        .popover(isPresented: $showQueue, arrowEdge: .bottom) {
            QueueView(studio: studio, close: { showQueue = false })
        }
    }

    private var subtitle: String {
        guard let item = studio.currentItem else { return "Drop a script here to add one" }
        let position = (studio.queue.firstIndex(of: item) ?? 0) + 1
        var parts = ["Video \(position) of \(studio.queue.count)", "\(studio.script.targetMinutes) min"]
        if item.recordings > 0 { parts.append(item.recordings == 1 ? "1 take" : "\(item.recordings) takes") }
        return parts.joined(separator: " · ")
    }

    // MARK: Setup

    /// The sources, and under them the one thing to fix, if there is one.
    private func setup(dense: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SourcesPanel(studio: studio, dense: dense)
            if let attention = studio.attention, !studio.isBusy {
                AttentionCard(attention: attention) { studio.fix($0) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.attention)
    }

    // MARK: Transport

    private func transport(big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // A take of just the camera: the one way to bring the screen in.
            if studio.isRolling && !studio.takeHasScreen {
                ShareScreenButton(studio: studio)
                    .transition(.opacity)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(timecode(studio.elapsed))
                        .font(.system(size: big ? 64 : 44, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(studio.isRolling ? Palette.ink : Palette.dim)
                        .contentTransition(.numericText())
                    HStack(spacing: 8) {
                        Text("of \(studio.script.targetMinutes):00")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.engraved)
                        ProgressHairline(value: studio.elapsed / Double(max(1, studio.script.targetMinutes * 60)))
                            .frame(width: 96)
                    }
                }
                Spacer()
                RecordKey(look: keyLook) { keyPressed() }
                    .disabled(!keyEnabled)
            }

            guidance
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }
        .animation(.easeOut(duration: 0.2), value: studio.phase)
    }

    private var keyLook: RecordKey.Look {
        switch studio.phase {
        case .idle, .done, .failed: studio.canStart ? .ready : .unavailable
        case .starting: studio.countingIn ? .rolling : .busy(nil)
        case .recording: .rolling
        case .stopping: .busy(nil)
        case .finishing(_, let p): .busy(p)
        }
    }

    private var keyEnabled: Bool {
        switch studio.phase {
        case .recording: true
        case .starting: studio.countingIn
        case .idle, .done, .failed: studio.canStart
        default: false
        }
    }

    private func keyPressed() {
        if studio.countingIn { studio.cancelStart() } else if studio.isRolling { studio.stop() } else { studio.start() }
    }

    @ViewBuilder private var guidance: some View {
        switch studio.phase {
        case .idle:
            Text(studio.canStart ? "Ready. Press the red button to record." : "Not ready yet. The note above says what to fix.")
                .guidanceStyle()
        case .starting:
            Text(studio.countingIn ? "Get ready. Recording starts after the count, so start talking at the beep. Press the button to cancel."
                 : studio.takeHasScreen ? "Starting the camera and screen." : "Starting the camera.")
                .guidanceStyle()
        case .recording:
            if let problem = studio.shareProblem, !studio.takeHasScreen {
                Text(problem).guidanceStyle(Palette.amber)
            } else {
                Text("Recording. Press to stop.").guidanceStyle()
            }
        case .stopping:
            Text("Closing the files.").guidanceStyle()
        case .finishing(let step, _):
            Text("\(step).").guidanceStyle()
        case .done(_, let note):
            VStack(alignment: .leading, spacing: 8) {
                Text(note ?? "Saved and finished. Transcript, chapters and retakes are in the folder.")
                    .guidanceStyle()
                HStack(spacing: 16) {
                    LinkButton(title: "Open folder") { studio.openFolder() }
                    if studio.queue.contains(where: { $0.recordings == 0 }) {
                        LinkButton(title: "Next video") { studio.nextVideo() }
                    }
                }
            }
        case .failed(let message):
            Text(message).guidanceStyle(Palette.amber)
        }
    }

    // MARK: Drop

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                let name = url.deletingPathExtension().lastPathComponent
                Task { @MainActor in studio.addScript(text, name: name) }
            }
        }
    }
}

private extension Text {
    func guidanceStyle(_ color: Color = Palette.dim) -> some View {
        self.font(.system(size: 12.5))
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pieces

struct MenuChoice: Identifiable {
    let id = UUID()
    var title: String
    var selected: Bool
    var action: () -> Void
}

struct LiveMeter: View {
    @ObservedObject var meter: LevelMeter

    var body: some View {
        MeterBar(level: meter.level, peak: meter.peak)
    }
}

/// Segmented level meter over the top 60 dB. Up to 40 segments, fewer when it is narrow.
struct MeterBar: View {
    var level: Float
    var peak: Float

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let count = max(6, min(40, Int((size.width + gap) / 5)))
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let lit = Int(fraction(level) * Double(count))
            let peakIndex = Int(fraction(peak) * Double(count)) - 1
            for i in 0..<count {
                let rect = CGRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: size.height)
                let position = Double(i) / Double(count)
                let color: Color = position >= 0.9 ? Palette.red : position >= 0.75 ? Palette.amber : Palette.signal
                let on = i < lit || (i == peakIndex && peakIndex >= 0)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(on ? color : color.opacity(0.13)))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Mic level")
    }

    private func fraction(_ db: Float) -> Double { min(1, max(0, (Double(db) + 60) / 60)) }
}

struct ProgressHairline: View {
    var value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule()
                    .fill(value > 1 ? Palette.amber : Palette.signal)
                    .frame(width: g.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 2)
    }
}

struct LinkButton: View {
    var title: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hover ? Palette.signalHot : Palette.signal)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Opens the page with every recording. Always in the header, so it is one click from anywhere.
struct RecordingsButton: View {
    var big: Bool
    @State private var hover = false

    var body: some View {
        Button { RecordingsWindow.show() } label: {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .font(.system(size: big ? 12 : 11, weight: .semibold))
                Text("Recordings")
                    .font(.system(size: big ? 13 : 12, weight: .semibold))
            }
            .foregroundStyle(hover ? Palette.ink : Palette.dim)
            .padding(.horizontal, big ? 14 : 10)
            .frame(height: big ? 32 : 28)
            .background(Capsule().fill(hover ? Palette.raised : Palette.face))
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Every recording, with search, rename, copy and delete (Command-Shift-R)")
    }
}

/// The record button, like a camera's: a red disc in a white ring. Recording, the disc closes
/// into a red stop square; finishing, a green arc fills the ring.
struct RecordKey: View {
    enum Look: Equatable {
        case ready, unavailable, rolling
        case busy(Double?)
    }

    var look: Look
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(ringColor, lineWidth: 3)
                    .frame(width: 84, height: 84)
                switch look {
                case .ready, .rolling:
                    // One shape that closes from a disc into a square, the way a camera's button does.
                    let rolling = look == .rolling
                    RoundedRectangle(cornerRadius: rolling ? 7 : 34, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xFF6A5C), Palette.red], startPoint: .top, endPoint: .bottom))
                        .frame(width: rolling ? 32 : 68, height: rolling ? 32 : 68)
                        .brightness(hover ? 0.06 : 0)
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
                case .unavailable:
                    Circle().fill(Palette.raised).frame(width: 68, height: 68)
                        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                case .busy(let progress):
                    Circle().fill(Palette.raised).frame(width: 68, height: 68)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.02, progress))
                            .stroke(Palette.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 81, height: 81)
                            .animation(.easeOut(duration: 0.4), value: progress)
                    } else {
                        ProgressView().controlSize(.small).tint(Palette.dim)
                    }
                }
            }
            .frame(width: 88, height: 88)
            .contentShape(Circle())
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: look)
        }
        .buttonStyle(KeyPress())
        .onHover { hover = $0 }
        .accessibilityLabel(look == .rolling ? "Stop recording" : "Start recording")
    }

    private var ringColor: Color {
        switch look {
        case .ready, .rolling: Color.white.opacity(0.9)
        case .unavailable: Palette.hairline
        case .busy: Color.white.opacity(0.12)
        }
    }
}

private struct KeyPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Viewfinder

struct Viewfinder: View {
    var preview: PreviewNSView
    var hasCamera: Bool
    var rolling: Bool
    var resting = false
    /// 3, 2, 1 over the picture before a take.
    var countdown: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.well
            if hasCamera && Snapshots.active {
                LinearGradient(colors: [Color(hex: 0x2A302D), Color(hex: 0x111413)], startPoint: .top, endPoint: .bottom)
                if !resting && countdown == nil {
                    Text("Camera picture").font(.system(size: 12)).foregroundStyle(Palette.engraved)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if hasCamera {
                PreviewLayerView(view: preview)
            }
            if hasCamera && resting {
                // The camera is off to save power. Clicking the window brings the app forward, which wakes it.
                Color.black.opacity(0.62)
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Palette.engraved)
                    Text("Camera resting to save power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink.opacity(0.85))
                    Text("Click here to wake it")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.engraved)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            if !hasCamera {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Palette.engraved)
                    Text("No camera")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.engraved)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let countdown {
                Color.black.opacity(0.5)
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .ultraLight))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(countsDown: true))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
            if rolling {
                HStack(spacing: 6) {
                    Lamp(state: .fail, size: 7)
                    Text("Rec").engraved(Palette.ink)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(10)
                .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
        .animation(.easeOut(duration: 0.2), value: rolling)
        .animation(.easeOut(duration: 0.25), value: resting)
        .animation(.easeOut(duration: 0.24), value: countdown)
    }
}

/// During a take of just the camera, the one way to bring the screen in. It says what will be
/// recorded and what happens to this window, so pressing it holds no surprise.
private struct ShareScreenButton: View {
    @ObservedObject var studio: Studio
    @State private var hover = false

    var body: some View {
        Button { studio.askToShare() } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.signal.opacity(studio.sharing ? 0.08 : 0.14))
                    if studio.sharing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "rectangle.inset.filled.and.person.filled")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.signal)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(studio.sharing ? "Sharing the screen" : "Share screen")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Adds \(studio.sharePhrase) to the video. This window then shrinks to a small box with Me, Screen and Stop.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.dim)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover && !studio.sharing ? Palette.raised : Palette.face))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(studio.sharing)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.2), value: hover)
        .help("Start recording the screen too. Your camera keeps recording.")
    }
}

/// Shows the panel's camera picture, made once at launch and fed by `CameraFeed`.
struct PreviewLayerView: NSViewRepresentable {
    var view: PreviewNSView

    func makeNSView(context: Context) -> PreviewNSView { view }

    func updateNSView(_ view: PreviewNSView, context: Context) {}
}

final class PreviewNSView: FeedView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Queue

struct QueueView: View {
    @ObservedObject var studio: Studio
    var close: () -> Void
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if studio.queue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No videos yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Add a script and it appears on the prompter. The hook shows word for word, then one bullet at a time.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(studio.queue.enumerated()), id: \.element.id) { index, item in
                            row(index: index, item: item)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 18) {
                LinkButton(title: "Add script file") { openFile() }
                LinkButton(title: "Paste script") { paste() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 340)
        .background(Palette.face)
    }

    private func row(index: Int, item: VideoItem) -> some View {
        let selected = item.id == studio.currentID
        let parsed = item.parsed
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.engraved)
                .frame(width: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(parsed.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(parsed.targetMinutes) min · \(parsed.cards.count) lines")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.engraved)
            }
            Spacer(minLength: 6)
            if hovered == item.id {
                Button { studio.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.engraved)
                }
                .buttonStyle(.plain)
                .help("Remove from today")
            } else {
                Text(item.recordings == 0 ? "To film" : item.recordings == 1 ? "1 take" : "\(item.recordings) takes")
                    .font(.system(size: 11))
                    .foregroundStyle(item.recordings == 0 ? Palette.engraved : Palette.signal)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(selected ? Palette.raised : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { studio.select(item.id); close() }
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more scripts"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                studio.addScript(text, name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        studio.addScript(text, name: "Pasted script")
    }
}
