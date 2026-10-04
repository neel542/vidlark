#!/bin/bash
# Builds the fixtures and ava-finish, runs it on every fixture and checks the results.
# Set SKIP_FIXTURE=1 to reuse fixtures that are already built.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="$HERE/fixtures/out"
PY=/usr/bin/python3

if [ "${SKIP_FIXTURE:-0}" != "1" ]; then
    "$HERE/make_fixture.sh" || { echo "fixture build failed"; exit 1; }
fi
source "$OUT/expected.env"

(cd "$ROOT" && swift build --product ava-finish 2>&1 | tail -1) || { echo "build failed"; exit 1; }
BIN="$ROOT/.build/debug/ava-finish"

PASS=0
FAILED=0
check() { # description, command...
    local what="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); echo "  ok    $what"; else FAILED=$((FAILED + 1)); echo "  FAIL  $what"; fi
}
run() { # name, args...
    local name="$1"; shift
    local started=$(date +%s)
    "$BIN" "$OUT/$name" "$@" > "$OUT/$name.stdout" 2> "$OUT/$name.stderr"
    echo $? > "$OUT/$name.exit"
    echo "== $name ($(( $(date +%s) - started )) s): $(tail -1 "$OUT/$name.stdout")"
}
py() { "$PY" -c "$1" "${@:2}"; }

offset_near() { # folder, expected
    py 'import json,sys; d=json.load(open(sys.argv[1]+"/sync.json")); o=d["screenOffsetSec"]; e=float(sys.argv[2])
print("        measured %+.4f s, expected %+.4f s, error %.1f ms, confidence %.3f, method %s" % (o, e, abs(o-e)*1000, d["confidence"], d["method"]))
sys.exit(0 if d["method"]=="audio" and abs(o-e) <= 0.010 else 1)' "$1" "$2"
}
chapters_are() { # folder, expected lines joined with |
    local got; got="$(tr '\n' '|' < "$1/chapters.txt")"
    [ "$got" = "$2" ] || { echo "        chapters.txt: $got"; return 1; }
}
no_em_dash() { ! grep -rl $'\xe2\x80\x94' "$@" >/dev/null 2>&1; }
steps_ok() { # name, total
    local expected=""
    for i in $(seq 1 "$2"); do expected+="$i/$2 "; done
    [ "$(grep '^STEP' "$OUT/$1.stdout" | cut -d' ' -f2 | tr '\n' ' ')" = "$expected" ]
}
done_ok() { [ "$(cat "$OUT/$1.exit")" = 0 ] && grep -q "^DONE $OUT/$1/report.md$" "$OUT/$1.stdout"; }

# main: full run
run main
check "exit 0 and DONE line" done_ok main
check "six STEP lines" steps_ok main 6
check "offset within 10 ms of $EXPECTED_OFFSET_MAIN" offset_near "$OUT/main" "$EXPECTED_OFFSET_MAIN"
check "mic.wav is 48 kHz mono 16-bit" bash -c "[ \"\$(/opt/homebrew/bin/ffprobe -v error -show_entries stream=sample_rate,channels,codec_name -of csv=p=0 '$OUT/main/mic.wav')\" = 'pcm_s16le,48000,1' ]"
check "words.json close to the spoken text" py '
import json,sys,re,difflib
w=[x["word"] for x in json.load(open(sys.argv[1]))]
norm=lambda s:[re.sub(r"[^a-z0-9]","",t.lower()) for t in s if re.sub(r"[^a-z0-9]","",t.lower())]
a=norm(open(sys.argv[2]).read().split()); b=norm(w)
r=difflib.SequenceMatcher(None,a,b).ratio()
bad=[x for x in json.load(open(sys.argv[1])) if not x["word"] or x["word"]!=x["word"].strip() or x["end"]<x["start"]]
print("        %d words, %d spoken, match ratio %.3f, bad entries %d" % (len(b),len(a),r,len(bad)))
sys.exit(0 if b and r>=0.85 and not bad else 1)' "$OUT/main/words.json" "$OUT/spoken.txt"
check "exactly one retake near $RETAKE_T s" py '
import json,sys
d=json.load(open(sys.argv[1])); e=float(sys.argv[2])
for r in d: print("        retake at %.3f s (expected %.3f, error %.0f ms): %s" % (r["t"], e, abs(r["t"]-e)*1000, r["context"]))
sys.exit(0 if len(d)==1 and abs(d[0]["t"]-e)<=0.5 and d[0]["context"].endswith("[RETAKE]") else 1)' "$OUT/main/retakes.json" "$RETAKE_T"
check "chapters.txt is Hook, Setup, Payoff" chapters_are "$OUT/main" "00:00 Hook|00:15 Setup|00:30 Payoff|"
check "report.md written" test -s "$OUT/main/report.md"
check "no em dashes in output" no_em_dash "$OUT/main" "$OUT/main.stdout"

# --no-transcribe
run notranscribe --no-transcribe
check "exit 0 and DONE line" done_ok notranscribe
check "four STEP lines" steps_ok notranscribe 4
check "no words.json or retakes.json" bash -c "[ ! -e '$OUT/notranscribe/words.json' ] && [ ! -e '$OUT/notranscribe/retakes.json' ]"
check "offset within 10 ms of $EXPECTED_OFFSET_MAIN" offset_near "$OUT/notranscribe" "$EXPECTED_OFFSET_MAIN"
check "chapters.txt is Hook, Setup, Payoff" chapters_are "$OUT/notranscribe" "00:00 Hook|00:15 Setup|00:30 Payoff|"
check "report says transcript skipped" grep -q "^Skipped" "$OUT/notranscribe/report.md"

# extra camera: camera-2.mov starts 0.75 s after camera.mov and carries the same sound
rm -rf "$OUT/extracam" && mkdir -p "$OUT/extracam"
cp "$OUT/notranscribe/camera.mov" "$OUT/notranscribe/screen.mov" "$OUT/notranscribe/events.jsonl" "$OUT/extracam/"
/opt/homebrew/bin/ffmpeg -v error -ss 0.75 -i "$OUT/notranscribe/camera.mov" -map 0 -c:v copy -c:a aac -b:a 128k "$OUT/extracam/camera-2.mov"
run extracam --no-transcribe
check "exit 0 and DONE line" done_ok extracam
check "camera-2.mov offset within 20 ms of +0.75" py 'import json,sys; d=json.load(open(sys.argv[1]+"/sync.json")); c=d["cameras"][0]
print("        measured %+.4f s, confidence %.3f, method %s" % (c["offsetSec"], c["confidence"], c["method"]))
sys.exit(0 if c["file"]=="camera-2.mov" and c["method"]=="audio" and abs(c["offsetSec"]-0.75) <= 0.020 else 1)' "$OUT/extracam"
check "screen offset unchanged by the extra camera" offset_near "$OUT/extracam" "$EXPECTED_OFFSET_MAIN"
check "report names camera-2.mov" grep -q "^- camera-2.mov: offset" "$OUT/extracam/report.md"
check "sync.json has no cameras list without extra cameras" py 'import json,sys; sys.exit("cameras" in json.load(open(sys.argv[1]+"/sync.json")))' "$OUT/notranscribe"

# the tick box unticked: no transcript and no chapters
rm -rf "$OUT/nochapters" && cp -R "$OUT/notranscribe" "$OUT/nochapters" && rm -f "$OUT/nochapters"/{chapters.txt,report.md,sync.json,mic.wav}
run nochapters --no-transcribe --no-chapters
check "exit 0 and DONE line" done_ok nochapters
check "three STEP lines" steps_ok nochapters 3
check "no chapters.txt or words.json" bash -c "[ ! -e '$OUT/nochapters/chapters.txt' ] && [ ! -e '$OUT/nochapters/words.json' ]"
check "sync still measured" offset_near "$OUT/nochapters" "$EXPECTED_OFFSET_MAIN"
check "report says chapters skipped" grep -q "^Skipped (the take was recorded with the transcript and chapters box unticked)" "$OUT/nochapters/report.md"

# crash: fragmented videos cut off mid-fragment, events.jsonl with no stop line, a cut-off
# last line and a 4 s section to merge
run truncated --no-transcribe
check "exit 0 and DONE line" done_ok truncated
check "offset within 10 ms of $EXPECTED_OFFSET_MAIN" offset_near "$OUT/truncated" "$EXPECTED_OFFSET_MAIN"
check "report shows the shortened camera length" grep -q "Camera (camera.mov): 00:4[0-4]" "$OUT/truncated/report.md"
check "chapters.txt is Hook, Setup, Payoff" chapters_are "$OUT/truncated" "00:00 Hook|00:15 Setup|00:30 Payoff|"
check "report mentions the missing stop line" grep -q "no stop line" "$OUT/truncated/report.md"
check "report mentions 1 damaged line" grep -q "1 damaged line was skipped" "$OUT/truncated/report.md"

# screen started 0.5127 s after the camera, different sound path; chapters from app switches
run advanced --no-transcribe
check "exit 0 and DONE line" done_ok advanced
check "offset within 10 ms of +$EXPECTED_OFFSET_ADVANCED" offset_near "$OUT/advanced" "$EXPECTED_OFFSET_ADVANCED"
check "app chapters, short switches merged" chapters_are "$OUT/advanced" "00:00 Microsoft PowerPoint|00:25 Safari|00:35 Finder|"

# no screen.mov, only two sections
run noscreen --no-transcribe
check "exit 0 and DONE line" done_ok noscreen
check "sync method none, offset 0" py 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["method"]=="none" and d["screenOffsetSec"]==0 else 1)' "$OUT/noscreen/sync.json"
check "chapters.txt is empty" bash -c "[ -f '$OUT/noscreen/chapters.txt' ] && [ ! -s '$OUT/noscreen/chapters.txt' ]"

# unreadable camera.mov
run badcamera --no-transcribe
check "non-zero exit" bash -c "[ \"\$(cat '$OUT/badcamera.exit')\" != 0 ]"
check "FAIL line names camera.mov" grep -q "^FAIL camera.mov could not be read" "$OUT/badcamera.stdout"

# missing folder
run missing --no-transcribe
check "missing folder fails" bash -c "[ \"\$(cat '$OUT/missing.exit')\" != 0 ] && grep -q '^FAIL folder not found' '$OUT/missing.stdout'"

check "no em dashes in any output" no_em_dash "$OUT"/*/report.md "$OUT"/*/chapters.txt "$OUT"/*.stdout

echo
echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
