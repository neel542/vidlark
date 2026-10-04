import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    @ObservedObject var studio: Studio
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
        Viewfinder(preview: studio.mainPreview, hasCamera: studio.cameraName != nil && studio.cameraAllowed,
                   rolling: studio.isRolling)
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
            inputs(dense: true)
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
                    viewfinder
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if studio.currentItem != nil {
                        PrompterView(studio: studio)
                            .frame(height: 170)
                    }
                }
                VStack(spacing: 0) {
                    inputs(dense: false)
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
        HStack(alignment: .center, spacing: big ? 18 : 10) {
            queueButton(big: big)
            RecordingsButton(big: big)
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
        guard let item = studio.currentItem else { return "Record without a prompter, or add a script" }
        let position = (studio.queue.firstIndex(of: item) ?? 0) + 1
        var parts = ["Video \(position) of \(studio.queue.count)", "\(studio.script.targetMinutes) min"]
        if item.recordings > 0 { parts.append(item.recordings == 1 ? "1 take" : "\(item.recordings) takes") }
        return parts.joined(separator: " · ")
    }

    // MARK: Inputs

    private func inputs(dense: Bool) -> some View {
        // The prompter row comes back when the prompter does.
        let checks = studio.checks.filter { $0.id != "prompter" }
        return VStack(spacing: 0) {
            ForEach(checks) { check in
                InputRow(check: check, label: check.label, menu: menu(for: check.id), height: dense ? 33 : 38)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if check.id == "screen" && !studio.screenAllowed { studio.askForScreenAccess() }
                        if check.id == "after" { studio.writeTranscript.toggle() }
                        if check.id == "effects" { studio.openVideoEffects() }
                    }
                if check.id == "mic" {
                    LiveMeter(meter: studio.meter)
                        .padding(.leading, 17)
                        .padding(.bottom, 9)
                }
                if check.id != checks.last?.id { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
        .allowsHitTesting(!studio.isBusy)
    }

    private func menu(for id: String) -> [MenuChoice]? {
        switch id {
        case "camera":
            let main = studio.cameras.map { d in MenuChoice(title: d.localizedName, selected: d.uniqueID == studio.cameraID) { studio.cameraID = d.uniqueID } }
            // Any other camera can record its own file alongside the main one.
            let extra = studio.cameras.filter { $0.uniqueID != studio.cameraID }.map { d in
                MenuChoice(title: "Also record \(d.localizedName)", selected: studio.extraCameraIDs.contains(d.uniqueID)) { studio.toggleExtra(d.uniqueID) }
            }
            // Touch up is macOS Studio Light, set in Video Effects. Only the person at the Mac can switch it.
            let touchUp = MenuChoice(title: studio.touchUpOn ? "Touch up the face: on" : "Touch up the face", selected: studio.touchUpOn) {
                studio.openVideoEffects()
            }
            return main + extra + [touchUp]
        case "mic":
            return studio.mics.map { d in MenuChoice(title: d.localizedName, selected: d.uniqueID == studio.micID) { studio.micID = d.uniqueID } }
        case "screen":
            // Camera first: the take starts with only the camera, and the screen joins when it is
            // shared from the face box. Never shared, and the video is just the camera.
            let later = MenuChoice(title: "Camera first, share the screen when ready", selected: !studio.recordScreen) { studio.recordScreen = false }
            let sound = MenuChoice(title: "Include the Mac's sound", selected: studio.screenAudio) { studio.screenAudio.toggle() }
            guard studio.screenAllowed else { return studio.recordScreen ? nil : [later] }
            return studio.displays.map { d in
                MenuChoice(title: d.name, selected: studio.recordScreen && d.id == studio.displayID) {
                    studio.displayID = d.id
                    studio.recordScreen = true
                }
            } + [later, sound]
        case "prompter":
            return [MenuChoice(title: "Follows the voice", selected: studio.followVoice) { studio.followVoice = true },
                    MenuChoice(title: "Key only", selected: !studio.followVoice) { studio.followVoice = false }]
        case "face":
            var choices = [MenuChoice(title: "Screen only", selected: !studio.faceInVideo) { studio.faceInVideo = false }]
            for shape in BubbleShape.allCases {
                choices.append(MenuChoice(title: "Face in video, \(shape.title.lowercased())", selected: studio.faceInVideo && studio.bubbleShape == shape) {
                    studio.bubbleShape = shape
                    studio.faceInVideo = true
                })
            }
            return choices
        case "live":
            var choices = [
                MenuChoice(title: "Off", selected: studio.liveMode == .off) { studio.liveMode = .off },
                MenuChoice(title: "Home Wi-Fi", selected: studio.liveMode == .wifi) { studio.liveMode = .wifi },
                MenuChoice(title: "Anywhere", selected: studio.liveMode == .anywhere) { studio.liveMode = .anywhere },
            ]
            if studio.liveLink != nil {
                choices.append(MenuChoice(title: "Copy link", selected: false) { studio.copyLiveLink() })
            }
            if studio.liveMode != .off {
                choices.append(MenuChoice(title: "New link (old links stop working)", selected: false) { studio.newLiveLink() })
            }
            return choices
        default:
            return nil
        }
    }

    // MARK: Transport

    private func transport(big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let problem = studio.checks.first(where: { $0.problem != nil && $0.state == .fail })?.problem
                ?? (studio.isBusy ? nil : studio.checks.first(where: { $0.problem != nil })?.problem) {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        case .starting: .busy(nil)
        case .recording: .rolling
        case .stopping: .busy(nil)
        case .finishing(_, let p): .busy(p)
        }
    }

    private var keyEnabled: Bool {
        switch studio.phase {
        case .recording: true
        case .idle, .done, .failed: studio.canStart
        default: false
        }
    }

    private func keyPressed() {
        if studio.isRolling { studio.stop() } else { studio.start() }
    }

    @ViewBuilder private var guidance: some View {
        switch studio.phase {
        case .idle:
            Text(studio.canStart ? "Ready. Press the green key to start." : "Not ready yet. Check the lamps above.")
                .guidanceStyle()
        case .starting:
            Text("Starting the camera and screen.").guidanceStyle()
        case .recording:
            Text(studio.countdown != nil ? "Rolling. Start talking after the count." : "Recording. Press to stop.")
                .guidanceStyle()
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

struct InputRow: View {
    var check: Studio.Check
    var label: String
    var menu: [MenuChoice]?
    var height: CGFloat = 38

    var body: some View {
        HStack(spacing: 10) {
            Lamp(state: check.state)
            Text(label)
                .engraved()
                .frame(width: 66, alignment: .leading)
            if let menu, menu.count > 1, Snapshots.active {
                // A Menu cannot be drawn off screen, so snapshots show its face.
                menuFace
            } else if let menu, menu.count > 1 {
                Menu {
                    ForEach(menu) { choice in
                        Button { choice.action() } label: {
                            if choice.selected { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                        }
                    }
                } label: {
                    menuFace
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                valueText
            }
            Spacer(minLength: 0)
        }
        .frame(height: height)
    }

    private var menuFace: some View {
        HStack(spacing: 5) {
            valueText
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Palette.engraved)
        }
    }

    private var valueText: some View {
        HStack(spacing: 7) {
            if let tick = check.tick {
                Image(systemName: tick ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tick ? Palette.signal : Palette.engraved)
            }
            Text(check.value)
                .font(.system(size: 12.5))
                .foregroundStyle(check.state == .fail || check.tick == false ? Palette.dim : Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
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
                Image(systemName: "square.grid.2x2")
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

/// The one lit key. Green and ready, a stop square while rolling, a progress ring while finishing.
struct RecordKey: View {
    enum Look: Equatable {
        case ready, unavailable, rolling
        case busy(Double?)
    }

    var look: Look
    var action: () -> Void
    @State private var breathe = false
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Palette.hairline, lineWidth: 1).frame(width: 84, height: 84)
                switch look {
                case .ready:
                    Circle()
                        .fill(LinearGradient(colors: [Palette.signalHot.opacity(0.9), Palette.signal], startPoint: .top, endPoint: .bottom))
                        .frame(width: 62, height: 62)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                        .brightness(hover ? 0.05 : 0)
                case .unavailable:
                    Circle().fill(Palette.raised).frame(width: 62, height: 62)
                        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                case .rolling:
                    Circle()
                        .strokeBorder(Palette.red.opacity(breathe ? 0.9 : 0.35), lineWidth: 2)
                        .frame(width: 84, height: 84)
                    Circle().fill(Palette.raised).frame(width: 62, height: 62)
                        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Palette.ink)
                        .frame(width: 21, height: 21)
                case .busy(let progress):
                    Circle().fill(Palette.raised).frame(width: 62, height: 62)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.02, progress))
                            .stroke(Palette.signal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 83, height: 83)
                            .animation(.easeOut(duration: 0.4), value: progress)
                    } else {
                        ProgressView().controlSize(.small).tint(Palette.dim)
                    }
                }
            }
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(KeyPress())
        .onHover { hover = $0 }
        .onChange(of: look) { _, new in
            breathe = false
            if new == .rolling {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
            }
        }
        .accessibilityLabel(look == .rolling ? "Stop recording" : "Start recording")
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.well
            if hasCamera && Snapshots.active {
                LinearGradient(colors: [Color(hex: 0x2A302D), Color(hex: 0x111413)], startPoint: .top, endPoint: .bottom)
                Text("Camera picture").font(.system(size: 12)).foregroundStyle(Palette.engraved)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasCamera {
                PreviewLayerView(view: preview)
            } else {
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
