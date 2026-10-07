#!/bin/bash
# Checks the Recordings page's file logic against a fake library in a temp folder.
# Run: bash Tests/recordings/run.sh   (needs ffmpeg for the test videos)
set -euo pipefail
cd "$(dirname "$0")/../.."

WORK="$(mktemp -d)"
ROOT="$WORK/library"
trap 'rm -rf "$WORK"' EXIT

FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"
video() { "$FFMPEG" -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 5 -c:v libx264 -pix_fmt yuv420p "$1"; }

# A finished take with both videos.
T="$ROOT/2026-10-01 Fix a listing/recording-1"
mkdir -p "$T"
video "$T/camera.mov"; cp "$T/camera.mov" "$T/screen.mov"
printf '%s\n' '{"t":0,"type":"start","wall":"2026-10-01T09:30:00Z","title":"Fix a suppressed listing","cameraName":"iPhone"}' \
  '{"t":3.2,"type":"card","index":1,"section":"Hook"}' '{"t":42.5,"type":"stop"}' > "$T/events.jsonl"
echo "# Report" > "$T/report.md"

# A crashed take: no camera file, no stop line, a cut-off last line.
T="$ROOT/2026-10-01 Fix a listing/recording-2"
mkdir -p "$T"
video "$T/screen.mov"
printf '%s\n' '{"t":0,"type":"start","wall":"2026-10-01T10:00:00Z","title":"Fix a suppressed listing"}' '{"t":2.0,"type":"card"' > "$T/events.jsonl"

# A take being recorded right now (check.swift makes its files new).
T="$ROOT/2026-10-04 Brand Registry/recording-1"
mkdir -p "$T"
video "$T/camera.mov"
printf '%s\n' '{"t":0,"type":"start","wall":"2026-10-04T08:00:00Z","title":"Brand Registry in ten minutes"}' > "$T/events.jsonl"

# A take sitting directly in the library, and things that are not takes.
T="$ROOT/2026-09-20 Loose take"
mkdir -p "$T"
video "$T/camera.mov"
mkdir -p "$ROOT/.models/whisper/recording-1" "$ROOT/2026-09-01 Old/notes"
touch "$ROOT/.models/whisper/recording-1/camera.mov" "$ROOT/2026-09-01 Old/notes/readme.txt"
# An empty take folder that only has events (a camera that never started).
T="$ROOT/2026-09-01 Old/recording-1"
mkdir -p "$T"
printf '%s\n' '{"t":0,"type":"start","wall":"2026-09-01T12:00:00Z","title":"Old video"}' > "$T/events.jsonl"

mkdir -p "$WORK/copies"
swiftc -O -parse-as-library -o "$WORK/check" \
  Sources/Vidlark/RecordingsStore.swift Sources/Vidlark/Library.swift Sources/Vidlark/Script.swift \
  Tests/recordings/check.swift
"$WORK/check" "$ROOT" "$WORK/copies"
