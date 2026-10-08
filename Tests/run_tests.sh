#!/bin/bash
# Builds the fixtures and vidlark-finish, runs it on every fixture and checks the results.
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

# FINISH_BIN=<path> checks another build of the finisher instead, such as the C++ one in windows/.
if [ -n "${FINISH_BIN:-}" ]; then
    BIN="$FINISH_BIN"
else
    (cd "$ROOT" && swift build --product vidlark-finish 2>&1 | tail -1) || { echo "build failed"; exit 1; }
    BIN="$ROOT/.build/debug/vidlark-finish"
fi

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
check "seven STEP lines" steps_ok main 7
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
check "five STEP lines" steps_ok notranscribe 5
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

looks_like_in() { # folder, video time, source file, source time, wanted: same or different
    local dir="$OUT/$1"; shift
    local score
    score=$(/opt/homebrew/bin/ffmpeg -v info -ss "$1" -i "$dir/video.mp4" -ss "$3" -i "$dir/$2" \
        -filter_complex "[0:v]scale=640:360,format=yuv420p[a];[1:v]scale=640:360,format=yuv420p[b];[a][b]ssim" -frames:v 1 -f null - 2>&1 \
        | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1)
    echo "        video at $1 s against $2 at $3 s: SSIM $score"
    if [ "$4" = same ]; then python3 -c "import sys; sys.exit(0 if float('$score') > 0.9 else 1)"
    else python3 -c "import sys; sys.exit(0 if float('$score') < 0.6 else 1)"; fi
}

# camera first, screen shared 20 s in: screen.mov holds the same sound from 20 s on
rm -rf "$OUT/shared" && mkdir -p "$OUT/shared"
cp "$OUT/notranscribe/camera.mov" "$OUT/shared/"
/opt/homebrew/bin/ffmpeg -v error -ss 20 -i "$OUT/notranscribe/screen.mov" -map 0 -c:v libx264 -preset ultrafast -c:a aac -b:a 128k "$OUT/shared/screen.mov"
python3 - "$OUT/notranscribe/events.jsonl" "$OUT/shared/events.jsonl" <<'PY'
import json, sys
out = []
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e["type"] == "start": e["screen"] = ""
    out.append(json.dumps(e))
out.insert(1, json.dumps({"type": "screen-start", "t": 19.6, "screen": "screen.mov"}))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
run shared --no-transcribe
check "exit 0 and DONE line" done_ok shared
check "screen offset within 20 ms of 20 s plus the fixture's own offset" py 'import json,sys; d=json.load(open(sys.argv[1]+"/sync.json")); want=20+float(sys.argv[2])
print("        measured %+.4f s, expected %+.4f s, confidence %.3f, method %s" % (d["screenOffsetSec"], want, d["confidence"], d["method"]))
sys.exit(0 if d["method"]=="audio" and abs(d["screenOffsetSec"]-want) <= 0.020 else 1)' "$OUT/shared" "$EXPECTED_OFFSET_MAIN"
check "before the share the video is the camera" looks_like_in shared 10 camera.mov 10 same
check "after the share the video is the screen" looks_like_in shared 30 camera.mov 30 different
check "report says when the screen was shared" grep -q "shared 00:19 into the take" "$OUT/shared/report.md"
# The test camera has no face: faces.json says so, and the opening keeps the old crop.
check "faces.json written for the camera-first opening, with no face in it" py 'import json,sys; d=json.load(open(sys.argv[1]+"/faces.json"))
print("        %d looks over %s, %d with a face" % (len(d["looks"]), d["spans"], sum(1 for l in d["looks"] if l["faces"])))
sys.exit(0 if d["looks"] and not any(l["faces"] for l in d["looks"]) and d["spans"][0][0] == 0 else 1)' "$OUT/shared"
check "report says no face was found" grep -q "^No face was found in the camera picture" "$OUT/shared/report.md"

# --no-framing: no looking for faces at all
rm -rf "$OUT/noframing" && mkdir -p "$OUT/noframing"
cp "$OUT/shared/camera.mov" "$OUT/shared/screen.mov" "$OUT/shared/events.jsonl" "$OUT/noframing/"
run noframing --no-transcribe --no-framing
check "exit 0 and DONE line" done_ok noframing
check "no faces.json" test ! -e "$OUT/noframing/faces.json"
check "report says face framing was off" grep -q "^Face framing was off" "$OUT/noframing/report.md"
check "before the share the video is the camera, as with framing" looks_like_in noframing 10 camera.mov 10 same

# Me and Screen: the video starts on the camera, shows the screen at 10 s and the camera again at 25 s
rm -rf "$OUT/switches" && mkdir -p "$OUT/switches"
cp "$OUT/notranscribe/camera.mov" "$OUT/notranscribe/screen.mov" "$OUT/switches/"
{ head -1 "$OUT/notranscribe/events.jsonl"
  echo '{"t":0,"type":"show","what":"camera"}'
  tail -n +2 "$OUT/notranscribe/events.jsonl"
  echo '{"t":10,"type":"show","what":"screen"}'
  echo '{"t":25,"type":"show","what":"camera"}'; } > "$OUT/switches/events.jsonl"
run switches --no-transcribe
check "exit 0 and DONE line" done_ok switches
looks_like() { looks_like_in switches "$@"; }
check "video.mp4 runs as long as the camera" py 'import subprocess,sys
d=float(subprocess.check_output(["/opt/homebrew/bin/ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",sys.argv[1]]).decode())
print("        video.mp4 is %.2f s" % d); sys.exit(0 if abs(d-45) < 0.2 else 1)' "$OUT/switches/video.mp4"
# Me fills the real screen with the camera, so screen.mov holds it: the video is screen.mov throughout.
check "at 5 s the video is screen.mov" looks_like 5 screen.mov 5 same
check "at 17 s the video is screen.mov, not the camera" looks_like 17 camera.mov 17 different
check "at 35 s the video is screen.mov" looks_like 35 screen.mov 35 same
check "report lists the clicks" bash -c "grep -q '^- 00:10 Screen' '$OUT/switches/report.md' && grep -q '^- 00:25 Me' '$OUT/switches/report.md'"

# camera first and never shared: no screen.mov, said plainly
rm -rf "$OUT/nevershared" && mkdir -p "$OUT/nevershared"
cp "$OUT/notranscribe/camera.mov" "$OUT/nevershared/"
grep -v screen-start "$OUT/shared/events.jsonl" > "$OUT/nevershared/events.jsonl"
run nevershared --no-transcribe
check "exit 0 and DONE line" done_ok nevershared
check "report says the screen was not shared" grep -q "none, the screen was not shared in this take" "$OUT/nevershared/report.md"

# the tick box unticked: no transcript and no chapters
rm -rf "$OUT/nochapters" && cp -R "$OUT/notranscribe" "$OUT/nochapters" && rm -f "$OUT/nochapters"/{chapters.txt,report.md,sync.json,mic.wav}
run nochapters --no-transcribe --no-chapters
check "exit 0 and DONE line" done_ok nochapters
check "four STEP lines" steps_ok nochapters 4
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

# The padding only comes from the Mac's camera writer, so the C++ finisher has nothing to take out.
if [ -z "${FINISH_BIN:-}" ]; then
# camera.mov padded the way the Mac's camera writer pads it: the finisher takes the padding out
# before anything reads the file, and every packet stays as it was
rm -rf "$OUT/padded"; mkdir -p "$OUT/padded"
"$PY" "$HERE/pad_movie.py" "$OUT/main/camera.mov" "$OUT/padded/camera.mov"
cp "$OUT/main/screen.mov" "$OUT/main/events.jsonl" "$OUT/main/script.md" "$OUT/padded/"
packets() { /opt/homebrew/bin/ffmpeg -v error -i "$1" -map 0 -c copy -f framemd5 - | grep -v '^#' | md5; }
BEFORE_PACKETS="$(packets "$OUT/main/camera.mov")"
run padded --no-transcribe
check "exit 0 and DONE line" done_ok padded
check "padding taken out: camera.mov is back to its unpadded size" bash -c "[ \$(stat -f%z '$OUT/padded/camera.mov') = \$(stat -f%z '$OUT/main/camera.mov') ]"
check "every packet of camera.mov unchanged" bash -c "[ \"\$1\" = \"\$2\" ]" _ "$BEFORE_PACKETS" "$(packets "$OUT/padded/camera.mov")"
check "offset within 10 ms of $EXPECTED_OFFSET_MAIN" offset_near "$OUT/padded" "$EXPECTED_OFFSET_MAIN"
check "no tidy copy left behind" bash -c "! ls -a '$OUT/padded' | grep -q '\.tidy$'"
fi

# unreadable camera.mov
run badcamera --no-transcribe
check "non-zero exit" bash -c "[ \"\$(cat '$OUT/badcamera.exit')\" != 0 ]"
check "FAIL line names camera.mov" grep -q "^FAIL camera.mov could not be read" "$OUT/badcamera.stdout"

# missing folder
run missing --no-transcribe
check "missing folder fails" bash -c "[ \"\$(cat '$OUT/missing.exit')\" != 0 ] && grep -q '^FAIL folder not found' '$OUT/missing.stdout'"

check "framing rules on made-up face tracks (Tests/framing)" bash -c "bash '$HERE/framing/run.sh' > '$OUT/framing.log' 2>&1 || { grep FAIL '$OUT/framing.log'; tail -1 '$OUT/framing.log'; exit 1; }; tail -1 '$OUT/framing.log' | sed 's/^/        /'"

check "no em dashes in any output" no_em_dash "$OUT"/*/report.md "$OUT"/*/chapters.txt "$OUT"/*.stdout

echo
echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
