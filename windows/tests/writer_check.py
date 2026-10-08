#!/usr/bin/env python3
"""Checks the files capture::MovieWriter makes, on a Windows machine with ffmpeg (CI).

usage: writer_check.py <vidlark-writer-test.exe> <vidlark-finish.exe>
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile


def probe(ffprobe, path):
    out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,width,height",
                          "-of", "json", path], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    data = json.loads(out.stdout)
    streams = {s["codec_type"]: s for s in data.get("streams", [])}
    return float(data["format"].get("duration", 0)), streams


def main():
    writer, finisher = (os.path.abspath(p) for p in sys.argv[1:3])
    ffprobe = shutil.which("ffprobe") or sys.exit("ffprobe not found")
    root = tempfile.mkdtemp(prefix="vidlark-writer-")
    failures = []

    def check(what, ok, detail=""):
        print(("  ok    " if ok else "  FAIL  ") + what + (f"  ({detail})" if detail else ""))
        if not ok:
            failures.append(what)

    take = os.path.join(root, "2026-10-08 Writer test", "recording-1")
    os.makedirs(take)
    camera = os.path.join(take, "camera.mov")
    result = subprocess.run([writer, camera, "6"], capture_output=True, text=True)
    check("writer exits 0", result.returncode == 0, result.stderr.strip())
    info = probe(ffprobe, camera)
    check("camera.mov can be read", info is not None)
    if info:
        duration, streams = info
        check("camera.mov is 6 seconds long", abs(duration - 6) < 0.25, f"{duration:.3f} s")
        check("picture is H.264 1280x720", streams.get("video", {}).get("codec_name") == "h264"
              and streams["video"].get("width") == 1280 and streams["video"].get("height") == 720)
        check("sound is AAC", streams.get("audio", {}).get("codec_name") == "aac")

    crashed = os.path.join(root, "crashed.mov")
    result = subprocess.run([writer, crashed, "12", "--crash-after", "8"], capture_output=True, text=True)
    check("the crash run ends abruptly", result.returncode == 3, f"exit {result.returncode}")
    info = probe(ffprobe, crashed)
    check("a file cut off by a crash can still be read", info is not None)
    if info:
        duration, streams = info
        check("it keeps all but the last 2 seconds or so", duration >= 5.5, f"{duration:.3f} s of 8 s")

    mic = os.path.join(take, "mic-2.m4a")
    result = subprocess.run([writer, mic, "5", "--audio-only"], capture_output=True, text=True)
    info = probe(ffprobe, mic)
    check("mic-2.m4a is sound only, AAC, 5 seconds", info is not None and "video" not in info[1]
          and info[1].get("audio", {}).get("codec_name") == "aac" and abs(info[0] - 5) < 0.25,
          f"{info[0]:.3f} s" if info else result.stderr.strip())

    with open(os.path.join(take, "events.jsonl"), "w", encoding="utf-8") as out:
        out.write(json.dumps({"t": 0, "type": "start", "wall": "2026-10-08T09:30:00Z", "title": "Writer test", "screen": ""}) + "\n")
        out.write(json.dumps({"t": 5.9, "type": "stop"}) + "\n")
    os.remove(mic)  # a camera-only take
    result = subprocess.run([finisher, take, "--no-transcribe"], capture_output=True, text=True, encoding="utf-8")
    print(result.stdout.strip())
    check("vidlark-finish finishes a camera.mov the writer made", result.returncode == 0 and "DONE" in result.stdout,
          result.stdout.strip().splitlines()[-1] if result.stdout.strip() else result.stderr.strip())

    shutil.rmtree(root, ignore_errors=True)
    print(f"{len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
