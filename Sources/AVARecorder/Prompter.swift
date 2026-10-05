import AppKit
import Combine
import SwiftUI

/// What the presenter reads. One line at a time, large, with the next line waiting faintly beneath it.
struct PrompterView: View {
    @ObservedObject var studio: Studio

    var body: some View {
        GeometryReader { g in
            // The strip is already taller for bigger text, so the size only lifts the cap.
            let base = max(22, min(g.size.height * 0.19, 54 * studio.prompterSize))
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.glass)
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07))
                VStack(alignment: .leading, spacing: 0) {
                    stage(base: base)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                        .padding(.bottom, 10)
                    rail
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func stage(base: CGFloat) -> some View {
        if let n = studio.countdown {
            Text("\(n)")
                .font(.system(size: base * 1.9, weight: .light))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("count-\(n)")
                .transition(.opacity)
        } else if studio.autoScroll && studio.isRolling && studio.scrollAt != nil && !studio.ended {
            ScrollingScript(studio: studio, base: base)
        } else if studio.ended {
            line(dot: .off, text: "End of script. Look at the lens, then stop.", size: base * 0.75, opacity: 0.7)
        } else if let card = studio.currentCard ?? (studio.isRolling ? nil : studio.script.cards.first) {
            let waiting = !studio.isRolling
            let current = line(dot: waiting ? .off : .ok, text: card.text, size: card.prose ? base * 0.86 : base, opacity: waiting ? 0.55 : 1,
                               spoken: card.prose && studio.following && !waiting ? studio.spokenWords : 0)
                .id("card-\(studio.cardIndex)-\(waiting)")
                .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .opacity))
            // The current line gets the room first (shrinking to fit if it must); the next line waits
            // underneath only when a whole line of it fits in what is left.
            VStack(alignment: .leading, spacing: 0) {
                current.layoutPriority(1)
                if let next = waiting ? nil : studio.nextCard {
                    ViewThatFits(in: .vertical) {
                        Text(next.text)
                            .font(.system(size: base * 0.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.3))
                            .lineLimit(1)
                            .padding(.leading, base * 0.62)
                            .padding(.top, base * 0.32)
                        Color.clear.frame(height: 0)
                    }
                    .id("next-\(studio.cardIndex)")
                    .transition(.opacity)
                }
            }
        } else {
            line(dot: .off, text: studio.isRolling ? "Recording. No script loaded." : "No script loaded. Add one on the panel.",
                 size: base * 0.7, opacity: 0.6)
        }
    }

    private func line(dot: LampState, text: String, size: CGFloat, opacity: Double, spoken: Int = 0) -> some View {
        HStack(alignment: .top, spacing: size * 0.36) {
            Lamp(state: dot, size: max(7, size * 0.24))
                .padding(.top, size * 0.42)
            said(text, spoken: spoken)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(opacity))
                .lineSpacing(size * 0.16)
                .minimumScaleFactor(0.55)
                .fixedSize(horizontal: false, vertical: false)
        }
    }

    /// Words she has already said fade to spent green, like the rail, so the full ink shows where she is.
    private func said(_ text: String, spoken: Int) -> Text {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard spoken > 0, spoken <= words.count else { return Text(text) }
        let done = words.prefix(spoken).joined(separator: " ")
        let rest = words.dropFirst(spoken).joined(separator: " ")
        return Text("\(Text(done).foregroundStyle(Palette.signal.opacity(0.5)))\(rest.isEmpty ? "" : " ")\(rest)")
    }

    private var rail: some View {
        VStack(spacing: 9) {
            if studio.script.cards.count > 1 {
                GeometryReader { g in
                    let count = studio.script.cards.count
                    let gap: CGFloat = count > 40 ? 1.5 : 3
                    let width = max(1, (g.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                    HStack(spacing: gap) {
                        ForEach(0..<count, id: \.self) { i in
                            Capsule()
                                .fill(segmentColor(i))
                                .frame(width: width)
                        }
                    }
                }
                .frame(height: 3)
            }
            HStack(spacing: 7) {
                if studio.following { Lamp(state: studio.hearing ? .ok : .off) }
                Text(railLeft).engraved()
                Spacer()
                Text(railRight)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(overBudget ? Palette.amber : Palette.engraved)
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.cardIndex)
    }

    private func segmentColor(_ i: Int) -> Color {
        guard studio.isRolling, studio.countdown == nil else { return Color.white.opacity(0.1) }
        if studio.ended || i < studio.cardIndex { return Palette.signal.opacity(0.35) }
        if i == studio.cardIndex { return Palette.signal }
        return Color.white.opacity(0.1)
    }

    private var railLeft: String {
        let total = studio.script.cards.count
        if !studio.isRolling { return total == 0 ? "Waiting to start" : "Waiting to start · \(total) lines" }
        if studio.countdown != nil { return "Starting" }
        if studio.ended { return "Done" }
        guard let card = studio.currentCard else { return timecode(studio.elapsed) }
        return "\(card.section) · \(studio.cardIndex + 1) of \(total)"
    }

    private var railRight: String {
        guard studio.isRolling else { return "Next line: the key under Esc" }
        guard studio.countdown == nil, !studio.ended, let budget = studio.cardBudget else { return short(studio.elapsed) }
        return "\(short(studio.cardElapsed)) of \(short(budget))"
    }

    private func short(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? timecode(t) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var overBudget: Bool {
        guard studio.isRolling, let budget = studio.cardBudget, !studio.ended else { return false }
        return studio.cardElapsed > budget * 1.25 + 5
    }
}

/// The whole script moving up at a steady pace, like a classic teleprompter. The words being read
/// sit at the green mark near the top; what comes next waits underneath.
private struct ScrollingScript: View {
    @ObservedObject var studio: Studio
    var base: CGFloat
    @State private var frames: [Int: CGRect] = [:]

    var body: some View {
        GeometryReader { g in
            let mark = min(g.size.height * 0.22, base * 1.4)
            TimelineView(.animation) { context in
                let y = position(studio.scrolledWords(at: context.date))
                VStack(alignment: .leading, spacing: base * 0.55) {
                    ForEach(Array(studio.script.cards.enumerated()), id: \.offset) { i, card in
                        Text(card.text)
                            .font(.system(size: card.prose ? base * 0.86 : base, weight: .semibold))
                            .foregroundStyle(Palette.ink.opacity(i < studio.cardIndex ? 0.3 : i == studio.cardIndex ? 1 : 0.62))
                            .lineSpacing(base * 0.16)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("script")) } action: { frames[i] = $0 }
                    }
                }
                .padding(.leading, base * 0.5)
                .coordinateSpace(.named("script"))
                .frame(width: g.size.width, alignment: .leading)
                .offset(y: mark - y)
            }
            .overlay(alignment: .topLeading) {
                // The reading mark.
                Capsule().fill(Palette.signal)
                    .frame(width: 3, height: base * 0.9)
                    .offset(y: mark - base * 0.45)
            }
        }
        .clipped()
        // Fades out well before the rail, so a line on its way up never crowds it.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.62), .init(color: .clear, location: 0.92)],
                             startPoint: .top, endPoint: .bottom))
        .padding(.bottom, base * 0.2)
    }

    /// Where the word being read sits, from the top of the script.
    private func position(_ words: Double) -> CGFloat {
        let starts = studio.cardStarts
        guard let i = starts.lastIndex(where: { Double($0) <= words }), let frame = frames[i] else { return 0 }
        let share = min(1, (words - Double(starts[i])) / Double(max(1, studio.script.cards[i].words)))
        return frame.minY + frame.height * share
    }
}

/// A floating strip that stays above PowerPoint, never takes focus and is never recorded
/// (the whole app is excluded from the screen capture).
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PrompterController {
    private let panel: PrompterPanel
    private let studio: Studio
    private var watch: AnyCancellable?
    private var sizeWatch: AnyCancellable?

    init(studio: Studio) {
        self.studio = studio
        panel = PrompterPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 230),
                              styleMask: [.borderless, .nonactivatingPanel, .resizable],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: 480, height: 150)
        panel.contentView = NSHostingView(rootView: PrompterView(studio: studio))
        panel.setFrameAutosaveName("Prompter")
        studio.onDisplaysChanged = { [weak self] in self?.placeIfLost() }
        // On screen during a take only, and only when Settings says to show it.
        watch = studio.$phase.combineLatest(studio.$showPrompter)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, show in
                switch phase {
                case .starting, .recording: if show { self?.show() } else { self?.panel.orderOut(nil) }
                default: self?.panel.orderOut(nil)
                }
            }
        // Bigger words need a taller strip, or they would only shrink back to fit.
        sizeWatch = studio.$prompterSize
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] size in self?.fit(size) }
    }

    func show() {
        guard !panel.isVisible else { return }
        if !panel.setFrameUsingName("Prompter") { placeAtTop() }
        placeIfLost()
        panel.orderFrontRegardless()
    }

    /// The strip's height for this text size, keeping its top edge where it is.
    private func fit(_ size: Double) {
        let height = (230 * size).rounded()
        let old = panel.frame
        guard abs(old.height - height) > 1 else { return }
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - height, width: old.width, height: height), display: true)
    }

    /// Top centre of the prompter screen, the edge nearest a camera on a tripod behind it.
    private func placeAtTop() {
        guard let screen = studio.prompterScreen else { return }
        let visible = screen.visibleFrame
        let width = min(920, visible.width - 80)
        let height = (230 * studio.prompterSize).rounded()
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 16, width: width, height: height), display: true)
    }

    private func placeIfLost() {
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen { placeAtTop() }
    }
}
