import Foundation

// Checks the face framing rules (Sources/vidlark-finish/Framing.swift) on made-up face tracks.
// Run by Tests/framing/run.sh. UPDATE_GOLDEN=1 rewrites the expected paths in fixtures/*.path.json,
// which the Windows port can compare its own paths against.

@main
struct Check {
    static var passed = 0
    static var failed = 0

    static func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ok    \(what)") } else { failed += 1; print("  FAIL  \(what)\(detail.isEmpty ? "" : ": \(detail)")") }
    }

    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let update = ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1"

        /// The path for a fixture, as video.mp4 would crop it: a 4:3 video from a 16:9 camera has room to
        /// move across; a 16:10 video from a tall phone has room up and down.
        func path(_ name: String, canvas: Double) -> (CropPath, FaceTrack) {
            let track = FaceTrack(json: try! Data(contentsOf: dir.appendingPathComponent("\(name).faces.json")))!
            let fill = fillCrop(pictureAspect: track.aspect, canvasAspect: canvas)
            let p = framePath(track.looks, width: track.width, height: track.height, crop: (fill.w, fill.h), home: fill.home)
            let golden = dir.appendingPathComponent("\(name).path.json")
            if update { try! p.json().write(to: golden, atomically: true, encoding: .utf8) }
            let expected = (try? String(contentsOf: golden, encoding: .utf8)) ?? ""
            check("\(name): path matches \(name).path.json", p.json() == expected, "run with UPDATE_GOLDEN=1 after a deliberate change")
            return (p, track)
        }
        /// The steepest part of the easing curve, in progress per unit of time.
        let steepest = (0..<1000).map { (glideEase(Double($0 + 1) / 1000) - glideEase(Double($0) / 1000)) * 1000 }.max()!
        /// Every frame at 30 a second: inside the picture, moving only during a glide and never faster
        /// than that glide's steepest moment, so nothing ever jumps.
        func smooth(_ name: String, _ p: CropPath, seconds: Double) {
            var inside = true, jumps = 0, last = p.at(0)
            for f in 1...Int(seconds * 30) {
                let t0 = Double(f - 1) / 30, t1 = Double(f) / 30
                let c = p.at(t1)
                inside = inside && c.x >= -1e-9 && c.y >= -1e-9 && c.x <= 1 - p.width + 1e-9 && c.y <= 1 - p.height + 1e-9
                let step = hypot(c.x - last.x, c.y - last.y)
                let allowed = p.moves.filter { $0.t < t1 && $0.t + $0.d > t0 }
                    .reduce(0.0) { $0 + hypot($1.to.x - $1.from.x, $1.to.y - $1.from.y) * steepest / ($1.d * 30) }
                if step > allowed * 1.01 + 1e-9 { jumps += 1 }
                last = c
            }
            check("\(name): the crop stays inside the picture", inside)
            check("\(name): every frame on a glide's curve, no jumps", jumps == 0, "\(jumps) frames jumped")
        }
        func faceCentre(_ track: FaceTrack, at t: Double) -> Double? {
            track.looks.last { $0.t <= t && !$0.faces.isEmpty }.map { $0.faces[0].midX }
        }
        let wide = 4.0 / 3.0

        print("== still")
        do {
            let (p, track) = path("still", canvas: wide)
            check("still: framed on her face from the first frame", abs(p.start.x + p.width / 2 - 0.42) < 0.01, "start \(p.start)")
            check("still: never moves", p.moves.isEmpty, "\(p.moves.count) moves")
            smooth("still", p, seconds: track.duration)
        }

        print("== drift")
        do {
            let (p, track) = path("drift", canvas: wide)
            check("drift: a few calm glides, not a constant follow (\(p.moves.count))", (2...8).contains(p.moves.count))
            check("drift: every glide is the calm 0.9 s one", p.moves.allSatisfy { $0.d == FramingRules.glide })
            let gaps = zip(p.moves.dropFirst(), p.moves).map { $0.t - ($1.t + $1.d) }
            check("drift: holds still between glides (shortest hold \(String(format: "%.1f", gaps.min() ?? 99)) s)", (gaps.min() ?? 99) >= 2)
            let end = p.at(track.duration), face = faceCentre(track, at: track.duration)!
            check("drift: ends with her face near the middle", abs(end.x + p.width / 2 - face) < 0.08, "crop middle \(end.x + p.width / 2), face \(face)")
            smooth("drift", p, seconds: track.duration)
        }

        print("== jump")
        do {
            let (p, track) = path("jump", canvas: wide)
            check("jump: exactly one move", p.moves.count == 1, "\(p.moves.count) moves")
            if let move = p.moves.first {
                check("jump: it starts within a look of the jump (\(move.t) s)", move.t >= 10 && move.t <= 10.2)
                check("jump: the calm 0.9 s glide", move.d == FramingRules.glide)
                check("jump: ends as far right as the picture allows", abs(move.to.x - (1 - p.width)) < 1e-9, "\(move.to)")
            }
            check("jump: held still before it", p.at(9.9) == p.start)
            smooth("jump", p, seconds: track.duration)
        }

        print("== edge")
        do {
            let (p, track) = path("edge", canvas: wide)
            check("edge: follows within the walk (first move at \(p.moves.first?.t ?? -1) s)", (p.moves.first?.t ?? 0) > 10 && (p.moves.first?.t ?? 99) < 11.2)
            check("edge: every glide the calm one", p.moves.allSatisfy { $0.d == FramingRules.glide })
            check("edge: at most three moves (\(p.moves.count))", p.moves.count <= 3)
            let end = p.at(track.duration)
            check("edge: ends with her in frame, near the middle", abs(end.x + p.width / 2 - 0.70) < 0.08, "crop middle \(end.x + p.width / 2)")
            smooth("edge", p, seconds: track.duration)
        }

        print("== lost")
        do {
            let (p, track) = path("lost", canvas: wide)
            check("lost: holds through 8 s with no face, and after", p.moves.isEmpty, "\(p.moves.count) moves")
            smooth("lost", p, seconds: track.duration)
        }

        print("== gone")
        do {
            let (p, track) = path("gone", canvas: wide)
            check("gone: two moves, home and back to her (\(p.moves.count))", p.moves.count == 2)
            if p.moves.count == 2 {
                check("gone: holds 12 s, then glides home (at \(p.moves[0].t) s)", abs(p.moves[0].t - 22) < 0.2 && p.moves[0].to == p.home)
                check("gone: glides to her within a second of her coming back (at \(p.moves[1].t) s)", p.moves[1].t >= 30 && p.moves[1].t <= 31)
                check("gone: ends centred on her", abs(p.moves[1].to.x + p.width / 2 - 0.62) < 0.02, "\(p.moves[1].to)")
            }
            smooth("gone", p, seconds: track.duration)
        }

        print("== two faces")
        do {
            let picks = presenterFaces(FaceTrack(json: try! Data(contentsOf: dir.appendingPathComponent("two.faces.json")))!.looks, aspect: 16.0 / 9)
            check("two: her face is picked in every look, the passer-by never", picks.allSatisfy { $0?.index == 0 })
            let (p, track) = path("two", canvas: wide)
            check("two: never moves", p.moves.isEmpty, "\(p.moves.count) moves")
            check("two: framed on her", abs(p.start.x + p.width / 2 - 0.40) < 0.01, "\(p.start)")
            smooth("two", p, seconds: track.duration)
        }

        print("== tall phone")
        do {
            let (p, track) = path("tall", canvas: 16.0 / 10)
            check("tall: the crop is the full width, a band of the height", p.width == 1 && abs(p.height - 0.3516) < 0.001)
            check("tall: one move, straight down", p.moves.count == 1 && p.moves.allSatisfy { $0.to.x == 0 && $0.to.y > $0.from.y })
            check("tall: her face sits a little above the middle after it",
                  abs((0.50 - p.at(track.duration).y) / p.height - FramingRules.restY) < 0.03, "\(p.at(track.duration))")
            smooth("tall", p, seconds: track.duration)
        }

        print("== nobody")
        do {
            let fill = fillCrop(pictureAspect: 16.0 / 9, canvasAspect: wide)
            let looks = (0..<120).map { FaceLook(t: Double($0) / 6, faces: []) }
            let p = framePath(looks, width: 1920, height: 1080, crop: (fill.w, fill.h), home: fill.home)
            check("nobody: the crop stays home, as before framing", p.still && p.start == fill.home)
            check("nobody: home is the old crop, centred across and 0.4 down", fill.home.x == 0.125 && fill.home.y == 0)
            let tall = fillCrop(pictureAspect: 9.0 / 16, canvasAspect: 1.6)
            check("nobody: a tall picture's home is 0.4 of the way down its spare height", abs(tall.home.y - (1 - tall.h) * 0.4) < 1e-12 && tall.home.x == 0)
        }

        print("== easing")
        do {
            check("ease: 0 and 1 at the ends", glideEase(0) == 0 && glideEase(1) == 1)
            check("ease: the face box's curve, past half way at half time (\(String(format: "%.3f", glideEase(0.5))))", abs(glideEase(0.5) - 0.7294) < 0.001)
            var rising = true
            for i in 1...100 { rising = rising && glideEase(Double(i) / 100) >= glideEase(Double(i - 1) / 100) }
            check("ease: never goes back", rising)
            check("ease: starts gently (a tenth of the time, under a twentieth of the way)", glideEase(0.1) < 0.05)
        }

        print("== where the video shows the camera")
        do {
            let shows = [ShowChange(t: 0, screen: false), ShowChange(t: 32, screen: true), ShowChange(t: 40, screen: false), ShowChange(t: 50, screen: true)]
            let framed = cameraStretches(end: 56.7, screenFrom: 20, screenTo: 56.7, cut: 20.3, shows: shows, meToo: true)
            let want = [CameraStretch(from: 0, to: 31.7, fadeIn: 0, fadeOut: 0.3, homeAtStart: false, homeAtEnd: true),
                        CameraStretch(from: 40.9, to: 49.7, fadeIn: 0.3, fadeOut: 0.3, homeAtStart: true, homeAtEnd: true)]
            check("stretches: the opening carries on through Me in screen.mov, and the later Me is its own", close(framed, want), "\(framed)")
            let plain = cameraStretches(end: 56.7, screenFrom: 20, screenTo: 56.7, cut: 20.3, shows: shows, meToo: false)
            check("stretches: without Me, only the opening, home before the share",
                  close(plain, [CameraStretch(from: 0, to: 20.55, fadeIn: 0, fadeOut: 0.25, homeAtStart: false, homeAtEnd: true)]), "\(plain)")
            let none = cameraStretches(end: 45, screenFrom: 0, screenTo: 45, cut: 0, shows: [], meToo: false)
            check("stretches: a screen from the start with no Me shows no camera", none.isEmpty)
            let fromStart = cameraStretches(end: 45, screenFrom: 0.05, screenTo: 45, cut: 0,
                                            shows: [ShowChange(t: 0, screen: false), ShowChange(t: 20, screen: true)], meToo: true)
            check("stretches: a take on Me with the screen from the start is framed from just after its first picture",
                  close(fromStart, [CameraStretch(from: 0.95, to: 19.7, fadeIn: 0.3, fadeOut: 0.3, homeAtStart: true, homeAtEnd: true)]), "\(fromStart)")
            let short = cameraStretches(end: 60, screenFrom: 0, screenTo: 60, cut: 0,
                                        shows: [ShowChange(t: 0, screen: true), ShowChange(t: 10, screen: false), ShowChange(t: 12, screen: true)], meToo: true)
            check("stretches: a Me of 2 s is left to screen.mov", short.isEmpty, "\(short)")
            let later = [ShowChange(t: 0, screen: false), ShowChange(t: 32, screen: true), ShowChange(t: 45, screen: false), ShowChange(t: 50, screen: true)]
            let spans = framingSpans(end: 56.7, shared: 19.6, cameraFirst: true, shows: later)
            check("spans: the opening through the first Screen, and the later Me, with room either side", spans == [[0, 35], [42, 53]], "\(spans)")
            check("spans: none for a screen from the start with no Me", framingSpans(end: 45, shared: nil, cameraFirst: false, shows: [ShowChange(t: 0, screen: true)]).isEmpty)
            let path = CropPath(width: 0.75, height: 1, home: CropPoint(x: 0.125, y: 0), start: CropPoint(x: 0, y: 0), moves: [])
            let me = want[1]
            check("blend: at home where the camera fades in and out",
                  framedCrop(path, at: me.from + me.fadeIn, in: me) == path.home && framedCrop(path, at: me.to - me.fadeOut, in: me) == path.home)
            check("blend: on her face a glide after that", framedCrop(path, at: me.from + me.fadeIn + FramingRules.glide, in: me) == path.start)
        }

        print("== faces.json")
        do {
            let track = FaceTrack(width: 1920, height: 1080, duration: 2, looksPerSecond: 6, spans: [[0, 2]],
                                  looks: [FaceLook(t: 0, faces: [FaceBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4)]), FaceLook(t: 0.167, faces: [])])
            check("faces.json: reads back what it wrote", FaceTrack(json: track.json().data(using: .utf8)!) == track)
        }

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func close(_ a: [CameraStretch], _ b: [CameraStretch]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            abs(x.from - y.from) < 1e-6 && abs(x.to - y.to) < 1e-6 && abs(x.fadeIn - y.fadeIn) < 1e-6 && abs(x.fadeOut - y.fadeOut) < 1e-6
                && x.homeAtStart == y.homeAtStart && x.homeAtEnd == y.homeAtEnd
        }
    }
}
