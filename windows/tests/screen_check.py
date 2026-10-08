#!/usr/bin/env python3
"""Checks screen recording on a Windows machine with ffmpeg (CI).

Runs vidlark-screen-test, which records the main screen into screen.mov with the app's own screen
recorder and its stage and face bubble windows, then checks the file:
  - length, size, H.264, and two sound tracks (the mic, then the computer's sound)
  - the picture: her made-up camera (green) across the screen for Me, then in the bubble for Screen;
    a window kept out of the capture (magenta) never shows; a window let in (blue) does
  - a recording cut off by a crash can still be read
  - vidlark-finish lines it up with a camera.mov made by vidlark-writer-test and makes video.mp4

When Windows.Graphics.Capture cannot run on this machine, the screen test records a test pattern
instead and this says so plainly: the file, the sound tracks and the finisher are still checked.

usage: screen_check.py <vidlark-screen-test.exe> <vidlark-writer-test.exe> <vidlark-finish.exe>
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

SECONDS = 6


def probe(ffprobe, path):
    out = subprocess.run([ffprobe, "-v", "error", "-show_entries",
                          "format=duration:stream=index,codec_type,codec_name,width,height,channels,duration",
                          "-of", "json", path], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return json.loads(out.stdout)


def frame(ffmpeg, path, at, width, height):
    """One picture of the file at `at` seconds as rows of RGB bytes."""
    out = subprocess.run([ffmpeg, "-v", "error", "-ss", f"{at}", "-i", path, "-frames:v", "1", "-f", "rawvideo",
                          "-pix_fmt", "rgb24", "-"], capture_output=True)
    data = out.stdout
    if len(data) < width * height * 3:
        return None
    return lambda x, y: tuple(data[(int(y) * width + int(x)) * 3:(int(y) * width + int(x)) * 3 + 3])


def green(c):
    return c[1] > 140 and c[0] < 90 and c[2] < 90


def magenta(c):
    return c[0] > 170 and c[2] > 170 and c[1] < 90


def blue(c):
    return c[2] > 150 and c[0] < 70 and c[1] < 70


def run_test(test, out, seconds, *extra):
    result = subprocess.run([test, out, str(seconds), *extra], capture_output=True, text=True)
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    report = json.loads(lines[-1]) if lines else None
    return result, report


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    test, writer, finisher = (os.path.abspath(p) for p in sys.argv[1:4])
    ffmpeg = shutil.which("ffmpeg") or sys.exit("ffmpeg not found")
    ffprobe = shutil.which("ffprobe") or sys.exit("ffprobe not found")
    root = tempfile.mkdtemp(prefix="vidlark-screen-")
    failures = []

    def check(what, ok, detail=""):
        print(("  ok    " if ok else "  FAIL  ") + what + (f"  ({detail})" if detail else ""))
        if not ok:
            failures.append(what)

    take = os.path.join(root, "2026-10-08 Screen test", "recording-1")
    os.makedirs(take)
    screen = os.path.join(take, "screen.mov")
    result, report = run_test(test, screen, SECONDS)
    check("the screen test runs", result.returncode == 0 and report is not None,
          (result.stderr or result.stdout).strip()[-400:])
    if report is None:
        print(result.stdout, result.stderr)
        sys.exit(1)
    print("        " + json.dumps(report))
    captured = report["capture"] == "screen"
    if captured:
        print("        Windows.Graphics.Capture ran: this is the real screen.")
    else:
        print("        NOTE: Windows.Graphics.Capture could not run on this machine: " + report.get("why", "no reason given") + ".")
        print("        The file was made from a test pattern instead. The writer, the two sound tracks, the crash")
        print("        safety and the finisher are checked; the screen capture and the stage and bubble windows are not.")
    if report.get("problem"):
        print("        recorder said: " + report["problem"])
    if report.get("overlayProblem"):
        print("        stage and bubble said: " + report["overlayProblem"])

    info = probe(ffprobe, screen)
    check("screen.mov can be read", info is not None)
    if info:
        streams = info["streams"]
        video = [s for s in streams if s["codec_type"] == "video"]
        audio = [s for s in streams if s["codec_type"] == "audio"]
        duration = float(info["format"].get("duration", 0))
        check(f"screen.mov is {SECONDS} seconds long", abs(duration - SECONDS) < 0.5, f"{duration:.3f} s")
        check("one H.264 picture track", len(video) == 1 and video[0].get("codec_name") == "h264",
              ", ".join(s.get("codec_name", "?") for s in video))
        if video:
            w, h = video[0].get("width"), video[0].get("height")
            check(f"picture is {report['width']} x {report['height']}, at most 1920 on the long side",
                  (w, h) == (report["width"], report["height"]) and max(w, h) <= 1920, f"{w} x {h}")
        check("two sound tracks, both AAC", len(audio) == 2 and all(s.get("codec_name") == "aac" for s in audio),
              ", ".join(s.get("codec_name", "?") for s in audio))
        if len(audio) == 2:
            check("the first is the mic (one channel), the second the computer's sound (two)",
                  audio[0].get("channels") == 1 and audio[1].get("channels") == 2,
                  f"{audio[0].get('channels')} and {audio[1].get('channels')} channels")
        print(f"        {report.get('pictures')} pictures written, {report.get('newPictures')} new from the screen;"
              f" computer's sound {'heard' if report.get('hearsComputer') else 'not available here (silent track)'}")
        check("about 30 pictures a second", abs(report.get("pictures", 0) - SECONDS * 30) <= SECONDS * 3,
              f"{report.get('pictures')} in {SECONDS} s")

    if captured and info:
        w, h = report["width"], report["height"]
        m = report["monitor"]
        scale = w / (m[2] - m[0])

        def at(pick, point):
            return pick(point[0] * scale, point[1] * scale)

        def middle(r):
            return ((r[0] + r[2]) / 2, (r[1] + r[3]) / 2)

        def spots(r):
            """Nine points inside a rectangle, away from its edges."""
            return [(r[0] + (r[2] - r[0]) * fx, r[1] + (r[3] - r[1]) * fy) for fx in (0.25, 0.5, 0.75) for fy in (0.25, 0.5, 0.75)]

        check("the stage was on screen before recording started", report.get("stageReady") is True)
        check("clicks go through the stage", report.get("stageClickThrough") is True)
        me = frame(ffmpeg, screen, 0.8, w, h)
        check("a picture at 0.8 s (Me)", me is not None)
        if me:
            whole = [(m[2] - m[0]) * fx for fx in (0.2, 0.5, 0.8)]
            points = [(x, (m[3] - m[1]) * fy) for x in whole for fy in (0.3, 0.6, 0.9)]
            greens = sum(green(at(me, p)) for p in points)
            check("Me: her camera fills the screen", greens >= 7, f"{greens} of 9 spots green, middle {at(me, middle([0, 0, m[2] - m[0], m[3] - m[1]]))}")
            pink = sum(magenta(at(me, p)) for p in spots(report["keptOut"]))
            check("Me: the kept-out window is not in the video", pink == 0, f"{pink} of 9 spots magenta")
        later = frame(ffmpeg, screen, SECONDS - 1.5, w, h)
        check(f"a picture at {SECONDS - 1.5} s (Screen)", later is not None)
        if later:
            b = report["bubble"]
            cx, cy, r = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2, (b[2] - b[0]) / 2
            faces = [at(later, (cx + dx * r, cy + dy * r)) for dx, dy in ((0, 0), (-0.4, 0), (0.4, 0), (0, -0.4), (0, 0.4))]
            check("Screen: her face is in the bubble", sum(green(c) for c in faces) >= 3, f"bubble at {b}, middle {faces[0]}")
            centre = at(later, middle([0, 0, m[2] - m[0], m[3] - m[1]]))
            check("Screen: the middle of the screen is the screen again", not green(centre), f"{centre}")
            pink = sum(magenta(at(later, p)) for p in spots(report["keptOut"]))
            check("Screen: the kept-out window is not in the video", pink == 0, f"{pink} of 9 spots magenta")
            seen = sum(blue(at(later, p)) for p in spots(report["plain"]))
            check("Screen: an ordinary window is in the video", seen >= 7, f"{seen} of 9 spots blue")

    crashed = os.path.join(root, "crashed.mov")
    result, _ = run_test(test, crashed, 10, "--crash-after", "6")
    check("the crash run ends abruptly", result.returncode == 3, f"exit {result.returncode}")
    info = probe(ffprobe, crashed)
    check("a screen.mov cut off by a crash can still be read", info is not None)
    if info:
        duration = float(info["format"].get("duration", 0) or 0)
        audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
        check("it keeps all but the last 2 seconds or so, with both sound tracks", duration >= 3.5 and len(audio) == 2,
              f"{duration:.3f} s of 6 s, {len(audio)} sound tracks")

    # A whole take: camera.mov from the writer test (the same bursts) and this screen.mov.
    result = subprocess.run([writer, os.path.join(take, "camera.mov"), str(SECONDS)], capture_output=True, text=True)
    check("the writer test makes camera.mov", result.returncode == 0, result.stderr.strip())
    with open(os.path.join(take, "events.jsonl"), "w", encoding="utf-8") as out:
        for line in [{"t": 0, "type": "start", "wall": "2026-10-08T09:30:00Z", "title": "Screen test", "camera": "camera.mov",
                      "screen": "screen.mov", "computer": "Windows"},
                     {"t": 0, "type": "show", "what": "camera"},
                     {"t": 1.5, "type": "show", "what": "screen"},
                     {"t": SECONDS - 0.1, "type": "stop"}]:
            out.write(json.dumps(line) + "\n")
    result = subprocess.run([finisher, take, "--no-transcribe"], capture_output=True, text=True, encoding="utf-8")
    print("        " + "\n        ".join(result.stdout.strip().splitlines()))
    check("vidlark-finish finishes the take", result.returncode == 0 and "DONE" in result.stdout, result.stderr.strip()[-300:])
    sync_file = os.path.join(take, "sync.json")
    if os.path.exists(sync_file):
        sync = json.load(open(sync_file, encoding="utf-8"))
        check("screen.mov lined up with camera.mov by sound", sync.get("method") == "audio" and abs(sync["screenOffsetSec"]) < 0.5,
              json.dumps(sync))
    video = os.path.join(take, "video.mp4")
    info = probe(ffprobe, video) if os.path.exists(video) else None
    check("video.mp4 made", info is not None)
    if info:
        v = [s for s in info["streams"] if s["codec_type"] == "video"]
        a = [s for s in info["streams"] if s["codec_type"] == "audio"]
        duration = float(info["format"].get("duration", 0))
        check("video.mp4 is H.264 with sound, as long as the camera", v and v[0].get("codec_name") == "h264" and a
              and abs(duration - SECONDS) < 0.5, f"{duration:.2f} s")

    # Pictures for a person to look at, when CI keeps them.
    keep = os.environ.get("VIDLARK_CHECK_OUT")
    if keep:
        os.makedirs(keep, exist_ok=True)
        for name, at_seconds in (("me", 0.8), ("screen", SECONDS - 1.5)):
            subprocess.run([ffmpeg, "-v", "error", "-y", "-ss", f"{at_seconds}", "-i", screen, "-frames:v", "1",
                            os.path.join(keep, f"screen-{name}.png")])
        for name in ("screen.mov", "video.mp4", "report.md", "sync.json", "events.jsonl"):
            if os.path.exists(os.path.join(take, name)):
                shutil.copy(os.path.join(take, name), keep)

    shutil.rmtree(root, ignore_errors=True)
    print(f"{len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
