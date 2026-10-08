#!/usr/bin/env python3
"""Checks the transcript, retakes and words.json on Windows with a real voice.

Makes a camera-only take whose sound is the JFK sample from whisper.cpp ("ask not what your country
can do for you"), runs vidlark-finish with the given model, and checks words.json.

usage: transcript_check.py <vidlark-finish> <ggml model> <speech.wav>
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile


def main():
    finisher, model, speech = (os.path.abspath(p) for p in sys.argv[1:4])
    ffmpeg = shutil.which("ffmpeg") or sys.exit("ffmpeg not found")
    root = tempfile.mkdtemp(prefix="vidlark-transcript-")
    take = os.path.join(root, "2026-10-08 Ask not", "recording-1")
    os.makedirs(take)
    subprocess.run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-i", speech,
                    "-c:v", "mpeg4", "-c:a", "aac", "-shortest", os.path.join(take, "camera.mov")], check=True)
    with open(os.path.join(take, "events.jsonl"), "w", encoding="utf-8") as out:
        out.write(json.dumps({"t": 0, "type": "start", "wall": "2026-10-08T09:30:00Z", "title": "Ask not", "screen": ""}) + "\n")

    result = subprocess.run([finisher, take, "--model", model], capture_output=True, text=True, encoding="utf-8")
    print(result.stdout.strip())
    failures = []

    def check(what, ok, detail=""):
        print(("  ok    " if ok else "  FAIL  ") + what + (f"  ({detail})" if detail else ""))
        if not ok:
            failures.append(what)

    check("exit 0 and DONE", result.returncode == 0 and "DONE" in result.stdout, result.stderr.strip()[-300:])
    words_file = os.path.join(take, "words.json")
    words = json.load(open(words_file, encoding="utf-8")) if os.path.exists(words_file) else []
    text = " ".join(w["word"] for w in words).lower()
    print("        heard: " + text)
    check("words.json has the words", len(words) >= 15, f"{len(words)} words")
    check("it heard 'ask not what your country'", "country" in text and "ask" in text)
    check("every word has a time, in order", all(w["end"] >= w["start"] for w in words)
          and all(a["start"] <= b["start"] for a, b in zip(words, words[1:])))
    check("retakes.json written", os.path.exists(os.path.join(take, "retakes.json")))
    shutil.rmtree(root, ignore_errors=True)
    print(f"{len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
