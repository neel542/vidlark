#!/usr/bin/env python3
"""End-to-end check of vidlark-finish on any computer with ffmpeg: Windows in CI, or a Mac.

Builds one take in a folder whose name has spaces and an accented letter, with:
  camera.mov  a test picture and a random pattern of noise bursts
  screen.mov  another test picture; track 1 is the same bursts arriving 0.35 s later,
              track 2 is the computer's sound (a quiet tone)
  events.jsonl  a camera-first start would change the video, so this is a plain screen take
then runs the finisher with --no-transcribe and checks what it wrote.

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

    shutil.rmtree(root, ignore_errors=True)
    print(f"{len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
