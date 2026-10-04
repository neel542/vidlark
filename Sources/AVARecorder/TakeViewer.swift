import AVKit
import SwiftUI

// Watching a take without leaving the app. Click a card on the Recordings page and its video plays
// here: the camera, the screen or an extra camera, switched at the same moment of the take.

/// One file of a take that can be watched, and where it sits in the take.
struct TakeSource: Identifiable, Equatable {
    var id: String
    var title: String
    var url: URL
    /// camera time = this file's time + offset, as in sync.json. Zero for camera.mov.
    var offset: Double

    /// Every video file in the folder: the finished video first, then the camera and the screen.
    static func all(in take: TakeInfo) -> [TakeSource] {
        let folder = take.folder
        let sync = (try? Data(contentsOf: folder.appendingPathComponent("sync.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var out: [TakeSource] = []
        let fm = FileManager.default
        // video.mp4 follows the Me and Screen clicks, on the camera's timeline.
        if Snapshots.active ? take.hasScreen : fm.fileExists(atPath: folder.appendingPathComponent("video.mp4").path) {
            out.append(TakeSource(id: "video", title: "Video", url: folder.appendingPathComponent("video.mp4"), offset: 0))
        }
        if Snapshots.active ? take.hasCamera : fm.fileExists(atPath: folder.appendingPathComponent("camera.mov").path) {
            out.append(TakeSource(id: "camera", title: "Camera", url: folder.appendingPathComponent("camera.mov"), offset: 0))
        }
        if Snapshots.active ? take.hasScreen : fm.fileExists(atPath: folder.appendingPathComponent("screen.mov").path) {
            // Before finishing there is no sync.json; a shared screen still starts where it was shared.
            let offset = (sync["screenOffsetSec"] as? NSNumber)?.doubleValue ?? sharedAt(folder) ?? 0
            out.append(TakeSource(id: "screen", title: "Screen", url: folder.appendingPathComponent("screen.mov"), offset: offset))
        }
        let cameras = (sync["cameras"] as? [[String: Any]]) ?? []
        for n in 2...9 {
            let name = "camera-\(n).mov"
            guard !Snapshots.active, fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { continue }
            let offset = (cameras.first { $0["file"] as? String == name }?["offsetSec"] as? NSNumber)?.doubleValue ?? 0
            out.append(TakeSource(id: "camera-\(n)", title: "Camera \(n)", url: folder.appendingPathComponent(name), offset: offset))
        }
        return out
    }

    /// The camera time of the "screen-start" line in events.jsonl, for a camera-first take.
    private static func sharedAt(_ folder: URL) -> Double? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"screen-start\"") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                return (object["t"] as? NSNumber)?.doubleValue
            }
        }
        return nil
    }
}

/// The player and which file it shows.
@MainActor
final class TakePlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var sources: [TakeSource] = []
    @Published private(set) var current: TakeSource?

    func load(_ take: TakeInfo) {
        sources = TakeSource.all(in: take)
        guard let first = sources.first, !Snapshots.active else { current = sources.first; return }
        current = first
        player.replaceCurrentItem(with: AVPlayerItem(url: first.url))
        player.play()
    }

    /// Shows another file at the same moment of the take, playing or paused as before.
    func show(_ source: TakeSource) {
        guard source != current else { return }
        let previous = current
        current = source
        guard !Snapshots.active else { return }
        let playing = player.rate > 0
        let takeTime = player.currentTime().seconds.isFinite ? player.currentTime().seconds + (previous?.offset ?? 0) : 0
        let item = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: item)
        // A screen shared mid-take has nothing before the share, so it starts at its own beginning.
        let target = max(0, takeTime - source.offset)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if playing { player.play() }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct TakeViewer: View {
    var take: TakeInfo
    var close: () -> Void
    @StateObject private var model = TakePlayer()

    var body: some View {
        GeometryReader { g in
            let compact = g.size.width < 760
            VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                header(compact: compact)
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        Palette.well
                        if Snapshots.active {
                            LinearGradient(colors: [Color(hex: 0x2A302D), Color(hex: 0x111413)], startPoint: .top, endPoint: .bottom)
                            Image(systemName: "play.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Palette.ink.opacity(0.8))
                        } else if model.sources.isEmpty {
                            Text("This take has no video files.")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.engraved)
                        } else {
                            PlayerView(player: model.player)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, compact ? 22 : 44)
            .padding(.top, compact ? (Snapshots.active ? 36 : 8) : 34)
            .padding(.bottom, compact ? 18 : 28)
        }
        .background(DeviceBody())
        .onAppear { model.load(take) }
        .onDisappear { model.stop() }
        .onExitCommand(perform: close)
    }

    @ViewBuilder
    private func header(compact: Bool) -> some View {
        let title = HStack(spacing: 14) {
            BackButton(action: close, help: "Back to all recordings")
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                Text(take.title)
                    .font(.system(size: compact ? 15 : 24, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: compact ? 11.5 : 13))
                    .foregroundStyle(Palette.engraved)
                    .lineLimit(1)
            }
        }
        if compact {
            VStack(alignment: .leading, spacing: 14) {
                title
                if model.sources.count > 1 { SourceSwitch(model: model, stretch: true) }
            }
        } else {
            HStack(alignment: .center, spacing: 14) {
                title
                Spacer(minLength: 24)
                if model.sources.count > 1 { SourceSwitch(model: model, stretch: false) }
            }
        }
    }

    private var meta: String {
        var parts = [TakeFormat.when(take.date)]
        if take.renamed { parts.append(take.videoTitle) } else if let n = take.number { parts.append("Take \(n)") }
        if let length = take.duration { parts.append(timecode(length)) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if let current = model.current {
                FooterLink(title: "Open in QuickTime Player", symbol: "play.rectangle") { openInQuickTime(current.url) }
            }
            FooterLink(title: "Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.current?.url ?? take.folder])
            }
            Spacer(minLength: 0)
            if let current = model.current, current.id == "screen", current.offset > 3 {
                Text("The screen was shared \(timecode(current.offset)) into the take.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.engraved)
                    .lineLimit(1)
            }
        }
    }

    private func openInQuickTime(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Camera, Screen, Camera 2: which file plays.
private struct SourceSwitch: View {
    @ObservedObject var model: TakePlayer
    var stretch: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.sources) { source in
                let on = source.id == model.current?.id
                Button { model.show(source) } label: {
                    Text(source.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? Palette.ink : Palette.dim)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: stretch ? .infinity : nil)
                        .frame(height: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.raised)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline))
        .animation(.easeOut(duration: 0.2), value: model.current?.id)
    }
}

private struct FooterLink: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hover ? Palette.ink : Palette.dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The system player, with its own play bar, scrubbing and full screen button.
private struct PlayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
