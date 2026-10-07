import SwiftUI

/*
 THESIS: The operator panel is the face of a field audio recorder, not a settings dashboard. It holds
 only what a take needs: the picture, the sources with their lamps and the meter, and one red record
 button. Every other choice lives in the Settings window, one plain sentence each, so the face itself
 never becomes the sidebar plus cards plus toggles layout of a generic capture app.

 OWN-WORLD: An anodised graphite body (#0E1110 to #151917) with engraved uppercase labels in a warm
 grey-green. Status lamps have a hot centre. The level meter is segmented, signal green through
 amber to red. Green means "live and good". Red is the record button, like a camera's, and the
 rolling lamp. Labels use the system sans; timecode uses tabular figures.

 STORY: Neel glances at the panel and knows camera, mic and screen are live. He picks today's video
 and presses the lit key. He watches time and level, then sees the files get finished and filed.
 The presenter sees only the prompter: one line, large, with the next line waiting faintly beneath it.

 FIRST VIEWPORT: Full screen. The video title top left; Live, Recordings and Settings top right. The
 16:9 picture fills the left with the prompter strip under it. The right column: Sources (camera,
 microphone with its meter, screen, extra cameras) with + Add, at most one attention card, then large
 light timecode and the 84pt red record button at the bottom. Narrow, the same stacked.

 FORM: field recorder face, position 5 of 7, seed 29f141b5.
 Raises: one next decision at monumental scale (from airport wayfinding); the next line waits one
 press away (from the vertical feed); fixed queue columns where only the state flips (from the
 split-flap board).
*/

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Palette {
    static let body = Color(hex: 0x0E1110)
    static let face = Color(hex: 0x151917)
    static let well = Color(hex: 0x070908)
    static let raised = Color(hex: 0x1B201E)
    static let hairline = Color.white.opacity(0.075)
    static let engraved = Color(hex: 0x86918B)
    static let ink = Color(hex: 0xECF1EE)
    static let dim = Color(hex: 0xA3ADA8)
    static let signal = Color(hex: 0x3DCC80)
    static let signalHot = Color(hex: 0x8CF0B8)
    static let amber = Color(hex: 0xE8B34B)
    static let red = Color(hex: 0xF04E3E)
    static let glass = Color(hex: 0x050706)
}

extension View {
    /// Small uppercase label, like lettering engraved into a device face.
    func engraved(_ color: Color = Palette.engraved) -> some View {
        self.font(.system(size: 9.5, weight: .semibold))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

enum LampState: Equatable {
    case ok, warn, fail, off

    var color: Color {
        switch self {
        case .ok: Palette.signal
        case .warn: Palette.amber
        case .fail: Palette.red
        case .off: Color(hex: 0x3A413D)
        }
    }

    var hot: Color {
        switch self {
        case .ok: Palette.signalHot
        case .warn: Color(hex: 0xFFE2A0)
        case .fail: Color(hex: 0xFFA89C)
        case .off: Color(hex: 0x4A524E)
        }
    }
}

struct Lamp: View {
    var state: LampState
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [state.hot, state.color],
                                 center: UnitPoint(x: 0.38, y: 0.32),
                                 startRadius: 0, endRadius: size * 0.6))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5))
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.2), value: state)
    }
}

/// The anodised body behind the panel: a faint top light falling onto graphite.
struct DeviceBody: View {
    var body: some View {
        ZStack {
            Palette.body
            LinearGradient(colors: [Color.white.opacity(0.035), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
        }
        .ignoresSafeArea()
    }
}

func timecode(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
}
