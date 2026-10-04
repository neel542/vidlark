import AppKit
import SwiftUI

// The Recordings page: every take on disk as a card, newest first, with a search, a filter and
// four actions (rename, show in Finder, save a copy, delete to the Trash). The file work lives in
// RecordingsStore.swift. Open it with `RecordingsWindow.show()`, or place `RecordingsView(onClose:)`.

// MARK: - Model

@MainActor
final class RecordingsModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, week, unfinished, screen, camera
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .week: "This week"
            case .unfinished: "Not finished"
            case .screen: "With screen"
            case .camera: "Camera only"
            }
        }
        /// For a narrow window, where five full names and counts do not fit.
        var shortTitle: String {
            switch self {
            case .all: "All"
            case .week: "Week"
            case .unfinished: "Not done"
            case .screen: "Screen"
            case .camera: "Camera"
            }
        }
    }

    /// What is happening to a take right now. Only `.none` allows rename, copy and delete.
    enum Activity: Equatable {
        case none, recording, finishing, copying
    }

    struct Notice: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var reveal: URL?
        var warn = false
        var working = false
    }

    @Published private(set) var takes: [TakeInfo] = []
    @Published private(set) var loaded = false
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published private(set) var notice: Notice?
    @Published private(set) var copying: Set<String> = []
    /// The take the recorder is writing or finishing, from the Studio's own state.
    @Published private(set) var held: [String: Activity] = [:]

    let root: URL
    private let staged: Bool
    private var cache = TakeStore.Cache()
    private var timer: Timer?
    private var scanning = false
    private var rescanSoon = false

    init(root: URL = Library.root) {
        self.root = root
        staged = false
    }

    /// For snapshots: fixed takes, nothing read from disk.
    init(staged takes: [TakeInfo], held: [String: Activity] = [:], filter: Filter = .all, search: String = "", notice: Notice? = nil) {
        root = URL(fileURLWithPath: "/nonexistent", isDirectory: true)
        staged = true
        self.takes = takes
        self.held = held
        self.filter = filter
        self.search = search
        self.notice = notice
        loaded = true
    }

    // MARK: Reading

    func start() {
        guard !staged, timer == nil else { return }
        refresh()
        // Takes appear, grow and finish while the page is open. A rescan is a few hundred file stats.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in self.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !staged else { return }
        guard !scanning else { rescanSoon = true; return }
        scanning = true
        let root = root, cache = cache
        Task {
            let result = await Task.detached(priority: .utility) { await TakeStore.scan(root: root, cache: cache) }.value
            self.cache = result.cache
            if result.takes != self.takes { self.takes = result.takes }
            self.updateHeld()
            self.loaded = true
            self.scanning = false
            if self.rescanSoon {
                self.rescanSoon = false
                self.refresh()
            }
        }
    }

    /// While the recorder is busy, its take may sit still for a while (the transcript takes
    /// minutes), so the 10 second rule alone is not enough: the newest unfinished take is held too.
    private func updateHeld() {
        let activity: Activity? = switch Studio.shared.phase {
        case .starting, .recording, .stopping: .recording
        case .finishing: .finishing
        default: nil
        }
        var next: [String: Activity] = [:]
        if let activity, let newest = takes.filter({ !$0.finished }).max(by: { $0.date < $1.date }) {
            next[newest.id] = activity
        }
        if next != held { held = next }
    }

    func activity(_ take: TakeInfo) -> Activity {
        if let a = held[take.id] { return a }
        if take.writing { return .recording }
        if copying.contains(take.id) { return .copying }
        return .none
    }

    // MARK: Filtering

    private var matching: [TakeInfo] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return takes }
        return takes.filter { take in
            let text = [take.title, take.videoTitle, take.folder.lastPathComponent,
                        take.folder.deletingLastPathComponent().lastPathComponent,
                        take.number.map { "Take \($0)" } ?? ""].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private func passes(_ take: TakeInfo, _ filter: Filter, now: Date) -> Bool {
        switch filter {
        case .all: true
        case .week: take.date > now.addingTimeInterval(-7 * 24 * 3600)
        case .unfinished: !take.finished
        case .screen: take.hasScreen
        case .camera: take.hasCamera && !take.hasScreen
        }
    }

    var visible: [TakeInfo] {
        let now = Date()
        return matching.filter { passes($0, filter, now: now) }
    }

    var counts: [Filter: Int] {
        let now = Date(), found = matching
        return Dictionary(uniqueKeysWithValues: Filter.allCases.map { f in (f, found.filter { passes($0, f, now: now) }.count) })
    }

    var summary: String {
        guard loaded else { return "Looking for recordings" }
        let total = takes.reduce(Int64(0)) { $0 + $1.bytes }
        let count = takes.count == 1 ? "1 take" : "\(takes.count) takes"
        return takes.isEmpty ? "Nothing filmed yet" : "\(count) · \(TakeFormat.size(total)) on disk"
    }

    // MARK: Actions

    func showInFinder(_ take: TakeInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([take.folder])
    }

    func rename(_ take: TakeInfo, to name: String) {
        guard activity(take) == .none else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != take.title else { return }
        let folder = take.folder
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try TakeStore.rename(folder, to: trimmed) } }.value
            switch result {
            case .success(let moved):
                if let i = takes.firstIndex(of: take) {
                    takes[i].folder = moved
                    takes[i].title = trimmed
                    takes[i].renamed = true
                    takes[i].number = nil
                }
                show(Notice(text: "Renamed to “\(trimmed)”"))
            case .failure(let error):
                show(Notice(text: "Could not rename. \(error.localizedDescription)", warn: true))
            }
            refresh()
        }
    }

    func delete(_ take: TakeInfo) {
        guard activity(take) == .none else { return }
        let folder = take.folder
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try TakeStore.moveToTrash(folder) } }.value
            switch result {
            case .success:
                takes.removeAll { $0.id == take.id }
                TakeThumbnails.shared.forget(take.id)
                show(Notice(text: "Moved “\(take.fullName)” to the Trash"))
            case .failure(let error):
                show(Notice(text: "Could not delete. \(error.localizedDescription)", warn: true))
            }
            refresh()
        }
    }

    /// Asks where, then copies in the background. The page stays usable while it copies.
    func saveCopy(_ take: TakeInfo) {
        guard activity(take) == .none else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = "Choose where to save a copy of “\(take.fullName)”"
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in self.copy(take, into: directory) }
        }
    }

    private func copy(_ take: TakeInfo, into directory: URL) {
        copying.insert(take.id)
        show(Notice(text: "Saving a copy of “\(take.fullName)”", working: true))
        let folder = take.folder, name = take.copyName
        Task {
            // A big copy blocks its thread for minutes, so it gets a thread of its own.
            let result: Result<URL, Error> = await withCheckedContinuation { done in
                DispatchQueue.global(qos: .utility).async {
                    done.resume(returning: Result { try TakeStore.copy(folder, named: name, into: directory) })
                }
            }
            copying.remove(take.id)
            switch result {
            case .success(let copy):
                show(Notice(text: "Saved a copy in \(directory.lastPathComponent)", reveal: copy))
            case .failure(let error):
                show(Notice(text: "Could not save the copy. \(error.localizedDescription)", warn: true))
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func dismissNotice() { notice = nil }

    private func show(_ next: Notice) {
        notice = next
        guard !next.working else { return }
        let id = next.id
        Task {
            try? await Task.sleep(for: .seconds(next.warn ? 8 : 5))
            if notice?.id == id { notice = nil }
        }
    }
}

// MARK: - Thumbnails in memory

/// Decoded thumbnails, kept small and few. At most two are made at once.
final class TakeThumbnails: @unchecked Sendable {
    static let shared = TakeThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private let gate = ThumbnailGate(slots: 2)

    private init() {
        // About 40 thumbnails at 640x360. Off screen ones are dropped first when it fills.
        cache.totalCostLimit = 40 * 640 * 360 * 4
    }

    func cached(_ id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    func put(_ image: NSImage, for id: String) {
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 640 * 360
        cache.setObject(image, forKey: id as NSString, cost: pixels * 4)
    }

    func forget(_ id: String) { cache.removeObject(forKey: id as NSString) }
    func clear() { cache.removeAllObjects() }

    func load(_ take: TakeInfo) async -> NSImage? {
        if let image = cached(take.id) { return image }
        await gate.enter()
        defer { Task { await gate.leave() } }
        if Task.isCancelled { return nil }
        if let image = cached(take.id) { return image }
        let folder = take.folder
        guard let cg = await Task.detached(priority: .utility, operation: { await TakeStore.thumbnail(for: folder) }).value else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        put(image, for: take.id)
        return image
    }
}

actor ThumbnailGate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(slots: Int) { free = slots }

    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

enum TakeFormat {
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                           : date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(day), \(time)"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Page

struct RecordingsView: View {
    @StateObject private var model: RecordingsModel
    private let onClose: (() -> Void)?
    /// Snapshots only: draws the hover button on the first card.
    private let showHover: Bool
    @State private var renaming: TakeInfo?
    @State private var newName = ""
    @State private var deleting: TakeInfo?
    /// The take playing in the viewer, which takes the place of the cards.
    @State private var watching: TakeInfo?

    /// The page for the real library. `onClose` adds a back button; leave it out in a window of its own.
    init(onClose: (() -> Void)? = nil) {
        self.init(model: Snapshots.active ? RecordingsModel.sample() : RecordingsModel(), onClose: onClose)
    }

    init(model: @autoclosure @escaping () -> RecordingsModel, onClose: (() -> Void)? = nil, showHover: Bool = false) {
        _model = StateObject(wrappedValue: model())
        self.onClose = onClose
        self.showHover = showHover
    }

    var body: some View {
        GeometryReader { g in
            let compact = g.size.width < 760
            if let watching {
                TakeViewer(take: watching) { self.watching = nil }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header(compact: compact)
                        .padding(.horizontal, compact ? 22 : 44)
                        // The window's title bar band holds the traffic lights; snapshots have none.
                        .padding(.top, compact ? (Snapshots.active ? 36 : 8) : 34)
                        .padding(.bottom, compact ? 18 : 26)
                    content(compact: compact)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 480)
        .background(DeviceBody())
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeBar(notice: notice, reveal: { notice.reveal.map(model.reveal) }, dismiss: model.dismissNotice)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.notice)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("Rename this take", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { take in
            TextField("Name", text: $newName)
            Button("Rename") { model.rename(take, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { take in
            Text("Filmed \(TakeFormat.when(take.date)). The folder on disk gets the new name too.")
        }
        .alert(deleting.map { "Delete “\($0.fullName)”?" } ?? "Delete?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { take in
            Button("Move to Trash", role: .destructive) { model.delete(take) }
            Button("Cancel", role: .cancel) {}
        } message: { take in
            Text("Filmed \(TakeFormat.when(take.date)), \(TakeFormat.size(take.bytes)). It goes to the Trash with all its files, so you can get it back until the Trash is emptied.")
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(compact: Bool) -> some View {
        let title = HStack(spacing: 14) {
            if let onClose { BackButton(action: onClose) }
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                Text("Recordings")
                    .font(.system(size: compact ? 15 : 24, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(model.summary)
                    .font(.system(size: compact ? 11.5 : 13))
                    .foregroundStyle(Palette.engraved)
                    .lineLimit(1)
            }
        }
        if model.loaded && model.takes.isEmpty {
            // Nothing to search or filter yet, so neither is shown.
            title.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        } else if compact {
            VStack(alignment: .leading, spacing: 14) {
                title
                SearchBox(text: $model.search)
                FilterBar(filter: $model.filter, counts: model.counts, stretch: true)
            }
        } else {
            HStack(alignment: .center, spacing: 14) {
                title
                Spacer(minLength: 24)
                SearchBox(text: $model.search).frame(width: 250)
                FilterBar(filter: $model.filter, counts: model.counts, stretch: false)
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        let shown = model.visible
        if !model.loaded {
            Spacer()
        } else if model.takes.isEmpty {
            EmptyNote(title: "No recordings yet", detail: "Every take you film shows up here, newest first.")
        } else if shown.isEmpty {
            EmptyNote(title: "Nothing matches", detail: model.search.isEmpty ? "No takes in “\(model.filter.title)”." : "No take has “\(model.search)” in its name.",
                      action: ("Show all recordings", { model.search = ""; model.filter = .all }))
        } else {
            let grid = LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 18, alignment: .top)],
                                 alignment: .leading, spacing: 18) {
                ForEach(shown) { take in
                    card(take, hover: showHover && take.id == shown.first?.id)
                }
            }
            .padding(.horizontal, compact ? 22 : 44)
            .padding(.bottom, 90)
            if Snapshots.active {
                // An off-screen render cannot draw a scroll view, so snapshots lay the cards out flat.
                grid
                Spacer(minLength: 0)
            } else {
                ScrollView { grid }
            }
        }
    }

    private func card(_ take: TakeInfo, hover: Bool) -> some View {
        TakeCard(take: take, activity: model.activity(take), forceHover: hover,
                 watch: { watching = take },
                 open: { model.showInFinder(take) },
                 rename: { newName = take.title; renaming = take },
                 saveCopy: { model.saveCopy(take) },
                 delete: { deleting = take })
    }
}

// MARK: - Card

struct TakeCard: View {
    var take: TakeInfo
    var activity: RecordingsModel.Activity
    var forceHover = false
    var watch: () -> Void
    var open: () -> Void
    var rename: () -> Void
    var saveCopy: () -> Void
    var delete: () -> Void
    @State private var hover = false

    private var busy: Bool { activity == .recording || activity == .finishing }
    private var lit: Bool { hover || forceHover }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TakeThumbnail(take: take, held: busy)
                .overlay(alignment: .topLeading) {
                    if activity == .recording {
                        HStack(spacing: 6) {
                            Lamp(state: .fail, size: 7)
                            Text("Rec").engraved(Palette.ink)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let length = take.duration, !busy {
                        Text(timecode(length))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if lit {
                        MoreButton { actions }
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if lit && canWatch {
                        Image(systemName: "play.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Palette.ink)
                            .offset(x: 2)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }

            Text(take.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 12)
            Text(meta)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.engraved)
                .lineLimit(1)
                .padding(.top, 3)

            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.top, 11)

            HStack(spacing: 7) {
                Lamp(state: lamp, size: 6)
                Text(status).engraved(activity == .recording ? Palette.ink : Palette.engraved)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(TakeFormat.size(take.bytes))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.engraved)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(lit ? Palette.raised : Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.2), value: hover)
        .onTapGesture { if canWatch { watch() } }
        .contextMenu { actions }
        .help(canWatch ? "Click to watch it" : "Recording now")
        .accessibilityAction(named: "Watch") { if canWatch { watch() } }
        .accessibilityAction(named: "Show in Finder", open)
    }

    /// A take can be watched once its files are closed.
    private var canWatch: Bool { activity != .recording && (take.hasCamera || take.hasScreen) }

    @ViewBuilder private var actions: some View {
        if canWatch { Button("Watch", action: watch) }
        Button("Show in Finder", action: open)
        if activity == .none {
            Button("Rename…", action: rename)
            Button("Save a Copy…", action: saveCopy)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        } else {
            Divider()
            Text(activity == .copying ? "Saving a copy now" : activity == .finishing ? "Finishing now, so it cannot be changed"
                 : "Recording now, so it cannot be changed")
        }
    }

    private var meta: String {
        let when = TakeFormat.when(take.date)
        if take.renamed { return "\(when) · \(take.videoTitle)" }
        if let n = take.number { return "\(when) · Take \(n)" }
        return when
    }

    private var lamp: LampState {
        switch activity {
        case .recording: return .fail
        case .finishing, .copying: return .off
        case .none: return take.warning != nil ? .warn : take.finished ? .ok : .off
        }
    }

    private var status: String {
        switch activity {
        case .recording: return "Recording"
        case .finishing: return "Finishing"
        case .copying: return "Saving a copy"
        case .none: return take.warning ?? (take.finished ? "Finished" : "Not finished")
        }
    }
}

/// The picture: thumbnail.jpg, made on first sight off the main thread and kept in a small cache.
struct TakeThumbnail: View {
    var take: TakeInfo
    var held: Bool
    @State private var image: NSImage?

    init(take: TakeInfo, held: Bool) {
        self.take = take
        self.held = held
        _image = State(initialValue: TakeThumbnails.shared.cached(take.id))
    }

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x161A18), Palette.well], startPoint: .top, endPoint: .bottom)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else if !take.hasCamera && !take.hasScreen {
                        Image(systemName: "video.slash")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Palette.engraved.opacity(0.6))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline))
            .animation(.easeOut(duration: 0.2), value: image != nil)
            .task(id: "\(take.id)|\(held)") {
                guard image == nil, !held, !Snapshots.active else { return }
                image = await TakeThumbnails.shared.load(take)
            }
    }
}

/// The round button that appears on a card under the pointer and opens the same menu as a right click.
private struct MoreButton<Items: View>: View {
    @ViewBuilder var items: () -> Items

    var body: some View {
        Group {
            if Snapshots.active {
                // A menu cannot be drawn off screen, so snapshots show its face.
                face
            } else {
                Menu(content: items) { face }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.black.opacity(0.6)))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
        .help("Rename, save a copy or delete")
        .accessibilityLabel("More")
    }

    private var face: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Palette.ink)
    }
}

// MARK: - Header pieces

struct BackButton: View {
    var action: () -> Void
    var help = "Back to the recorder"
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? Palette.ink : Palette.dim)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hover ? Palette.raised : Palette.face))
                .overlay(Circle().strokeBorder(Palette.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut("[", modifiers: .command)
        .help(help)
        .accessibilityLabel("Back")
    }
}

private struct SearchBox: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.engraved)
            if Snapshots.active {
                Text(text.isEmpty ? "Search recordings" : text)
                    .foregroundStyle(text.isEmpty ? Palette.engraved : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search", text: $text, prompt: Text("Search recordings").foregroundStyle(Palette.engraved))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onExitCommand { text = "" }
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.engraved)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.face))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Palette.signal.opacity(0.55) : Palette.hairline))
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

private struct FilterBar: View {
    @Binding var filter: RecordingsModel.Filter
    var counts: [RecordingsModel.Filter: Int]
    var stretch: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RecordingsModel.Filter.allCases) { choice in
                let on = choice == filter
                Button { filter = choice } label: {
                    HStack(spacing: 6) {
                        Text(stretch ? choice.shortTitle : choice.title)
                            .foregroundStyle(on ? Palette.ink : Palette.dim)
                        if !stretch {
                            Text("\(counts[choice] ?? 0)")
                                .monospacedDigit()
                                .foregroundStyle(on ? Palette.signal : Palette.engraved)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, stretch ? 6 : 11)
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
        .animation(.easeOut(duration: 0.2), value: filter)
    }
}

private struct EmptyNote: View {
    var title: String
    var detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            // The record key's ring, unlit.
            ZStack {
                Circle().strokeBorder(Palette.hairline, lineWidth: 1).frame(width: 56, height: 56)
                Circle().fill(Palette.raised).frame(width: 40, height: 40)
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .padding(.bottom, 6)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                LinkButton(title: action.0, action: action.1).padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

private struct NoticeBar: View {
    var notice: RecordingsModel.Notice
    var reveal: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if notice.working {
                ProgressView().controlSize(.small).tint(Palette.dim)
            } else {
                Lamp(state: notice.warn ? .warn : .ok)
            }
            Text(notice.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            if notice.reveal != nil {
                LinkButton(title: "Show", action: reveal)
            }
            if !notice.working {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Palette.engraved)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
        .background(Capsule().fill(Palette.raised))
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}

// MARK: - Window

/// The Recordings page in a window of its own, so it can be opened from anywhere in the app.
@MainActor
enum RecordingsWindow {
    private static var window: NSWindow?
    private static var closing: NSObjectProtocol?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: RecordingsView().preferredColorScheme(.dark))
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Recordings"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Palette.body)
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 1180, height: 780))
        w.center()
        _ = w.setFrameAutosaveName("AVA Recordings")
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            // Let the page, its timer and its thumbnails go when the window closes.
            MainActor.assumeIsolated {
                if let closing { NotificationCenter.default.removeObserver(closing) }
                closing = nil
                window = nil
                TakeThumbnails.shared.clear()
            }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Adds Window > Recordings with Command-Shift-R. Wire it in with `.commands { RecordingsCommands() }`.
struct RecordingsCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Recordings") { RecordingsWindow.show() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
        }
    }
}

// MARK: - Snapshot samples

extension RecordingsModel {
    /// Staged takes with drawn placeholder thumbnails, for `--snapshot`. Nothing on disk is read.
    static func sample(filter: Filter = .all, search: String = "", empty: Bool = false, notice: Notice? = nil) -> RecordingsModel {
        guard !empty else { return RecordingsModel(staged: [], filter: filter, search: search, notice: notice) }
        let now = Date()
        let calendar = Calendar.current
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let gb: Int64 = 1_000_000_000
        func take(_ n: Int, _ video: String, _ title: String? = nil, _ date: Date, _ length: TimeInterval?, _ bytes: Int64,
                  finished: Bool, camera: Bool = true, screen: Bool = true, writing: Bool = false) -> TakeInfo {
            let day = TakeStore.dayFormatter.string(from: date)
            let folder = URL(fileURLWithPath: "/Sample/\(day) \(video)/\(title ?? "recording-\(n)")", isDirectory: true)
            return TakeInfo(folder: folder, title: title ?? video, videoTitle: video, number: title == nil ? n : nil,
                            renamed: title != nil, date: date, duration: length, bytes: bytes, hasCamera: camera,
                            hasScreen: screen, finished: finished, lastWrite: date, writing: writing)
        }
        let takes = [
            take(1, "Brand Registry in ten minutes", nil, now.addingTimeInterval(-6 * 60), nil, 410_000_000, finished: false, writing: true),
            take(3, "How to fix a suppressed listing", nil, at(daysAgo: 0, 11, 42), 761, 2 * gb + 310_000_000, finished: true),
            take(2, "How to fix a suppressed listing", nil, at(daysAgo: 0, 11, 18), 185, 486_000_000, finished: false, camera: false),
            take(1, "How to fix a suppressed listing", "Intro, the good one", at(daysAgo: 0, 10, 55), 94, 233_000_000, finished: true),
            take(1, "Why your Buy Box disappeared", nil, at(daysAgo: 1, 16, 5), 922, 2 * gb + 840_000_000, finished: true),
            take(2, "Reading the Account Health page", nil, at(daysAgo: 3, 12, 30), 655, gb + 920_000_000, finished: true),
            take(1, "Reading the Account Health page", nil, at(daysAgo: 3, 11, 50), 48, 151_000_000, finished: false),
            take(1, "Stranded inventory, explained", nil, at(daysAgo: 9, 15, 10), 1_034, 3 * gb + 120_000_000, finished: true),
            take(1, "FBA fees in 2026", nil, at(daysAgo: 16, 10, 0), 702, 2 * gb + 50_000_000, finished: true),
        ]
        for (i, t) in takes.enumerated() where t.hasCamera || t.hasScreen {
            guard !t.writing, let image = SampleFrame.image(seed: i, screen: !t.hasCamera) else { continue }
            TakeThumbnails.shared.put(image, for: t.id)
        }
        return RecordingsModel(staged: takes, held: [takes[0].id: .recording], filter: filter, search: search, notice: notice)
    }
}

/// Placeholder frames for snapshots: a figure against a softly lit wall, or a slide.
private enum SampleFrame {
    @MainActor
    static func image(seed: Int, screen: Bool) -> NSImage? {
        let walls: [(UInt32, UInt32)] = [(0x3B4A44, 0x1A211E), (0x4A4038, 0x1E1915), (0x2F3D47, 0x141A1F),
                                         (0x45463A, 0x1B1C16), (0x3E3446, 0x18141C), (0x34463F, 0x141C19)]
        let (top, bottom) = walls[seed % walls.count]
        let shift = CGFloat((seed * 37) % 60) - 30
        let view = ZStack {
            if screen {
                Color(hex: 0xE9ECEA)
                VStack(alignment: .leading, spacing: 18) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x23302A)).frame(width: 330, height: 26)
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 12) {
                            Circle().fill(Color(hex: 0x3DCC80)).frame(width: 10, height: 10)
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x9AA39E)).frame(width: CGFloat(300 - row * 40), height: 12)
                        }
                    }
                }
                .padding(56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .topTrailing, endPoint: .bottomLeading)
                Ellipse().fill(Color.white.opacity(0.10)).frame(width: 260, height: 300).blur(radius: 50).offset(x: 190, y: -110)
                // Head and shoulders, soft, a little off centre.
                VStack(spacing: -6) {
                    Ellipse().fill(Color(hex: 0x8C6E5C)).frame(width: 92, height: 112)
                    RoundedRectangle(cornerRadius: 90, style: .continuous).fill(Color(hex: 0x1F2A33)).frame(width: 300, height: 170)
                }
                .offset(x: -40 + shift, y: 92)
                .blur(radius: 2.5)
            }
        }
        .frame(width: 640, height: 360)
        .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        // A plain bitmap: an NSImage straight from the renderer draws nothing once the renderer is gone.
        guard let cg = renderer.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
