import AVFoundation
import SwiftUI

// The panel's sources, like the sources list in OBS: one row per thing being recorded, each with
// a symbol, what it is, and a menu to change it. + adds another camera or the screen.

struct SourcesPanel: View {
    @ObservedObject var studio: Studio
    var dense: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Sources")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                AddSourceButton(studio: studio)
            }
            VStack(spacing: 0) {
                let rows = rowViews
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    row
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.face))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
        }
        .allowsHitTesting(!studio.isBusy)
        .opacity(studio.isBusy ? 0.6 : 1)
    }

    private var rowViews: [AnyView] {
        var rows: [AnyView] = [AnyView(cameraRow), AnyView(micRow)]
        for (i, device) in studio.activeExtras.enumerated() {
            rows.append(AnyView(SourceRow(symbol: "video.fill", badge: "\(i + 2)", title: "Camera \(i + 2)", detail: device.localizedName,
                                          lamp: .ok, dense: dense,
                                          menu: [MenuChoice(title: "Stop recording this camera", selected: false) { studio.toggleExtra(device.uniqueID) }])))
        }
        rows.append(AnyView(screenRow))
        return rows
    }

    private var cameraRow: some View {
        let resting = studio.cameraResting && studio.cameraAllowed && studio.cameraName != nil
        let phoneWaiting = studio.usingPhone && !Snapshots.active && !studio.phoneReady
        let lamp: LampState = !studio.cameraAllowed ? .fail : studio.cameraName == nil || phoneWaiting ? .warn : resting ? .off : .ok
        var detail = studio.cameraAllowed ? (studio.cameraName ?? "None connected") : "Not allowed yet"
        if resting {
            detail += " · Resting"
        } else if phoneWaiting {
            detail += " · Waiting for the iPhone"
        } else {
            if let format = studio.cameraFormat, studio.cameraName != nil { detail += " · \(format.name)" }
            if studio.touchUpOn && studio.cameraName != nil && !studio.usingPhone { detail += " · Studio Light" }
        }
        // The iPhone over Wi-Fi works with any Apple Account: last in the list, as the way in when
        // the iPhone does not show up by itself.
        let choices = studio.cameras.map { d in MenuChoice(title: d.localizedName, selected: d.uniqueID == studio.cameraID) { studio.cameraID = d.uniqueID } }
            + [MenuChoice(title: studio.usingPhone ? "\(PhoneLink.name): show the code…" : "\(PhoneLink.name) (scan a code)…",
                          selected: studio.usingPhone) { studio.usePhone() }]
        // Quality straight from the camera's menu, without opening Settings.
        let more = CameraQuality.allCases.map { q in
            MenuChoice(title: "Quality: \(q.title)", selected: studio.cameraQuality == q) { studio.cameraQuality = q }
        } + [MenuChoice(title: "Studio Light and other effects…", selected: false) { SettingsWindow.show(.effects) }]
        return SourceRow(symbol: "video.fill", title: "Camera", detail: detail, lamp: lamp, dense: dense, menu: choices, more: more)
    }

    private var micRow: some View {
        let device = studio.mics.first { $0.uniqueID == studio.micID }
        let name = studio.micName
        let connection = device.map(Studio.connection) ?? (Snapshots.active ? "USB" : nil)
        // The mic rests with the camera; both wake together.
        let resting = studio.cameraResting && studio.micAllowed && name != nil
        let lamp: LampState = !studio.micAllowed || name == nil ? .fail : resting ? .off : studio.micHeardRecently ? .ok : .warn
        let detail = !studio.micAllowed ? "Not allowed yet"
            : name.map { n in resting ? "\(n) · Resting" : connection.map { "\(n) · \($0)" } ?? n } ?? "None found"
        let choices = studio.mics.map { d in
            MenuChoice(title: "\(d.localizedName) (\(Studio.connection(d)))", selected: d.uniqueID == studio.micID) { studio.micID = d.uniqueID }
        }
        return SourceRow(symbol: "mic.fill", title: "Microphone", detail: detail, lamp: lamp, dense: dense, menu: choices,
                         note: name != nil && !studio.micHeardRecently && studio.micAllowed && !resting ? "Say something to test it." : nil) {
            if !resting { LiveMeter(meter: studio.meter) }
        }
    }

    /// Every take starts on her face. This row only says what Share screen will record when pressed
    /// (already picked in the chooser), and changes it. The Mac's sound is set in the recording box.
    private var screenRow: some View {
        let lamp: LampState = !studio.screenAllowed ? .fail : .ok
        let detail = !studio.screenAllowed ? "Not allowed yet" : sharedName
        return SourceRow(symbol: isWindow ? "macwindow" : "display", title: "Screen", detail: detail,
                         also: studio.screenAllowed ? "Recorded once you press Share screen" : nil, lamp: lamp, dense: dense, menu: shareChoices)
    }

    private var isWindow: Bool {
        if case .window = studio.shareTarget { true } else { false }
    }

    /// The screen's name, or the window's, in the same words as Settings.
    private var sharedName: String { studio.shareLabel }

    /// Each whole screen, then "A window…", which opens the chooser.
    private var shareChoices: [MenuChoice] {
        studio.displays.map { d in
            MenuChoice(title: "Entire screen: \(d.name)", selected: studio.shareTarget == .screen(d.id) || (!isWindow && d.id == studio.displayID)) {
                studio.shareTarget = .screen(d.id)
            }
        } + [MenuChoice(title: isWindow ? "A window: \(studio.shareTarget.label)…" : "A window…", selected: isWindow) {
            SharePicker.show(.chooseDefault, studio: studio)
        }]
    }
}

/// One source: a symbol, its name and what it is now, a lamp, and a menu to change it.
struct SourceRow<Below: View>: View {
    var symbol: String
    var badge: String?
    var title: String
    var detail: String
    /// A second quiet line under the detail, so neither has to be cut short.
    var also: String?
    var lamp: LampState
    var dense: Bool
    var menu: [MenuChoice]
    var more: [MenuChoice] = []
    var note: String?
    var quiet = false
    @ViewBuilder var below: Below
    @State private var hover = false

    init(symbol: String, badge: String? = nil, title: String, detail: String, also: String? = nil, lamp: LampState, dense: Bool,
         menu: [MenuChoice], more: [MenuChoice] = [], note: String? = nil, quiet: Bool = false,
         @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.symbol = symbol
        self.badge = badge
        self.title = title
        self.detail = detail
        self.also = also
        self.lamp = lamp
        self.dense = dense
        self.menu = menu
        self.more = more
        self.note = note
        self.quiet = quiet
        self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if Snapshots.active || menu.count + more.count == 0 {
                    face
                } else {
                    Menu {
                        ForEach(menu) { item($0) }
                        if !more.isEmpty {
                            Divider()
                            ForEach(more) { item($0) }
                        }
                    } label: { face }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
            if !(below is EmptyView) || note != nil {
                VStack(alignment: .leading, spacing: 6) {
                    below
                    if let note {
                        Text(note).font(.system(size: 11.5)).foregroundStyle(Palette.amber)
                    }
                }
                .padding(.leading, 42)
                .padding(.trailing, 4)
            }
        }
        .padding(.vertical, dense ? 9 : 11)
        .onHover { hover = $0 }
    }

    private func item(_ choice: MenuChoice) -> some View {
        Button { choice.action() } label: {
            if choice.selected { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
        }
    }

    private var face: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.raised)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(quiet ? Palette.engraved : Palette.ink)
                    }
                if let badge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.glass)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Palette.ink))
                        .offset(x: 3, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(quiet ? Palette.dim : Palette.ink)
                ForEach([detail] + (also.map { [$0] } ?? []), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if !quiet { Lamp(state: lamp) }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hover ? Palette.dim : Palette.engraved)
        }
        .contentShape(Rectangle())
    }
}

/// + Add: another camera, or the screen when it is not being recorded from the start.
struct AddSourceButton: View {
    @ObservedObject var studio: Studio
    @State private var hover = false

    var body: some View {
        let face = HStack(spacing: 5) {
            Image(systemName: "plus").font(.system(size: 10.5, weight: .bold))
            Text("Add").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(hover ? Palette.ink : Palette.dim)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(hover ? Palette.raised : Palette.face))
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .contentShape(Capsule())

        Group {
            if Snapshots.active {
                face
            } else {
                Menu {
                    let others = studio.cameras.filter { $0.uniqueID != studio.cameraID && !studio.extraCameraIDs.contains($0.uniqueID) }
                    Section("Another camera") {
                        if others.isEmpty {
                            Text("No other camera is connected")
                        }
                        ForEach(others, id: \.uniqueID) { device in
                            Button(device.localizedName) { studio.toggleExtra(device.uniqueID) }
                        }
                    }
                    Divider()
                    Button("How to connect a camera…") { SettingsWindow.show(.cameraGuide) }
                } label: { face }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .onHover { hover = $0 }
        .help("Add another camera")
    }
}

/// The one thing to fix before a take, said plainly, with the button that fixes it.
struct AttentionCard: View {
    var attention: Studio.Attention
    var fix: (Studio.Attention.Fix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Lamp(state: attention.level).padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) {
                Text(attention.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                if attention.fix != nil || attention.learnMore != nil {
                    HStack(spacing: 16) {
                        if let action = attention.fix, let title = attention.fixTitle {
                            LinkButton(title: title) { fix(action) }
                        }
                        if let page = attention.learnMore {
                            LinkButton(title: "What is this?") { SettingsWindow.show(page) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(attention.level.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(attention.level.color.opacity(0.28)))
    }
}

/// A capsule button for the panel header.
struct HeaderButton: View {
    var symbol: String
    var title: String
    var big: Bool
    var help: String
    var lamp: LampState?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let lamp { Lamp(state: lamp, size: 6) }
                Image(systemName: symbol)
                    .font(.system(size: big ? 12 : 11, weight: .semibold))
                if big {
                    Text(title)
                        .font(.system(size: big ? 13 : 12, weight: .semibold))
                }
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
        .help(help)
        .fixedSize()
    }
}
