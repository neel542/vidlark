import Foundation

// Face framing for video.mp4. Wherever the finished video shows camera.mov across the whole frame,
// the camera picture is cropped to the video's shape, and the crop follows her face the way a camera
// operator would: still while she talks, gestures or leans, and one smooth glide once she has really
// moved. These are the face box's rules (FaceTracker in RecordingPill.swift), worked out after the
// take from faces.json instead of live, for a crop of fixed size.
//
// Plain arithmetic only, no Apple frameworks: faces in, crop moves out. The Windows finisher can port
// it line by line and check itself against the same fixtures (Tests/framing).

/// One face, normalised to the upright camera picture, origin top left.
struct FaceBox: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }
    var area: Double { w * h }
}

/// One look at the picture at `t` seconds (camera time). An empty list means nobody was found.
struct FaceLook: Equatable {
    var t: Double
    var faces: [FaceBox]
}

/// What faces.json holds: every look at camera.mov's picture and the faces in it.
struct FaceTrack: Equatable {
    var file = "camera.mov"
    /// The upright picture in pixels.
    var width: Int
    var height: Int
    var duration: Double
    var looksPerSecond: Double
    /// The stretches of camera time that were looked at, from and to. Nothing is known outside them.
    var spans: [[Double]]
    var looks: [FaceLook]

    var aspect: Double { Double(width) / Double(max(height, 1)) }
}

/// The top left corner of the crop, normalised to the picture.
struct CropPoint: Equatable {
    var x: Double
    var y: Double
}

/// One glide of the crop: from `from` at `t` to `to` at `t + d`, eased with `glideEase`.
struct CropMove: Equatable {
    var t: Double
    var d: Double
    var from: CropPoint
    var to: CropPoint
}

/// A crop of fixed size moving over the picture: `start` until the first move, then each move in
/// turn. A move that starts before the one before it has finished takes over from wherever the crop
/// is at that moment.
struct CropPath: Equatable {
    /// The crop's size, normalised to the picture.
    var width: Double
    var height: Double
    /// Where the crop sits with no face to follow.
    var home: CropPoint
    var start: CropPoint
    var moves: [CropMove]

    func at(_ t: Double) -> CropPoint {
        guard let move = moves.last(where: { $0.t <= t }) else { return start }
        let u = move.d <= 0 ? 1 : glideEase((t - move.t) / move.d)
        return CropPoint(x: move.from.x + (move.to.x - move.from.x) * u, y: move.from.y + (move.to.y - move.from.y) * u)
    }

    /// No face anywhere: the crop never leaves home.
    var still: Bool { start == home && moves.allSatisfy { $0.to == home } }
}

/// The rules, in one place so the Windows port uses the same numbers.
enum FramingRules {
    /// Her face, smoothed: a third of the way to each new look, so the detector's own wobble never counts as a move.
    static let smoothing = 0.35
    /// How far her face may wander from where it rests in the frame before the frame follows, as a
    /// share of a head and shoulders frame (2.8 face heights): across, and up or down. A frame wider
    /// than that uses the head and shoulders measure, so the margin is about half a face either way.
    static let marginAcross = 0.17
    static let marginUpDown = 0.15
    static let headAndShoulders = 2.8
    /// Her face within a tenth of the frame's edge cannot wait.
    static let edgeInset = 0.10
    /// A gesture or a lean comes back by itself: out of the margin this long before the frame follows.
    static let driftWait = 0.7
    /// How long a glide takes. The face box glides in half that when her face nears its edge, because
    /// its zoomed frame loses her quickly; the video's frame is far wider, so every glide is the calm
    /// one and only the start comes sooner.
    static let glide = 0.9
    /// A move shorter than this share of the frame's width is no move at all.
    static let minShift = 0.05
    /// Nobody found for this long: the frame glides back home.
    static let lostHome = 12.0
    /// Where her face rests in the frame: across, and down from the top. A little above the middle.
    static let restX = 0.5
    static let restY = 0.4
    /// Looks further apart than this start afresh (a stretch of the take that was not looked at).
    static let freshAfter = 2.0
    /// At the start of a stretch, a face found this soon sets the frame straight away.
    static let firstFaceWithin = 2.0
    /// The same face from one look to the next: centres within this many face heights, size within this ratio,
    /// and seen within `freshAfter` seconds.
    static let linkDistance = 1.0
    static let linkSize = 2.0
    /// The face followed so far keeps the frame while its total size over time is at least this share of
    /// the strongest face in the picture.
    static let keepShare = 0.5
}

// MARK: - The presenter

/// Which face is hers in each look: its index in `faces` and the track it belongs to, or nil.
/// Faces are linked from look to look into tracks; a track's weight is its size added up over every
/// look it is in, so the largest face that stays longest wins. The face followed so far keeps the
/// frame while its track weighs at least half the heaviest one in the picture, so someone passing
/// behind her, or close to the lens for a moment, never takes the frame.
func presenterFaces(_ looks: [FaceLook], aspect: Double) -> [(index: Int, track: Int)?] {
    struct Track { var last: FaceBox; var lastT: Double; var weight: Double }
    var tracks: [Track] = []
    var linked: [[Int]] = []
    for look in looks {
        var pairs: [(face: Int, track: Int, cost: Double)] = []
        for (f, face) in look.faces.enumerated() {
            for (k, track) in tracks.enumerated() where look.t - track.lastT <= FramingRules.freshAfter && look.t > track.lastT {
                let size = max(face.h, track.last.h) / max(min(face.h, track.last.h), 1e-6)
                guard size <= FramingRules.linkSize else { continue }
                let distance = hypot((face.midX - track.last.midX) * aspect, face.midY - track.last.midY) / max(face.h, track.last.h, 1e-6)
                if distance <= FramingRules.linkDistance { pairs.append((f, k, distance)) }
            }
        }
        var ids = Array(repeating: -1, count: look.faces.count)
        var taken = Set<Int>()
        for pair in pairs.sorted(by: { $0.cost < $1.cost }) where ids[pair.face] < 0 && !taken.contains(pair.track) {
            ids[pair.face] = pair.track
            taken.insert(pair.track)
        }
        for (f, face) in look.faces.enumerated() {
            if ids[f] < 0 {
                ids[f] = tracks.count
                tracks.append(Track(last: face, lastT: look.t, weight: 0))
            }
            tracks[ids[f]].last = face
            tracks[ids[f]].lastT = look.t
            tracks[ids[f]].weight += face.area
        }
        linked.append(ids)
    }
    // With every track weighed over the whole take, pick hers in each look.
    var followed: Int?
    var result: [(index: Int, track: Int)?] = []
    for (look, ids) in zip(looks, linked) {
        guard !ids.isEmpty else { result.append(nil); continue }
        let heaviest = ids.indices.max { a, b in
            let wa = tracks[ids[a]].weight, wb = tracks[ids[b]].weight
            return wa == wb ? look.faces[a].area < look.faces[b].area : wa < wb
        }!
        var pick = heaviest
        if let followed, let mine = ids.firstIndex(of: followed),
           tracks[followed].weight >= tracks[ids[heaviest]].weight * FramingRules.keepShare {
            pick = mine
        }
        followed = ids[pick]
        result.append((pick, ids[pick]))
    }
    return result
}

// MARK: - The path

/// Where the crop should sit to frame `face`: her face at the rest spot, kept inside the picture.
/// `width` and `height` are the picture in pixels; the crop's size is normalised.
private func framing(_ face: FaceBox, crop: (w: Double, h: Double), width: Double, height: Double) -> CropPoint {
    let x = face.midX - FramingRules.restX * crop.w
    let y = face.midY - FramingRules.restY * crop.h
    return CropPoint(x: min(max(x, 0), 1 - crop.w), y: min(max(y, 0), 1 - crop.h))
}

/// The camera operator, after the fact: faces in, crop moves out.
/// - `looks`: every look, in time order (faces.json).
/// - `width`, `height`: the upright picture in pixels.
/// - `crop`: the crop's size, normalised to the picture. Its position is what moves.
/// - `home`: where the crop sits when there is no face to follow.
func framePath(_ looks: [FaceLook], width: Int, height: Int, crop: (w: Double, h: Double), home: CropPoint) -> CropPath {
    let W = Double(width), H = Double(height)
    let aspect = W / max(H, 1)
    var path = CropPath(width: crop.w, height: crop.h, home: home, start: home, moves: [])
    let picks = presenterFaces(looks, aspect: aspect)

    // Stretches of looks with no long gap; each starts afresh.
    var runs: [Range<Int>] = []
    var from = 0
    for i in looks.indices where i > 0 && looks[i].t - looks[i - 1].t > FramingRules.freshAfter {
        runs.append(from..<i)
        from = i
    }
    if !looks.isEmpty { runs.append(from..<looks.count) }

    var goal = home
    func glide(at t: Double, to target: CropPoint, seconds: Double) {
        path.moves.append(CropMove(t: t, d: seconds, from: path.at(t), to: target))
        goal = target
    }

    for (n, run) in runs.enumerated() {
        let runStart = looks[run.lowerBound].t
        // A face found straight away sets the frame from the start of the stretch.
        let first = run.first { i in looks[i].t - runStart <= FramingRules.firstFaceWithin && picks[i] != nil }
        let opening = first.map { framing(looks[$0].faces[picks[$0]!.index], crop: crop, width: W, height: H) } ?? home
        if n == 0 {
            path.start = opening
            goal = opening
        } else if opening != goal {
            // A stretch that was not looked at: the crop is out of sight there, and glides to her
            // well before it shows again.
            glide(at: runStart, to: opening, seconds: FramingRules.glide)
        }

        var steady: FaceBox?
        var steadyTrack = -1
        var lostSince: Double?
        var awaySince: Double?
        for i in run {
            let t = looks[i].t
            guard let pick = picks[i] else {
                let since = lostSince ?? t
                lostSince = since
                awaySince = nil
                // Looking down, turned away, or hidden behind what she is showing: hold. Only after a
                // long while with nobody there does the frame go back home.
                if t - since >= FramingRules.lostHome, goal != home { glide(at: t, to: home, seconds: FramingRules.glide) }
                continue
            }
            lostSince = nil
            let box = looks[i].faces[pick.index]
            // Smooth the face itself; a different person starts a new smoothing.
            if let old = steady, steadyTrack == pick.track {
                let k = FramingRules.smoothing
                steady = FaceBox(x: old.x + (box.x - old.x) * k, y: old.y + (box.y - old.y) * k,
                                 w: old.w + (box.w - old.w) * k, h: old.h + (box.h - old.h) * k)
            } else {
                steady = box
            }
            steadyTrack = pick.track
            let face = steady!
            let ideal = framing(face, crop: crop, width: W, height: H)

            // Where her face sits in the frame now, against where it rests in an ideal frame.
            let nowX = (face.midX - goal.x) / crop.w, nowY = (face.midY - goal.y) / crop.h
            let restX = (face.midX - ideal.x) / crop.w, restY = (face.midY - ideal.y) / crop.h
            let measure = FramingRules.headAndShoulders * face.h * H
            let marginX = FramingRules.marginAcross * min(crop.w * W, measure) / (crop.w * W)
            let marginY = FramingRules.marginUpDown * min(crop.h * H, measure) / (crop.h * H)
            let drifted = abs(nowX - restX) > marginX || abs(nowY - restY) > marginY
            // Her face nearing the frame's edge is judged on the face as seen this moment, not the
            // smoothed one, which trails a quick move. A face too big to fit inside the frame's inner
            // part (a close-up cropped to a wide video) is always near an edge that way, so it counts
            // only by its middle then.
            let insetX = crop.w * FramingRules.edgeInset, insetY = crop.h * FramingRules.edgeInset
            let fitsX = box.w <= crop.w - 2 * insetX, fitsY = box.h <= crop.h - 2 * insetY
            let edgeX = fitsX ? box.x < goal.x + insetX || box.x + box.w > goal.x + crop.w - insetX
                              : box.midX < goal.x + insetX || box.midX > goal.x + crop.w - insetX
            let edgeY = fitsY ? box.y < goal.y + insetY || box.y + box.h > goal.y + crop.h - insetY
                              : box.midY < goal.y + insetY || box.midY > goal.y + crop.h - insetY
            let edge = edgeX || edgeY

            guard drifted || edge else {
                awaySince = nil
                continue
            }
            let since = awaySince ?? t
            awaySince = since
            guard t - since >= (edge ? 0 : FramingRules.driftWait) else { continue }
            // Centre her again; heading for the edge, follow where she is now, without waiting.
            let next = edge ? framing(box, crop: crop, width: W, height: H) : ideal
            // Up against the edge of the picture the frame cannot go further, so a move that would
            // barely shift it is no move at all.
            let shift = hypot((next.x - goal.x) * W, (next.y - goal.y) * H) / (crop.w * W)
            awaySince = nil
            guard shift > FramingRules.minShift else { continue }
            glide(at: t, to: next, seconds: FramingRules.glide)
            // Followed to where she is now: the smoothing starts there too, so its trail does not
            // ask for a second, small move straight after.
            if edge { steady = box }
        }
    }
    return path
}

/// The face box's easing, cubic-bezier(0.45, 0, 0.25, 1): starts gently and settles softly, like a
/// hand on a tripod head. `u` from 0 to 1, clamped.
func glideEase(_ u: Double) -> Double {
    if u <= 0 { return 0 }
    if u >= 1 { return 1 }
    let (x1, y1, x2, y2) = (0.45, 0.0, 0.25, 1.0)
    func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
        3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
    }
    // Find s where x(s) = u by halving: x rises from 0 to 1, so this always lands.
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 {
        let mid = (lo + hi) / 2
        if bezier(mid, x1, x2) < u { lo = mid } else { hi = mid }
    }
    return bezier((lo + hi) / 2, y1, y2)
}

// MARK: - Where the video shows the camera

/// One click of Me or Screen, in camera time.
struct ShowChange {
    var t: Double
    var screen: Bool
}

/// A stretch of video.mp4 that shows camera.mov across the whole frame, in camera time.
struct CameraStretch: Equatable {
    var from: Double
    var to: Double
    /// Seconds the camera takes to fade in from `from`, and to fade out by `to`. 0 is a cut.
    var fadeIn: Double
    var fadeOut: Double
    /// At this end the camera meets screen.mov while it shows her camera across the screen, cropped
    /// at home. The crop is at home there and eases to her face (or back) over a glide.
    var homeAtStart: Bool
    var homeAtEnd: Bool
}

enum StretchTimes {
    /// How long the change from camera.mov to screen.mov takes when the screen is shared.
    static let handover = 0.25
    /// After a click of Me, the stage grows for 0.5 s; the camera fades in once it has surely filled
    /// the screen, with room for the event clock being a moment off.
    static let afterMe = 0.9
    static let fade = 0.3
    /// Before a click of Screen, the camera has faded out this long before it, so the shrink is never covered.
    static let beforeScreen = 0.3
    /// A Me stretch shorter than this is left as screen.mov has it.
    static let shortest = 2.0
}

/// Where video.mp4 shows camera.mov, given when screen.mov has pictures (`screenFrom` to `screenTo`),
/// when the video changes to it (`cut`, 0 when the screen is there from the start) and the clicks of
/// Me and Screen. With `meToo`, every Me stretch inside screen.mov is shown from camera.mov as well,
/// so the crop can follow her face there too; screen.mov holds her camera at home in those stretches,
/// and each end meets it at home.
func cameraStretches(end: Double, screenFrom: Double, screenTo: Double, cut: Double, shows: [ShowChange], meToo: Bool) -> [CameraStretch] {
    let changes = shows.sorted { $0.t < $1.t }
    func showingCamera(_ t: Double) -> Bool {
        guard let last = changes.last(where: { $0.t <= t + 0.001 }) else { return false }
        return !last.screen
    }
    /// The first click of Screen after `t`, or nil when the camera shows until the screen stops.
    func nextScreen(after t: Double) -> Double? {
        changes.first { $0.t > t + 0.001 && $0.screen }?.t
    }
    var out: [CameraStretch] = []
    // The camera-first opening, until the screen has faded in.
    if cut > 0 {
        var opening = CameraStretch(from: 0, to: min(end, cut + StretchTimes.handover), fadeIn: 0, fadeOut: StretchTimes.handover,
                                    homeAtStart: false, homeAtEnd: showingCamera(cut))
        if meToo, showingCamera(cut) {
            // screen.mov opens on her camera at home: the opening carries on through it.
            if let click = nextScreen(after: cut) {
                let to = click - StretchTimes.beforeScreen
                if to - StretchTimes.fade > opening.to { opening.to = to; opening.fadeOut = StretchTimes.fade }
            } else {
                opening.to = end
                opening.fadeOut = 0
                opening.homeAtEnd = false
            }
        }
        out.append(opening)
    }
    // Each Me inside screen.mov.
    if meToo {
        // A camera-first take's Me before the share belongs to the opening. With the screen there from
        // the start, a take that starts on Me has her camera across screen.mov from its first picture.
        for change in changes where !change.screen && (cut == 0 || change.t >= cut) {
            // A second Me while Me shows changes nothing.
            if let before = changes.last(where: { $0.t < change.t }), !before.screen { continue }
            let from = max(change.t, screenFrom) + StretchTimes.afterMe
            var stretch = CameraStretch(from: from, to: end, fadeIn: StretchTimes.fade, fadeOut: 0, homeAtStart: true, homeAtEnd: false)
            if let click = nextScreen(after: change.t) {
                stretch.to = click - StretchTimes.beforeScreen
                stretch.fadeOut = StretchTimes.fade
                stretch.homeAtEnd = true
            } else if screenTo < end - 0.05 {
                stretch.to = end
            }
            guard stretch.to - stretch.fadeOut - (stretch.from + stretch.fadeIn) >= StretchTimes.shortest else { continue }
            out.append(stretch)
        }
    }
    // The screen stopping a moment before the camera: the camera covers the last moment.
    if screenTo < end - 0.05, cut == 0 || screenTo > cut {
        out.append(CameraStretch(from: screenTo, to: end, fadeIn: 0, fadeOut: 0, homeAtStart: false, homeAtEnd: false))
    }
    // Stretches that touch become one.
    var merged: [CameraStretch] = []
    for stretch in out.sorted(by: { $0.from < $1.from }) {
        if let last = merged.last, stretch.from <= last.to + 0.001 {
            if stretch.to > last.to {
                merged[merged.count - 1].to = stretch.to
                merged[merged.count - 1].fadeOut = stretch.fadeOut
                merged[merged.count - 1].homeAtEnd = stretch.homeAtEnd
            }
        } else {
            merged.append(stretch)
        }
    }
    return merged
}

/// The crop at `t` inside `stretch`: the path, eased in from home after an end that meets screen.mov
/// at home, and back home before one.
func framedCrop(_ path: CropPath, at t: Double, in stretch: CameraStretch) -> CropPoint {
    var weight = 1.0
    if stretch.homeAtStart { weight = min(weight, glideEase((t - stretch.from - stretch.fadeIn) / FramingRules.glide)) }
    if stretch.homeAtEnd { weight = min(weight, glideEase((stretch.to - stretch.fadeOut - t) / FramingRules.glide)) }
    let p = path.at(t), home = path.home
    return CropPoint(x: home.x + (p.x - home.x) * weight, y: home.y + (p.y - home.y) * weight)
}

/// The fill crop: the largest part of the picture with the video's shape (`canvasAspect`, width over
/// height), normalised, and its home, a little above the middle as before framing.
func fillCrop(pictureAspect: Double, canvasAspect: Double) -> (w: Double, h: Double, home: CropPoint) {
    let w = min(1, canvasAspect / pictureAspect)
    let h = min(1, pictureAspect / canvasAspect)
    return (w, h, CropPoint(x: (1 - w) / 2, y: (1 - h) * 0.4))
}

/// The camera times a framed video needs looked at, from events alone (before the screen is lined up):
/// the opening until a little after the share, and every stretch the video shows Me, with a few
/// seconds either side.
func framingSpans(end: Double, shared: Double?, cameraFirst: Bool, shows: [ShowChange]) -> [[Double]] {
    let pad = 3.0
    var spans: [[Double]] = []
    if cameraFirst || shared != nil { spans.append([0, (shared ?? end) + 4]) }
    let changes = shows.sorted { $0.t < $1.t }
    for (i, change) in changes.enumerated() where !change.screen {
        let until = changes[(i + 1)...].first { $0.screen }?.t ?? end
        spans.append([change.t - pad, until + pad])
    }
    var merged: [[Double]] = []
    for span in spans.map({ [max(0, $0[0]), min(end, $0[1])] }).filter({ $0[1] > $0[0] }).sorted(by: { $0[0] < $1[0] }) {
        if let last = merged.last, span[0] <= last[1] + FramingRules.freshAfter {
            merged[merged.count - 1][1] = max(last[1], span[1])
        } else {
            merged.append(span)
        }
    }
    return merged
}

// MARK: - faces.json

extension FaceTrack {
    func json() -> String {
        func n(_ v: Double, _ places: Int) -> String {
            let text = String(format: "%.\(places)f", v)
            return Double(text) == 0 ? String(format: "%.\(places)f", 0.0) : text
        }
        var out = "{\"version\":1,\"file\":\"\(file)\",\"width\":\(width),\"height\":\(height),\"duration\":\(n(duration, 3)),"
        out += "\"looksPerSecond\":\(n(looksPerSecond, 2)),\"origin\":\"top-left\","
        out += "\"spans\":[" + spans.map { "[\(n($0[0], 3)),\(n($0[1], 3))]" }.joined(separator: ",") + "],\n\"looks\":[\n"
        out += looks.map { look in
            "{\"t\":\(n(look.t, 3)),\"faces\":[" + look.faces.map { "[\(n($0.x, 4)),\(n($0.y, 4)),\(n($0.w, 4)),\(n($0.h, 4))]" }.joined(separator: ",") + "]}"
        }.joined(separator: ",\n")
        return out + "\n]}\n"
    }

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = (object["width"] as? NSNumber)?.intValue, let height = (object["height"] as? NSNumber)?.intValue,
              let looks = object["looks"] as? [[String: Any]] else { return nil }
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        self.width = width
        self.height = height
        file = object["file"] as? String ?? "camera.mov"
        duration = number(object["duration"]) ?? 0
        looksPerSecond = number(object["looksPerSecond"]) ?? 0
        spans = ((object["spans"] as? [[NSNumber]]) ?? []).map { $0.map(\.doubleValue) }.filter { $0.count == 2 }
        self.looks = looks.compactMap { look in
            guard let t = number(look["t"]) else { return nil }
            let faces = ((look["faces"] as? [[NSNumber]]) ?? []).compactMap { f -> FaceBox? in
                f.count >= 4 ? FaceBox(x: f[0].doubleValue, y: f[1].doubleValue, w: f[2].doubleValue, h: f[3].doubleValue) : nil
            }
            return FaceLook(t: t, faces: faces)
        }.sorted { $0.t < $1.t }
    }
}

extension CropPath {
    /// The path as JSON, for checks and for the Windows port's fixtures.
    func json() -> String {
        func n(_ v: Double) -> String { String(format: "%.5f", v) }
        func p(_ c: CropPoint) -> String { "[\(n(c.x)),\(n(c.y))]" }
        let moves = self.moves.map { "{\"t\":\(String(format: "%.3f", $0.t)),\"d\":\(String(format: "%.2f", $0.d)),\"from\":\(p($0.from)),\"to\":\(p($0.to))}" }
        return "{\"width\":\(n(width)),\"height\":\(n(height)),\"home\":\(p(home)),\"start\":\(p(start)),\n\"moves\":[\n"
            + moves.joined(separator: ",\n") + "\n]}\n"
    }
}
