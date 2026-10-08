#!/usr/bin/env python3
"""End-to-end check of vidlark-finish on any computer with ffmpeg: Windows in CI, or a Mac.

Take 1, a plain screen take, in a folder whose name has spaces and an accented letter:
  camera.mov  a test picture and a random pattern of noise bursts
  screen.mov  another test picture; track 1 is the same bursts arriving 0.35 s later,
              track 2 is the computer's sound (a quiet tone)
Take 2, camera first, as every Windows and Mac take now starts: the screen is shared 5 s in, with the
same events.jsonl lines the apps write for sharing and for Me and Screen:
  camera.mov  plain red, with the bursts
  screen.mov  plain blue, 15 s, starting at the share; track 1 the bursts from 5 s on, track 2 a loud tone
The finisher runs with --no-transcribe on each, and this checks what it wrote, including that video.mp4
is the camera until the share and the screen after it, with the computer's sound after it.

usage: e2e.py <path to vidlark-finish>
"""
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

DELAY = 0.35
SECONDS = 20
RATE = 48000


def ffmpeg_tool(name):
    found = shutil.which(name)
    if not found:
        sys.exit(f"{name} not found on PATH")
    return found


def bursts(path, seconds, delay=0.0):
    """Mono 16-bit WAV of random noise bursts, the same pattern every run, shifted by `delay`."""
    pattern = random.Random(7)
    events = []
    t = 0.2
    while t < seconds + 1:
        length = pattern.uniform(0.05, 0.4)
        events.append((t, length, pattern.uniform(0.3, 0.9)))
        t += length + pattern.uniform(0.1, 0.9)
    noise = random.Random(11)
    frames = bytearray()
    total = int(seconds * RATE)
    event_index = 0
    for i in range(total):
        now = i / RATE - delay
        level = 0.02
        while event_index < len(events) and events[event_index][0] + events[event_index][1] < now:
            event_index += 1
        if event_index < len(events):
            start, length, loud = events[event_index]
            if start <= now <= start + length:
                level = loud
        frames += struct.pack("<h", int(max(-1.0, min(1.0, noise.uniform(-1, 1) * level)) * 32000))
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(bytes(frames))


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        sys.exit(f"command failed: {' '.join(args)}\n{result.stderr}")
    return result


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    finisher = os.path.abspath(sys.argv[1])
    ffmpeg, ffprobe = ffmpeg_tool("ffmpeg"), ffmpeg_tool("ffprobe")

    root = tempfile.mkdtemp(prefix="vidlark-e2e-")
    take = os.path.join(root, "2026-10-08 Fix a listing, café", "recording-1")
    os.makedirs(take)
    camera_wav, screen_wav = os.path.join(root, "camera.wav"), os.path.join(root, "screen.wav")
    bursts(camera_wav, SECONDS)
    bursts(screen_wav, SECONDS, DELAY)

    run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate=30:duration={SECONDS}",
         "-i", camera_wav, "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-shortest", os.path.join(take, "camera.mov")])
    run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"smptehdbars=size=1920x1080:rate=30:duration={SECONDS}",
         "-i", screen_wav, "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={SECONDS}",
         "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-ac", "2",
         "-shortest", os.path.join(take, "screen.mov")])
    lines = [
        {"t": 0, "type": "start", "wall": "2026-10-08T09:30:00Z", "title": "Fix a listing, café", "screen": "screen.mov"},
        {"t": 0.5, "type": "card", "index": 1, "section": "Hook"},
        {"t": 7.0, "type": "card", "index": 2, "section": "Setup"},
        {"t": 18.0, "type": "stop"},
    ]
    with open(os.path.join(take, "events.jsonl"), "w", encoding="utf-8") as out:
        out.write("\n".join(json.dumps(line) for line in lines) + "\n")

    print("Take 1: a plain screen take")
    result = subprocess.run([finisher, take, "--no-transcribe"], capture_output=True, text=True, encoding="utf-8")
    out = result.stdout.splitlines()
    print("\n".join(out))
    failures = []

    def check(what, ok):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            failures.append(what)

    check("exit 0", result.returncode == 0)
    if result.returncode != 0:
        print(result.stderr)
    check("five STEP lines", [line.split()[1] for line in out if line.startswith("STEP")] == [f"{i}/5" for i in range(1, 6)])
    check("DONE names report.md", bool(out) and out[-1].startswith("DONE ") and out[-1].endswith("report.md"))
    sync = json.load(open(os.path.join(take, "sync.json"), encoding="utf-8"))
    error_ms = abs(sync["screenOffsetSec"] - (-DELAY)) * 1000
    print(f"        offset {sync['screenOffsetSec']:+.4f} s, expected {-DELAY:+.4f} s, error {error_ms:.1f} ms, "
          f"confidence {sync['confidence']}, method {sync['method']}")
    check("screen lined up by sound within 10 ms", sync["method"] == "audio" and error_ms <= 10)
    video = os.path.join(take, "video.mp4")
    check("video.mp4 written", os.path.isfile(video))
    if not os.path.isfile(video):
        report_text = open(os.path.join(take, "report.md"), encoding="utf-8").read()
        print("        report.md says:\n" + "\n".join("          " + line for line in report_text.splitlines() if "ideo" in line))
    if os.path.isfile(video):
        probe = json.loads(run([ffprobe, "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,width,height",
                                "-of", "json", video]).stdout)
        streams = {s["codec_type"]: s for s in probe["streams"]}
        duration = float(probe["format"]["duration"])
        check(f"video.mp4 lasts as long as the camera ({duration:.2f} s)", abs(duration - SECONDS) < 0.2)
        check("video.mp4 is H.264 at the screen's size", streams.get("video", {}).get("codec_name") == "h264"
              and streams["video"]["width"] == 1920 and streams["video"]["height"] == 1080)
        check("video.mp4 has sound", "audio" in streams)
    check("mic.wav written", os.path.isfile(os.path.join(take, "mic.wav")))
    check("chapters.txt written", os.path.isfile(os.path.join(take, "chapters.txt")))
    report = open(os.path.join(take, "report.md"), encoding="utf-8").read()
    check("report.md names the take", "Fix a listing, café" in report)
    check("no em dashes", "\u2014" not in report + result.stdout)

    camera_first(finisher, ffmpeg, ffprobe, root, check)

    shutil.rmtree(root, ignore_errors=True)
    print(f"{len(failures)} failed")
    sys.exit(1 if failures else 0)


SHARE_AT = 5.0


def colour_at(ffmpeg, path, at):
    """The average colour of the picture at `at` seconds, as (r, g, b)."""
    out = subprocess.run([ffmpeg, "-v", "error", "-ss", f"{at}", "-i", path, "-frames:v", "1", "-vf", "scale=16:9",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    if len(out) < 16 * 9 * 3:
        return None
    n = len(out) // 3
    return tuple(sum(out[i::3]) // n for i in range(3))


def tone_level(ffmpeg, path, start, end):
    """How loud the 440 Hz tone is in the sound from `start` to `end` seconds, in dB."""
    out = subprocess.run([ffmpeg, "-v", "info", "-ss", f"{start}", "-t", f"{end - start}", "-i", path, "-vn", "-af",
                          "bandpass=f=440:width_type=h:w=20,volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True, encoding="utf-8").stderr
    for line in out.splitlines():
        if "mean_volume:" in line:
            return float(line.split("mean_volume:")[1].split()[0])
    return None


def camera_first(finisher, ffmpeg, ffprobe, root, check):
    print("Take 2: camera first, the screen shared 5 s in, then Me and Screen")
    take = os.path.join(root, "2026-10-08 Share later", "recording-1")
    os.makedirs(take)
    camera_wav, screen_wav = os.path.join(root, "camera2.wav"), os.path.join(root, "screen2.wav")
    bursts(camera_wav, SECONDS)
    bursts(screen_wav, SECONDS - SHARE_AT, -SHARE_AT)  # screen time 0 is camera time 5
    run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=red:size=1280x720:rate=30:duration={SECONDS}",
         "-i", camera_wav, "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-shortest", os.path.join(take, "camera.mov")])
    length = SECONDS - SHARE_AT
    run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=blue:size=1920x1080:rate=30:duration={length}",
         "-i", screen_wav, "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={length}",
         "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-ac:a:1", "2",
         "-shortest", os.path.join(take, "screen.mov")])
    # The lines Vidlark writes, on Windows as on the Mac.
    lines = [
        {"t": 0, "type": "start", "wall": "2026-10-08T10:00:00Z", "title": "Share later", "camera": "camera.mov", "screen": "",
         "cameraName": "Camera", "micName": "Mic", "screenName": "", "extraCameras": [], "extraMics": [], "videoMic": "",
         "computer": "Windows"},
        {"t": 0, "type": "show", "what": "camera"},
        {"t": SHARE_AT, "type": "screen-start", "screen": "screen.mov", "screenName": "Built-in screen", "macSound": True},
        {"t": SHARE_AT + 0.2, "type": "sound", "on": True, "from": "every app"},
        {"t": SHARE_AT + 0.2, "type": "bubble", "visible": True},
        {"t": SHARE_AT + 0.6, "type": "show", "what": "screen"},
        {"t": 12.0, "type": "show", "what": "camera"},
        {"t": 15.0, "type": "show", "what": "screen"},
        {"t": SECONDS - 0.1, "type": "stop"},
    ]
    with open(os.path.join(take, "events.jsonl"), "w", encoding="utf-8") as out:
        out.write("\n".join(json.dumps(line) for line in lines) + "\n")

    result = subprocess.run([finisher, take, "--no-transcribe"], capture_output=True, text=True, encoding="utf-8")
    print("\n".join(result.stdout.splitlines()))
    check("exit 0", result.returncode == 0)
    sync = json.load(open(os.path.join(take, "sync.json"), encoding="utf-8"))
    error_ms = abs(sync["screenOffsetSec"] - SHARE_AT) * 1000
    print(f"        offset {sync['screenOffsetSec']:+.4f} s, expected {SHARE_AT:+.4f} s, error {error_ms:.1f} ms, method {sync['method']}")
    check("the shared screen lined up by sound within 10 ms", sync["method"] == "audio" and error_ms <= 10)
    video = os.path.join(take, "video.mp4")
    check("video.mp4 written", os.path.isfile(video))
    if not os.path.isfile(video):
        return
    probe = json.loads(run([ffprobe, "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,width,height",
                            "-of", "json", video]).stdout)
    streams = {s["codec_type"]: s for s in probe["streams"]}
    duration = float(probe["format"]["duration"])
    check(f"video.mp4 lasts as long as the camera ({duration:.2f} s)", abs(duration - SECONDS) < 0.2)
    check("video.mp4 is H.264 at the screen's size", streams.get("video", {}).get("codec_name") == "h264"
          and streams["video"]["width"] == 1920 and streams["video"]["height"] == 1080)
    before, after = colour_at(ffmpeg, video, 2.5), colour_at(ffmpeg, video, 10.0)
    print(f"        colour at 2.5 s {before}, at 10 s {after}")
    check("before the share, video.mp4 is the camera (red)", before is not None and before[0] > 150 and before[2] < 80)
    check("after the share, video.mp4 is the screen (blue)", after is not None and after[2] > 150 and after[0] < 80)
    quiet, loud = tone_level(ffmpeg, video, 1, 4), tone_level(ffmpeg, video, 8, 11)
    print(f"        the computer's tone: {quiet} dB before the share, {loud} dB after")
    check("the computer's sound comes in with the screen", quiet is not None and loud is not None and loud > quiet + 15)
    report = open(os.path.join(take, "report.md"), encoding="utf-8").read()
    check("report.md says when the screen was shared", "shared 00:05 into the take" in report)
    check("report.md lists each Me and Screen", all(f"- {t} {w}" in report for t, w in
                                                   (("00:00", "Me"), ("00:05", "Screen"), ("00:12", "Me"), ("00:15", "Screen"))))
    check("report.md lists the computer's sound", "- 00:05 on, from every app" in report)
    check("no em dashes", "\u2014" not in report + result.stdout)


if __name__ == "__main__":
    main()
