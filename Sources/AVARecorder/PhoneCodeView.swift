import AppKit
import SwiftUI

/// The window with the QR code that turns the iPhone into the camera over Wi-Fi.
enum PhoneCodeWindow {
    private static var window: NSWindow?

    static var isOpen: Bool { window != nil }

    static func show(studio: Studio) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: PhoneCodeView(studio: studio).preferredColorScheme(.dark))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Connect your iPhone"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Palette.body)
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() { window?.close() }
}

struct PhoneCodeView: View {
    @ObservedObject var studio: Studio
    /// Snapshots draw a stand-in link, since they have no network.
    var link: String? = Snapshots.active ? "https://Your-Mac.local:8791/sample/" : PhoneLink.shared.link

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            code
            VStack(alignment: .leading, spacing: 0) {
                Text("Connect your iPhone")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("No app, no cable and no shared Apple Account. The iPhone only needs to be on the same Wi-Fi as this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.dim)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 14) {
                    Step(n: 1, text: "Point the iPhone's Camera app at the code, then tap the link that appears.")
                    Step(n: 2, text: "The first time, Safari says \u{201C}This Connection Is Not Private\u{201D}. Tap Show Details, then \u{201C}visit this website\u{201D}, then Visit Website. It is AVA's own link, only on your Wi-Fi.")
                    Step(n: 3, text: "Tap Start camera, then Allow. Turn the iPhone sideways, back camera facing you.")
                }
                .padding(.top, 22)
                Spacer(minLength: 22)
                status
            }
            .frame(width: 380, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(minHeight: 400)
        .background(DeviceBody())
    }

    private var code: some View {
        VStack(spacing: 10) {
            Group {
                if let link, let image = PhoneLink.qrCode(link, side: 216) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 216, height: 216)
                } else {
                    Text("This Mac has no name on the network yet. Check Wi-Fi is on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(width: 216, height: 216)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
            if link != nil {
                Button { copyLink() } label: {
                    Label("Copy the link", systemImage: "link")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("For sending to the iPhone another way, such as by Messages")
            }
        }
    }

    private var state: PhoneState { studio.phoneState }

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
            Lamp(state: lamp, size: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(state.failure != nil ? Palette.amber : Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if state.connected {
                SmallButton(title: "Done", primary: true) { PhoneCodeWindow.close() }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var lamp: LampState {
        state.failure != nil ? .fail : state.connected ? .ok : state.present ? .warn : .off
    }

    private var headline: String {
        if state.failure != nil { return "The iPhone link is not running" }
        if state.connected { return "Connected" }
        if state.present { return "The iPhone page is open" }
        return "Waiting for the iPhone"
    }

    private var detail: String? {
        if let failure = state.failure { return failure }
        if state.connected { return "\(state.width) \u{00D7} \(state.height) at \(max(state.fps, 1)) frames a second. AVA uses it as the camera." }
        if state.present { return "Tap Start camera on the iPhone." }
        return "Scan the code with the iPhone."
    }

    private func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}

private struct Step: View {
    var n: Int
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Palette.raised))
                .overlay(Circle().strokeBorder(Palette.hairline))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink.opacity(0.9))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
