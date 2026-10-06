import AppKit
import SwiftUI

/// The window with phone n's QR code, which makes that phone a camera over Wi-Fi.
enum PhoneCodeWindow {
    private static var window: NSWindow?
    /// Which phone's code is showing, if any.
    private(set) static var showing: Int?

    static var isOpen: Bool { window != nil }

    static func show(studio: Studio, phone: Int) {
        if let window {
            if showing == phone {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
            window.close()
        }
        let host = NSHostingController(rootView: PhoneCodeView(studio: studio, phone: phone).preferredColorScheme(.dark))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Connect a phone"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Palette.body)
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard window === w else { return }
                window = nil
                showing = nil
            }
        }
        window = w
        showing = phone
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() { window?.close() }
}

struct PhoneCodeView: View {
    @ObservedObject var studio: Studio
    var phone: Int

    /// Snapshots draw a stand-in link, since they have no network.
    private var link: String? { Snapshots.active ? "https://192.168.1.20:8791/sample/\(phone)/" : PhoneLink.shared.link(phone) }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            code
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("An iPhone or an Android phone, with any account. No app and no cable: the phone only needs the same Wi-Fi as this Mac. \(role)")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.dim)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 14) {
                    Step(n: 1, text: "Point the phone's camera at the code, then tap the link that appears.")
                    Step(n: 2, text: "The first time, the phone warns that the connection is not private. It is AVA's own link, only on your Wi-Fi. On an iPhone, tap Show Details, then \u{201C}visit this website\u{201D}, then Visit Website. On Android, tap Advanced, then Proceed.")
                    Step(n: 3, text: "On the phone, pick Wide 16:9 or Tall 9:16, then tap Start camera and Allow. The picture keeps that shape however the phone turns.")
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
                    Text("This Mac has no address on the network yet. Check Wi-Fi is on.")
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
                .help("For sending to the phone another way, such as by a message")
            }
        }
    }

    private var state: PhoneState { studio.phoneState(phone) }

    /// "Connect a phone", or which one once there can be several.
    private var title: String {
        studio.phonesInUse.count > 1 || phone > 1 ? "Connect phone \(phone)" : "Connect a phone"
    }

    /// What the phone will be once it connects.
    private var role: String {
        studio.mainPhone == phone ? "It becomes the camera AVA films with."
            : "It films another angle, saved as its own file next to the main camera, so the angle can be picked in editing."
    }

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
        if state.failure != nil { return "The phone link is not running" }
        if state.connected { return "Connected" }
        if state.present { return "The phone's page is open" }
        return "Waiting for the phone"
    }

    private var detail: String? {
        if let failure = state.failure { return failure }
        if state.connected {
            let format = CameraFormat(width: state.width, height: state.height, fps: 30).name
            return "\(state.tall ? "Tall 9:16" : "Wide 16:9"), \(format), \(max(state.fps, 1)) frames a second."
        }
        if state.present { return "Tap Start camera on the phone." }
        return "Scan the code with the phone."
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
